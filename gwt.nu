# gwt.nu: structured `git worktree` commands for Nushell 0.116.2.
# See README.md for the full guide.
#
# `gwt add` puts worktrees in `<root>/<repo>/<branch>`. Set `$env.GWT_ROOT` to
# change `<root>` from its default, `~/src/worktrees`.
#
# Load it from config.nu, below any `$env.config = {...}` assignment (that
# assignment would replace the abbreviations this module adds):
#
#     use /path/to/nu-git-worktree/gwt.nu *
#
#   command                  shortcut
#   gwt list [--long]        wtl, wtll    (aliases)
#   gwt status               wts          (alias)
#   gwt cd [--main]          wtcd         (alias)
#   gwt add                  wta, wtac    (abbreviations; wtac adds --cd)
#   gwt remove               wtrm         (abbreviation)
#   gwt move                 wtmv         (abbreviation)
#   gwt lock / unlock        wtlk / wtul  (abbreviations)
#   gwt prune                wtp          (abbreviation)
#   gwt repair
#
# Aliases cover the commands that only read or navigate, so they run as typed
# and compose in pipelines. Commands that create, change, or delete worktrees
# are abbreviations instead: the line editor expands them on space or enter,
# so the full command is on screen before it runs and is what history records.
#
# Commands take a worktree by path, by directory name, or by the branch it has
# checked out, and complete all three. Raw `git worktree <subcommand>` calls
# get completions from the externs at the end of this file.

const ABBREVIATIONS = {
    wta: 'gwt add'
    wtac: 'gwt add --cd'
    wtrm: 'gwt remove'
    wtmv: 'gwt move'
    wtlk: 'gwt lock'
    wtul: 'gwt unlock'
    wtp: 'gwt prune'
}

export-env {
    # An abbreviation the user already defined keeps its expansion.
    $env.config.abbreviations = $ABBREVIATIONS | merge ($env.config.abbreviations? | default {})
}

# `git worktree list --porcelain` reports this HEAD for an unborn branch.
const NULL_SHA = '0000000000000000000000000000000000000000'

# Columns of `gwt list`, and of `gwt list --long` and the records
# that `add`, `move`, `lock`, and `unlock` return.
const LIST_COLUMNS = [name branch head committed current main locked prunable]
const LONG_COLUMNS = [
    name branch head commit committed subject path current main
    bare detached locked lock_reason prunable prune_reason
]

# Raise `msg` with a `text` label at `span`, the user's argument. Without a
# span the error is unspanned, since a label would point into this file.
def fail [msg: string, text: string, span: oneof<record, nothing>, --hint: string] {
    let help_part = if $hint == null { {} } else { {help: $hint} }
    if $span == null {
        error make --unspanned ({msg: $msg} | merge $help_part)
    }
    error make ({msg: $msg, label: {text: $text, span: $span}} | merge $help_part)
}

# Run git with each argument passed separately and return its stdout. A
# non-zero exit raises git's stderr as the error, labelled at `span` when one
# is given.
def --wrapped git-run [--span: oneof<record, nothing>, ...args]: nothing -> string {
    let result = ^git ...$args | complete
    if $result.exit_code != 0 {
        let message = $result.stderr | str trim | default --empty $"git exited with code ($result.exit_code)"
        fail $message 'git rejected this' $span
    }
    $result.stdout
}

# Whether a fully qualified ref such as `refs/heads/main` exists.
def ref-exists [ref: string]: nothing -> bool {
    (^git show-ref --verify --quiet $ref | complete).exit_code == 0
}

