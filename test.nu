# Fixture tests for gwt.nu; run from anywhere: nu --no-config-file test.nu
#
# Builds a throwaway repository with two bare remotes under `mktemp`, so it
# never touches a real checkout. Global and system git config are ignored.

use std/assert
use gwt.nu *

const MODULE = path self gwt.nu

# The message of the error `code` raises; fails when it raises none.
def error-of [code: closure]: nothing -> string {
    let message = try { do $code | ignore; null } catch {|e| $e.msg }
    if $message == null {
        error make {msg: 'expected an error, got none'}
    }
    $message
}

def row-named [name: string]: nothing -> record {
    gwt list --long | where name == $name | first
}

$env.GIT_CONFIG_GLOBAL = '/dev/null'
$env.GIT_CONFIG_NOSYSTEM = '1'
$env.GIT_AUTHOR_NAME = 'test'
$env.GIT_AUTHOR_EMAIL = 'test@example.com'
$env.GIT_COMMITTER_NAME = 'test'
$env.GIT_COMMITTER_EMAIL = 'test@example.com'

let root = mktemp --directory | path expand
let main = $root | path join repo
let wts = $root | path join worktrees repo
# Keep every default-path worktree inside the fixture, never in ~/src/worktrees.
$env.GWT_ROOT = $root | path join worktrees
cd $root
^git init --quiet --bare --initial-branch=main origin.git
^git init --quiet --bare --initial-branch=main upstream.git
^git init --quiet --initial-branch=main repo
cd repo
^git remote add origin ../origin.git
^git remote add upstream ../upstream.git
'one' | save a.txt
^git add a.txt
^git commit --quiet -m first
^git tag v1
^git commit --quiet --allow-empty -m second
^git push --quiet origin main
^git switch --quiet -c remote-only
^git commit --quiet --allow-empty -m 'remote only'
^git push --quiet origin remote-only remote-only:remote-two
^git switch --quiet -c shared
^git push --quiet origin shared
^git push --quiet upstream shared
^git switch --quiet main
^git branch --quiet -D remote-only shared
^git fetch --quiet --all
^git branch --quiet --set-upstream-to=origin/main main

print 'list: the main worktree alone'
let list = gwt list
assert equal ($list | columns) [name branch head committed current main locked prunable]
assert equal ($list | length) 1
assert equal $list.0.name repo
assert equal $list.0.branch main
assert equal (gwt list --long).0.path $main
assert ($list.0.main and $list.0.current)
assert equal ($list.0.committed | describe) datetime
assert equal $list.0.head (^git rev-parse --short HEAD | str trim)

print 'add: new branch in the default directory'
let feat = gwt add feat
assert equal $feat.path ($wts | path join feat)
assert equal $feat.branch feat
assert $feat.new_branch
assert equal $feat.commit (^git rev-parse HEAD | str trim)
assert equal ($feat | columns | last) new_branch
assert equal (gwt list | length) 2

print 'add: default root is ~/src/worktrees, and GWT_ROOT overrides it'
let home = $root | path join home
let homed = with-env {HOME: $home} {
    ^$nu.current-exe --no-config-file -c $"hide-env GWT_ROOT; use '($MODULE)' *; let a = \(gwt add homed).path; $env.GWT_ROOT = '~/alt'; [$a \(gwt add tilde).path] | to nuon"
} | from nuon
assert equal $homed [($home | path join src worktrees repo homed) ($home | path join alt repo tilde)]
assert equal (gwt remove homed tilde | length) 2

print 'add: a / in the branch becomes - in the directory'
assert equal (gwt add team/topic).path ($wts | path join team-topic)

print 'add: remote-only branch becomes a tracking branch'
let tracked = gwt add remote-only
assert $tracked.new_branch
assert equal (^git -C $tracked.path rev-parse --abbrev-ref '@{upstream}' | str trim) origin/remote-only
let two = gwt add origin/remote-two
assert equal $two.branch remote-two
assert equal $two.path ($wts | path join remote-two)
assert equal (^git -C $two.path rev-parse --abbrev-ref '@{upstream}' | str trim) origin/remote-two

print 'add: a branch on two remotes needs the remote named'
assert str contains (error-of { gwt add shared }) 'more than one remote'
assert equal (^git -C (gwt add upstream/shared).path rev-parse --abbrev-ref '@{upstream}' | str trim) upstream/shared

print 'add: --base, --detach, --orphan, explicit path, --lock'
assert equal (gwt add from-tag --base v1).commit (^git rev-parse v1 | str trim)
assert equal (error-of { gwt add feat --base v1 }) '--base only applies when creating a branch'
assert str contains (error-of { gwt add 'bad..name' }) 'not a valid branch name'
assert not ($wts | path join 'bad..name' | path exists)
let detached = gwt add v1 --detach
assert ($detached.detached and $detached.branch == null and not $detached.new_branch)
let orphan = gwt add fresh --orphan
assert ($orphan.commit == null and $orphan.head == null and $orphan.branch == 'fresh')
let explicit = gwt add explicit ../elsewhere/explicit
assert equal $explicit.path ($root | path join elsewhere explicit)
let locked_new = gwt add guarded --reason 'keep me'
assert ($locked_new.locked and $locked_new.lock_reason == 'keep me')
assert str contains (error-of { gwt add feat ../feat-again }) 'already used by worktree'

print 'lock and unlock'
let locked = gwt lock feat --reason "on usb\ndrive"
assert ($locked.locked and $locked.lock_reason == "on usb\ndrive")
assert str contains (error-of { gwt remove feat }) 'is locked'
assert str contains (error-of { gwt move feat ($root | path join nowhere) }) 'is locked'
assert not (gwt unlock feat).locked