# Parse `git worktree list --porcelain -z`. Each worktree is a run of
# NUL-terminated `key value` fields and an extra NUL ends the run; the first
# worktree is the main one. `--expire` marks missing worktrees older than that
# date as prunable, as `git worktree prune --expire` would see them.
def worktrees [--expire: string]: nothing -> table {
    let expire_args = if $expire == null { [] } else { ['--expire' $expire] }
    let porcelain = git-run worktree list --porcelain -z ...$expire_args
    let toplevel = ^git rev-parse --show-toplevel | complete
    let here = if $toplevel.exit_code == 0 { $toplevel.stdout | str trim | path expand }

    $porcelain
    | split row $'(char nul)(char nul)'
    | where $it != ''
    | enumerate
    | each {|entry|
        # `(?s)` keeps a multi-line lock or prune reason in one field.
        let attr = $entry.item
            | split row (char nul)
            | parse --regex '(?s)^(?<key>[^ ]+)(?: (?<value>.*))?$'
            | transpose --header-row --as-record
        let path = $attr.worktree
        {
            name: ($path | path basename)
            branch: (if 'branch' in $attr { $attr.branch | str replace --regex '^refs/heads/' '' })
            commit: ($attr.HEAD? | if $in == $NULL_SHA { null } else { $in })
            path: $path
            main: ($entry.index == 0)
            current: ($here != null and ($path | path expand) == $here)
            bare: ('bare' in $attr)
            detached: ('detached' in $attr)
            locked: ('locked' in $attr)
            lock_reason: ($attr.locked? | default --empty null)
            prunable: ('prunable' in $attr)
            prune_reason: ($attr.prunable? | default --empty null)
        }
    }
}

# Add each worktree's abbreviated HEAD, commit date, and subject, from a single
# `git log` over every HEAD. Bare and unborn worktrees get nulls.
def with-commit-info []: table -> table {
    let rows = $in
    let shas = $rows | get commit | compact | uniq
    let info = if ($shas | is-empty) { {} } else {
        git-run log --no-walk=unsorted --ignore-missing '--format=%H%x1f%h%x1f%cI%x1f%s' ...$shas
        | lines
        | split column --number 4 "\u{1f}" sha head committed subject
        | reduce --fold {} {|it, acc| $acc | insert $it.sha $it }
    }
    $rows | each {|row|
        let commit = if $row.commit != null { $info | get --optional $row.commit }
        $row | merge {
            head: $commit.head?
            committed: ($commit.committed? | if $in != null { into datetime })
            subject: $commit.subject?
        }
    }
}

# The one worktree that `target` names: its path (absolute or relative to the
# current directory), its directory name, or its branch. A piped row names its
# `path`, or its `name` when it has no path (plain `gwt list` leaves the path
# out). Errors are labelled at
# `span`, the user's argument, or unspanned when it is null.
#
# `--to remove` or `--to move` also refuses the main worktree and locked
# worktrees. git would take `--force` twice for a locked worktree; unlocking
# first keeps the lock a deliberate guard.
def find-worktree [target: any, span: oneof<record, nothing>, --to: string]: table -> record {
    let rows = $in
    let wanted = if ($target | describe --detailed | get type) == 'record' { $target.path? | default $target.name? } else { $target }
    if ($wanted | describe) != 'string' {
        fail 'expected a worktree path, name, or branch, or a row with a path or name column' $"got ($target | describe)" $span
    }
    let by_path = $rows | where ($it.path | path expand) == ($wanted | path expand)
    let matches = if ($by_path | is-not-empty) { $by_path } else {
        $rows | where name == $wanted or branch == $wanted
    }
    if ($matches | is-empty) {
        fail $"no worktree matches '($wanted)'" 'not a worktree path, directory name, or branch' $span --hint 'run `gwt list` to see the worktrees'
    }
    if ($matches | length) > 1 {
        fail $"'($wanted)' matches more than one worktree" 'ambiguous' $span --hint $"pass one of these paths instead: ($matches.path | str join ', ')"
    }
    let wt = $matches | first
    if $to != null and $wt.main {
        fail $"cannot ($to) the main worktree at ($wt.path)" 'main worktree' $span --hint '`gwt list | where not main` leaves it out'
    }
    if $to != null and $wt.locked {
        let reason = if $wt.lock_reason == null { '' } else { $": ($wt.lock_reason)" }
        fail $"worktree '($wt.name)' is locked($reason)" 'locked' $span --hint $"unlock it first: gwt unlock ($wt.name)"
    }
    $wt
}

# `find-worktree` for each target, without duplicates. Errors are labelled at
# each target's own span; `--unspanned` drops the labels, for piped rows whose
# spans point inside this file. A `for` loop rather than `each`, so a bad
# target raises its own error instead of one wrapped by the closure.
def find-worktrees [targets: list, --to: string, --unspanned]: table -> table {
    let rows = $in
    mut found = []
    for target in $targets {
        let span = if $unspanned { null } else { (metadata $target).span }
        $found ++= [($rows | find-worktree $target $span --to $to)]
    }
    $found | uniq-by path
}

# Where `gwt add` puts a worktree by default: `<root>/<repo>/<branch>`, with
# `<root>` from `$env.GWT_ROOT` or else `~/src/worktrees`, and `<repo>` the
# main worktree's directory name. Branch `abc` of `~/src/nushell` lands in
# `~/src/worktrees/nushell/abc`. A `/` in the branch becomes `-`, keeping one
# directory level per worktree.
def default-path [main: record, branch: string]: nothing -> string {
    let root = $env.GWT_ROOT? | default ($nu.home-dir | path join src worktrees) | path expand
    let repo = $main.path | path basename | str replace --regex '\.git$' ''
    $root | path join $repo ($branch | str replace --all '/' '-')
}

# The remote-tracking branch that `gwt add` should track for `branch`:
# `branch` names one itself (`origin/topic`), or exactly one remote has a
# branch called `branch`. Returns `{upstream: origin/topic, name: topic}`, or
# null when no remote has it.
def remote-for [branch: string, span: record]: nothing -> oneof<record, nothing> {
    let remote_refs = git-run for-each-ref '--format=%(refname:lstrip=2)%1f%(refname:lstrip=3)' refs/remotes
        | lines
        | split column "\u{1f}" upstream name
        | where name != 'HEAD'
    let exact = $remote_refs | where upstream == $branch
    if ($exact | is-not-empty) {
        return ($exact | first)
    }
    let named = $remote_refs | where name == $branch
    match ($named | length) {
        0 => null
        1 => ($named | first)
        _ => (fail $"branch '($branch)' exists on more than one remote" 'which remote?' $span --hint $"name the remote branch instead: ($named.upstream | str join ' or ')")
    }
}

# Counts from `git status --porcelain=v2 --branch` for one worktree.
def status-of [wt: record]: nothing -> record {
    # --no-optional-locks: a status check never rewrites the index.
    let lines = git-run --no-optional-locks -C $wt.path status --porcelain=v2 --branch | lines
    let header = $lines
        | parse --regex '^# (?<key>\S+) (?<value>.*)$'
        | transpose --header-row --as-record
    let ab = $header | get --optional 'branch.ab' | default '' | parse '+{ahead} -{behind}' | get --optional 0
    # Changed entries start `1 XY` or `2 XY` (renames): X is the index side,
    # Y the worktree side, and `.` means unchanged.
    let xy = $lines | where $it =~ '^[12] ' | each { str substring 2..3 }
    let counts = {
        staged: ($xy | where ($it | str substring 0..0) != '.' | length)
        modified: ($xy | where ($it | str substring 1..1) != '.' | length)
        untracked: ($lines | where $it starts-with '? ' | length)
        conflicts: ($lines | where $it starts-with 'u ' | length)
    }
    {
        name: $wt.name
        branch: $wt.branch
        upstream: ($header | get --optional 'branch.upstream')
        ahead: ($ab.ahead? | if $in != null { into int })
        behind: ($ab.behind? | if $in != null { into int })
        ...$counts
        clean: (($counts | values | math sum) == 0)
        path: $wt.path
    }
}