print 'status: counts per worktree'
cd $feat.path
'changed' | save --force a.txt
'new' | save new.txt
'staged' | save s.txt
^git add s.txt
let status = gwt status
let feat_status = $status | where name == feat | first
assert equal ($feat_status | reject path upstream ahead behind) {
    name: feat, branch: feat, staged: 1, modified: 1, untracked: 1, conflicts: 0, clean: false
}
let main_status = $status | where name == repo | first
assert ($main_status.clean and $main_status.upstream == 'origin/main' and $main_status.ahead == 0 and $main_status.behind == 0)
assert equal (gwt status feat | length) 1
assert (gwt list | where name == feat | first).current

print 'cd'
gwt cd --main
assert equal $env.PWD $main
gwt cd remote-two
assert equal $env.PWD $two.path

print 'move: rename, into a directory, and follow the shell'
assert equal (gwt move from-tag ($root | path join moved)).path ($root | path join moved)
mkdir ($root | path join box)
assert equal (gwt move moved ($root | path join box)).path ($root | path join box moved)
mkdir ($root | path join box moved sub)
cd ($root | path join box moved sub)
gwt move moved ($root | path join moved2) | ignore
assert equal $env.PWD ($root | path join moved2 sub)

print 'remove: refusals and errors'
assert str contains (error-of { gwt remove feat }) 'modified or untracked'
assert equal (error-of { gwt remove nope }) "no worktree matches 'nope'"
assert equal (error-of { gwt remove repo }) $"cannot remove the main worktree at ($main)"
assert equal (error-of { gwt remove }) 'no worktree to remove'
gwt add dup1 ($root | path join a dup) | ignore
gwt add dup2 ($root | path join b dup) | ignore
assert equal (error-of { gwt remove dup }) "'dup' matches more than one worktree"

print 'remove: --force, branch deletion, the current worktree, pipeline input'
let removed = gwt remove feat --force
assert equal $removed [{name: feat, branch: feat, path: $feat.path, branch_deleted: false}]
assert ($feat.path | path exists | not $in)
assert equal (gwt remove team/topic --delete-branch).0.branch_deleted true
assert ((^git show-ref --verify --quiet refs/heads/team/topic | complete).exit_code != 0)
^git -C $two.path commit --quiet --allow-empty -m unmerged
assert str contains (error-of { gwt remove remote-two --delete-branch }) 'not fully merged'
^git branch -D remote-two | ignore
cd ($root | path join moved2 sub)
gwt remove moved2 | ignore
assert equal $env.PWD $main
assert equal (error-of { gwt list | gwt remove }) $"cannot remove the main worktree at ($main)"
# Plain `gwt list` rows have no path, so they name their worktree by `name`.
assert equal (gwt list | where name == explicit | gwt remove | get name) [explicit]
assert equal (error-of { gwt list | where name == dup | gwt remove }) "'dup' matches more than one worktree"
let piped = gwt list --long | where name == dup | gwt remove
assert equal ($piped | length) 2
assert equal (gwt list | where name == dup) []

print 'prune: a worktree whose directory was deleted'
let gone = gwt add gone
rm --recursive --permanent $gone.path
assert (row-named gone).prunable
let would = gwt prune --dry-run
assert equal ($would | select name path) [{name: gone, path: $gone.path}]
assert str contains $would.0.reason 'non-existent'
assert (row-named gone).prunable
assert equal (gwt prune).name [gone]
assert equal (gwt list | where name == gone) []
assert equal (gwt prune) []

print 'repair: a worktree moved by hand'
let fixme = gwt add fixme
let moved_by_hand = $root | path join hand-moved
mv $fixme.path $moved_by_hand
let repairs = gwt repair $moved_by_hand
assert equal ($repairs | get status) [repaired]
assert equal (row-named hand-moved).branch fixme

print 'overview, shortcuts, and externs'
let overview = gwt
assert equal ($overview | columns) [command aliases abbreviations description]
assert equal ($overview | where command == 'gwt list' | first | select aliases abbreviations) {aliases: 'gwtl, gwtll', abbreviations: ''}
assert equal ($overview | where command == 'gwt add' | first | select aliases abbreviations) {aliases: '', abbreviations: 'gwta, gwtac'}
assert equal (scope commands | where name starts-with 'git worktree ' and type == external | length) 8
let abbrs = abbr list
assert equal ($abbrs | where name == gwtrm | first | get expansion) 'gwt remove'
let kept = ^$nu.current-exe --no-config-file -c $"$env.config.abbreviations = {gwta: 'mine'}; use '($MODULE)' *; abbr list | where name == gwta | get 0.expansion" | str trim
assert equal $kept mine

print 'completers'
let completions = ^$nu.current-exe --no-config-file -c $"source '($MODULE)'; {
    linked: \(complete-linked-worktree | get completions.value),
    locked: \(complete-locked-worktree | get completions.value),
    add: \(complete-add-branch | get completions.value),
    base: \(complete-commitish | get completions.value),
} | to nuon" | from nuon
assert ('repo' not-in $completions.linked and 'guarded' in $completions.linked)
assert equal $completions.locked [guarded]
assert ('feat' in $completions.add and 'remote-two' in $completions.add and 'main' not-in $completions.add)
assert ('v1' in $completions.base and 'origin/main' in $completions.base and 'origin/HEAD' not-in $completions.base)

cd $nu.home-dir
rm --recursive --permanent $root
print 'all gwt tests passed'