# Completion records for worktrees that pass `keep`. The value is the
# directory name when no other worktree shares it (git accepts that too) and
# the full path otherwise.
def suggest-worktrees [keep: closure]: nothing -> record {
    let rows = try { worktrees } catch { [] }
    let shared = $rows | get --optional name | default [] | uniq --repeated
    let completions = $rows | where $keep | each {|wt|
        let notes = [
            ($wt.branch | default '(detached)')
            (if $wt.current { 'current' })
            (if $wt.locked { 'locked' })
            (if $wt.prunable { 'prunable' })
            $wt.path
        ]
        {
            value: (if $wt.name in $shared { $wt.path } else { $wt.name })
            description: ($notes | compact | str join ' · ')
        }
    }
    {options: {sort: false}, completions: $completions}
}

def complete-worktree [] { suggest-worktrees {|wt| true } }
def complete-linked-worktree [] { suggest-worktrees {|wt| not $wt.main } }
def complete-unlocked-worktree [] { suggest-worktrees {|wt| not $wt.main and not $wt.locked } }
def complete-locked-worktree [] { suggest-worktrees {|wt| $wt.locked } }

# Branches `gwt add` can check out: local branches no worktree has
# checked out (newest first), then remote branches without a local branch of
# the same name.
def complete-add-branch [] {
    let refs = try {
        git-run for-each-ref --sort=-committerdate '--format=%(refname)%1f%(worktreepath)%1f%(subject)' refs/heads refs/remotes
        | lines
        | split column --number 3 "\u{1f}" ref worktree subject
    } catch { [] }
    let local = $refs
        | where ref starts-with 'refs/heads/'
        | insert value { $in.ref | str replace 'refs/heads/' '' }
    let free = $local
        | where worktree == ''
        | each {|it| {value: $it.value, description: $"local · ($it.subject)"} }
    let remote = $refs
        | where ref starts-with 'refs/remotes/'
        | insert upstream { $in.ref | str replace 'refs/remotes/' '' }
        | insert value { $in.upstream | str replace --regex '^[^/]+/' '' }
        | where value != 'HEAD' and value not-in $local.value
        | each {|it| {value: $it.value, description: $"($it.upstream) · ($it.subject)"} }
        | uniq-by value
    {options: {sort: false}, completions: ($free ++ $remote)}
}

# Commits by name for `--base` and raw `git worktree add`: local branches,
# remote branches, then tags, each newest first.
def complete-commitish [] {
    let refs = try {
        git-run for-each-ref --sort=-creatordate '--format=%(refname)%1f%(subject)' refs/heads refs/remotes refs/tags
        | lines
        | split column --number 2 "\u{1f}" ref subject
    } catch { [] }
    let kinds = [[prefix kind]; ['refs/heads/' branch] ['refs/remotes/' remote] ['refs/tags/' tag]]
    let completions = $kinds | each {|k|
        $refs
        | where ref starts-with $k.prefix and not ($it.ref ends-with '/HEAD')
        | each {|it| {value: ($it.ref | str replace $k.prefix ''), description: $"($k.kind) · ($it.subject)"} }
    }
    {options: {sort: false}, completions: ($completions | flatten)}
}

# Structured git worktree commands: list them with their aliases and abbreviations.
#
# Run `help gwt <subcommand>` for the details of one. This is the module's
# `main`, which `use gwt.nu *` imports as `gwt`; nushell won't let a module
# export a command with its own name.
export def main []: nothing -> table {
    let aliases = scope aliases | where expansion starts-with 'gwt ' | select name expansion
    let abbreviations = $ABBREVIATIONS | transpose name expansion
    # The shortcuts whose expansion is `command`, with or without extra flags.
    let names_for = {|shortcuts, command|
        $shortcuts
        | where $it.expansion == $command or ($it.expansion starts-with $"($command) ")
        | get name
        | str join ', '
    }
    scope commands
    | where name starts-with 'gwt ' and type == custom
    | each {|cmd|
        {
            command: $cmd.name
            aliases: (do $names_for $aliases $cmd.name)
            abbreviations: (do $names_for $abbreviations $cmd.name)
            description: $cmd.description
        }
    }
}

# List the repository's worktrees, main worktree first.
#
# `head` is the abbreviated HEAD commit and `committed` its commit date.
# `current` marks the worktree that contains the current directory. The path
# is left out to keep the table narrow; `--long` adds it.
@example "Worktrees whose branch mentions 'fix'" { gwt list | where branch =~ fix }
@example "Linked worktrees with no commit in two weeks" { gwt list | where not main and committed < ((date now) - 2wk) }
@example "Why each worktree is locked or prunable" { gwt list --long | where $it.locked or $it.prunable | select name lock_reason prune_reason }
export def "gwt list" [
    --long (-l) # Also show the path, full commit id and subject, bare/detached flags, and lock/prune reasons
]: nothing -> table {
    worktrees | with-commit-info | select ...(if $long { $LONG_COLUMNS } else { $LIST_COLUMNS })
}

# Show each worktree's branch, upstream, ahead/behind counts, and changes.
#
# Runs `git status` in every worktree in parallel. Prunable and bare
# worktrees have no files to inspect and are left out.
@example "Worktrees with uncommitted work" { gwt status | where not clean }
@example "Worktrees with commits their upstream lacks" { gwt status | where ahead > 0 }
export def "gwt status" [
    ...worktrees: string@complete-worktree # Worktrees to check, by path, name, or branch (default: all)
]: nothing -> table {
    let rows = worktrees
    let selected = if ($worktrees | is-empty) { $rows } else { $rows | find-worktrees $worktrees }
    $selected
    | where not $it.bare and not $it.prunable
    | par-each --keep-order {|wt| status-of $wt }
}

# Create a worktree for a branch and return its row from `gwt list --long`.
#
# `branch` decides what gets checked out:
#   - an existing local branch is checked out as is;
#   - a branch only a remote has (`topic` or `origin/topic`) becomes a local
#     branch tracking it;
#   - any other name becomes a new branch from `--base`, or from HEAD.
# The default directory is `<root>/<repo>/<branch>`, where `<root>` is
# `$env.GWT_ROOT` or `~/src/worktrees`: branch `abc` of `~/src/nushell` goes
# in `~/src/worktrees/nushell/abc`. Pass `path` to put one worktree elsewhere.
@example "New branch from HEAD in the default directory" { gwt add fix_parser }
@example "New branch from a release tag, then cd into it" { gwt add backport --base 0.116.0 --cd }
@example "Track a remote branch" { gwt add origin/feature }
@example "Inspect a tag in a detached worktree" { gwt add 0.116.0 --detach }
export def --env "gwt add" [
    branch: string@complete-add-branch # Branch to check out: local, remote (`topic` or `origin/topic`), or a new name; any commit with --detach
    path?: path # Directory for the worktree (default: <root>/<repo>/<branch>, root from $env.GWT_ROOT or ~/src/worktrees)
    --base (-b): string@complete-commitish # Start a new branch here (commit, branch, or tag) instead of HEAD
    --detach (-d) # Check out `branch` as a detached HEAD instead of a branch
    --orphan # Create `branch` as a new unborn branch with an empty index
    --force (-f) # Check out the branch even if another worktree has it checked out
    --no-checkout # Register the worktree without checking out its files
    --lock # Lock the new worktree
    --reason: string # Lock the new worktree with this reason (implies --lock)
    --cd (-c) # Change into the new worktree
]: nothing -> record {
    let span = (metadata $branch).span
    if $detach and $orphan {
        fail 'use --detach or --orphan, not both' 'two checkout modes' $span
    }
    let local = ref-exists $"refs/heads/($branch)"
    if $base != null and ($detach or $orphan or $local) {
        let why = if $local { $"branch '($branch)' already exists" } else if $detach { '--detach checks out an existing commit' } else { '--orphan starts with no commits' }
        fail '--base only applies when creating a branch' $why (metadata $base).span
    }
    let remote = if $detach or $orphan or $local or $base != null { null } else { remote-for $branch $span }
    let creates_branch = not ($detach or $local or $remote != null)
    if $creates_branch {
        # Reject a bad branch name before git creates the directory.
        git-run --span $span check-ref-format --branch $branch | ignore
    }

    let main = worktrees | first
    let dest = if $path != null { $path | path expand } else {
        default-path $main (if $remote != null { $remote.name } else { $branch })
    }
    let options = [
        (if $force { '--force' })
        (if $no_checkout { '--no-checkout' })
        (if $lock or $reason != null { '--lock' })
    ] | compact | append (if $reason != null { ['--reason' $reason] } else { [] })
    let checkout = if $detach {
        ['--detach' $dest $branch]
    } else if $orphan {
        ['--orphan' '-b' $branch $dest]
    } else if $local {
        [$dest $branch]
    } else if $remote != null {
        ['--track' '-b' $remote.name $dest $remote.upstream]
    } else {
        ['-b' $branch $dest] | append (if $base != null { [$base] } else { [] })
    }
    git-run --span $span worktree add --quiet ...$options ...$checkout | ignore

    let row = gwt list --long | find-worktree $dest $span
    if $cd {
        cd $row.path
    }
    $row | insert new_branch ($creates_branch or $remote != null)
}

# Remove worktrees, optionally deleting their branches, and return what was removed.
#
# git refuses a worktree with uncommitted or untracked changes unless you pass
# --force. Locked worktrees and the main worktree are refused. When the
# current directory is inside a removed worktree, the shell moves to the main
# worktree first.
@example "Remove a worktree by branch name" { gwt remove fix_parser }
@example "Remove a worktree and its merged branch" { gwt remove fix_parser --delete-branch }
@example "Remove linked worktrees with no commit in four weeks" { gwt list | where not main and committed < ((date now) - 4wk) | gwt remove }
export def --env "gwt remove" [
    ...worktrees: string@complete-linked-worktree # Worktrees by path, name, or branch; rows or paths from pipeline input also work
    --force (-f) # Remove even with uncommitted or untracked changes
    --delete-branch (-d) # Then delete the branch with `git branch -d` (refuses unmerged branches)
    --force-delete-branch (-D) # Then delete the branch with `git branch -D`, even if unmerged
]: [
    nothing -> table
    string -> table
    list<string> -> table
    record -> table
    table -> table
] {
    let input = $in
    let piped = if $input == null { [] } else if ($input | describe --detailed | get type) == 'list' { $input } else { [$input] }
    let rows = worktrees
    let main = $rows | first
    let targets = $rows
        | find-worktrees $worktrees --to remove
        | append ($rows | find-worktrees $piped --to remove --unspanned)
        | uniq-by path
    if ($targets | is-empty) {
        fail 'no worktree to remove' '' null --hint 'name worktrees by path, directory name, or branch, or pipe rows from `gwt list`'
    }
    # Leave a worktree before deleting it, so the shell never sits in a removed directory.
    if ($targets | any {|wt| $wt.current }) {
        cd $main.path
    }
    let force_args = if $force { ['--force'] } else { [] }
    let branch_flag = if $force_delete_branch { '-D' } else if $delete_branch { '-d' }
    # A `for` loop: git's error for one worktree surfaces as is, and nothing
    # downstream (such as `first`) can stop the loop partway.
    mut removed = []
    for wt in $targets {
        git-run -C $main.path worktree remove ...$force_args $wt.path | ignore
        let branch_deleted = $branch_flag != null and $wt.branch != null
        if $branch_deleted {
            git-run -C $main.path branch $branch_flag $wt.branch | ignore
        }
        $removed ++= [{name: $wt.name, branch: $wt.branch, path: $wt.path, branch_deleted: $branch_deleted}]
    }
    $removed
}

# Move a linked worktree to a new directory and return its new row.
#
# When `new_path` is an existing directory the worktree moves inside it, as
# with `git worktree move`. If the shell is inside the worktree, it follows to
# the same subdirectory at the new location.
@example "Rename a worktree directory" { gwt move fix_parser ~/src/worktrees/nushell/parser_fix }
export def --env "gwt move" [
    worktree: string@complete-linked-worktree # Worktree to move, by path, name, or branch
    new_path: path # Destination directory
    --force (-f) # Move onto a destination still registered to a missing worktree
]: nothing -> record {
    let span = (metadata $worktree).span
    let rows = worktrees
    let wt = $rows | find-worktree $worktree $span --to move
    let target = $new_path | path expand
    let dest = if ($target | path type) == dir { $target | path join ($wt.path | path basename) } else { $target }
    let inside = if $wt.current { $env.PWD | path expand | path relative-to $wt.path }
    git-run --span $span -C ($rows | first | get path) worktree move ...(if $force { ['--force'] } else { [] }) $wt.path $dest | ignore
    if $inside != null {
        cd ($dest | path join $inside)
    }
    gwt list --long | find-worktree $dest (metadata $new_path).span
}

# Lock a worktree against prune, move, and remove, and return its updated row.
@example "Lock a worktree on removable storage" { gwt lock usb_work --reason 'on the USB drive' }
export def "gwt lock" [
    worktree: string@complete-unlocked-worktree # Worktree to lock, by path, name, or branch
    --reason (-r): string # Why it is locked; shown by `gwt list --long`
]: nothing -> record {
    let span = (metadata $worktree).span
    let wt = worktrees | find-worktree $worktree $span
    git-run --span $span worktree lock ...(if $reason != null { ['--reason' $reason] } else { [] }) $wt.path | ignore
    gwt list --long | find-worktree $wt.path $span
}

# Unlock a worktree and return its updated row.
export def "gwt unlock" [
    worktree: string@complete-locked-worktree # Worktree to unlock, by path, name, or branch
]: nothing -> record {
    let span = (metadata $worktree).span
    let wt = worktrees | find-worktree $worktree $span
    git-run --span $span worktree unlock $wt.path | ignore
    gwt list --long | find-worktree $wt.path $span
}

# Delete git's records of worktrees whose directories are gone, and return them.
#
# Locked worktrees are kept. `path` is where the worktree was, read from its
# record before it goes; it is null when git's record lacks it.
@example "See what would be pruned" { gwt prune --dry-run }
@example "Prune only worktrees missing for over a week" { gwt prune --expire 1.week.ago }
export def "gwt prune" [
    --dry-run (-n) # Report what would be pruned without pruning
    --expire: string # Only prune worktrees missing since before this date, e.g. 1.week.ago
]: nothing -> table {
    let expire_args = if $expire == null { [] } else { ['--expire' $expire] }
    let common = git-run rev-parse --path-format=absolute --git-common-dir | str trim
    # git prints `Removing worktrees/<id>: <reason>` to stderr; LC_ALL=C keeps it in English.
    let report = with-env {LC_ALL: C} { ^git worktree prune --dry-run --verbose ...$expire_args | complete }
    if $report.exit_code != 0 {
        fail ($report.stderr | str trim) '' null
    }
    let pruned = $report.stderr
        | lines
        | parse --regex '^Removing worktrees/(?<name>.+?): (?<reason>.+)$'
        | each {|it|
            # The record's gitdir file holds `<worktree>/.git`, relative to the record with --relative-paths.
            let record = $common | path join worktrees $it.name
            let gitdir = try { open --raw ($record | path join gitdir) | str trim } catch { null }
            let path = if $gitdir != null { $record | path join $gitdir | path expand --no-symlink | path dirname }
            {name: $it.name, path: $path, reason: $it.reason}
        }
    if not $dry_run and ($pruned | is-not-empty) {
        git-run worktree prune ...$expire_args | ignore
    }
    $pruned
}

# Reconnect worktrees moved by hand, and return each repair git made or could not make.
#
# With no paths, git repairs the main worktree's links to every linked
# worktree. Pass the new location of a linked worktree moved by hand to
# reconnect it.
@example "Reconnect a worktree moved with mv" { gwt repair ~/src/worktrees/nushell/fix_parser }
export def "gwt repair" [
    ...paths: path # Linked worktree directories to reconnect
]: nothing -> table {
    let result = with-env {LC_ALL: C} {
        ^git worktree repair ...($paths | each { path expand }) | complete
    }
    # git reports `repair: <problem>: <path>` on stdout and `error: <problem>: <path>` on stderr.
    let pattern = '^(?<status>repair|error): (?<problem>.+?): (?<path>.+)$'
    let reports = ($result.stdout | lines) ++ ($result.stderr | lines)
        | parse --regex $pattern
        | update status { if $in == 'repair' { 'repaired' } else { 'failed' } }
    if $result.exit_code != 0 and ($reports | where status == failed | is-empty) {
        fail ($result.stderr | str trim) '' null
    }
    $reports
}

# Change to a worktree, picked interactively when none is named.
@example "Go to a worktree by branch" { gwt cd fix_parser }
@example "Back to the main worktree" { gwt cd --main }
export def --env "gwt cd" [
    worktree?: string@complete-worktree # Worktree by path, name, or branch (default: choose from a fuzzy list)
    --main (-m) # Go to the main worktree
]: nothing -> nothing {
    let rows = worktrees
    let target = if $main {
        if $worktree != null {
            fail 'pass a worktree or --main, not both' 'extra worktree' (metadata $worktree).span
        }
        $rows | first
    } else if $worktree != null {
        $rows | find-worktree $worktree (metadata $worktree).span
    } else {
        $rows | where not prunable | select name branch path | input list --fuzzy 'worktree'
    }
    if $target != null {
        cd $target.path
    }
}

export alias wtl = gwt list
export alias wtll = gwt list --long
export alias wts = gwt status
export alias wtcd = gwt cd

# Completions for raw `git worktree` calls. Flags follow git 2.56; nushell
# passes flags these signatures leave out straight through to git.

export extern "git worktree add" [
    path?: path # Directory for the new worktree
    commit_ish?: string@complete-commitish # Branch or commit to check out
    -b: string # Create a new branch
    -B: string # Create or reset a branch
    --force (-f) # Check out a branch even if another worktree has it
    --orphan # Create an unborn branch
    --detach (-d) # Detach HEAD at the named commit
    --checkout # Populate the new worktree
    --no-checkout # Do not populate the new worktree
    --lock # Keep the new worktree locked
    --reason: string # Reason for locking
    --quiet (-q) # Suppress progress reporting
    --track # Set up tracking mode (see git-branch(1))
    --no-track # Do not set up tracking
    --guess-remote # Match the new branch name with a remote-tracking branch
    --no-guess-remote # Do not guess a remote-tracking branch
    --relative-paths # Link the worktree with relative paths
    --no-relative-paths # Link the worktree with absolute paths
]

export extern "git worktree list" [
    --porcelain # Machine-readable output
    --verbose (-v) # Show lock and prune reasons
    --expire: string # Mark missing worktrees older than this as prunable
    -z # Terminate porcelain fields with NUL
]

export extern "git worktree lock" [
    worktree?: string@complete-unlocked-worktree # Worktree to lock
    --reason: string # Reason for locking
]

export extern "git worktree move" [
    worktree?: string@complete-linked-worktree # Worktree to move
    new_path?: path # Destination directory
    --force (-f) # Move even if dirty or locked (twice for locked)
    --relative-paths # Link the worktree with relative paths
    --no-relative-paths # Link the worktree with absolute paths
]

export extern "git worktree prune" [
    --dry-run (-n) # Report without removing
    --verbose (-v) # Report pruned worktrees
    --expire: string # Prune only worktrees missing since before this date
]

export extern "git worktree remove" [
    worktree?: string@complete-linked-worktree # Worktree to remove
    --force (-f) # Remove even if dirty (twice for locked)
]

export extern "git worktree repair" [
    ...paths: path # Linked worktree directories to reconnect
    --relative-paths # Link worktrees with relative paths
    --no-relative-paths # Link worktrees with absolute paths
]

export extern "git worktree unlock" [
    worktree?: string@complete-locked-worktree # Worktree to unlock
]
