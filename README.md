# gwt

`gwt` is a set of Nushell commands for `git worktree` that return tables and records instead of text. They complete worktree names, branches, and tags. Read-only commands get short aliases, and commands that change worktrees get abbreviations.

```nushell
> gwt list
╭───┬────────────┬────────────┬─────────┬─────────────┬─────────┬───────┬────────┬──────────╮
│ # │    name    │   branch   │  head   │  committed  │ current │ main  │ locked │ prunable │
├───┼────────────┼────────────┼─────────┼─────────────┼─────────┼───────┼────────┼──────────┤
│ 0 │ nushell    │ main       │ 451387b │ 2 days ago  │ false   │ true  │ false  │ false    │
│ 1 │ 0.116.0    │            │ 8bcb11f │ 3 weeks ago │ false   │ false │ false  │ false    │
│ 2 │ backport   │ backport   │ 8bcb11f │ 3 weeks ago │ false   │ false │ true   │ false    │
│ 3 │ fix_parser │ fix_parser │ 7d07c61 │ 3 hours ago │ true    │ false │ false  │ false    │
╰───┴────────────┴────────────┴─────────┴─────────────┴─────────┴───────┴────────┴──────────╯
```

Each command passes its arguments to git one by one, checks git's exit code, and parses git's porcelain output into Nushell values. The results filter and pipe like any other table:

```nushell
gwt status | where not clean
gwt list | where not main and committed < ((date now) - 4wk) | gwt remove
```

## Requirements

- Nushell 0.116.2, which this module is written for and tested with. The abbreviations need Nushell 0.113 or newer.
- git 2.36 or newer, for `git worktree list --porcelain -z`. Tested with git 2.56. `gwt add --orphan` needs git 2.42.

## Install

Clone this repository and add one line to `config.nu`:

```nushell
use ~/src/nu-git-worktree/gwt.nu *
```

Put that line below any `$env.config = { ... }` assignment. The module adds its abbreviations to `$env.config.abbreviations` when it loads, and assigning a whole new `$env.config` afterwards throws them away.

Import it with `*`. Every command is `gwt` or `gwt <subcommand>`, so `*` can't shadow a builtin such as `move`. Without `*`, Nushell would prefix the aliases with the module name (`gwt wtl`).

## Commands

| Command                            | Alias                    | Abbreviation           | Returns                                                      |
| ---------------------------------- | ------------------------ | ---------------------- | ------------------------------------------------------------ |
| `gwt list [--long]`                | `wtl`, `wtll` (`--long`) |                        | table of worktrees                                           |
| `gwt status [...worktrees]`        | `wts`                    |                        | table of upstream, ahead/behind, and change counts           |
| `gwt cd [worktree] [--main]`       | `wtcd`                   |                        | nothing; changes directory                                   |
| `gwt add <branch> [path]`          |                          | `wta`, `wtac` (`--cd`) | record of the new worktree                                   |
| `gwt remove ...worktrees`          |                          | `wtrm`                 | table of removed worktrees                                   |
| `gwt move <worktree> <new_path>`   |                          | `wtmv`                 | record of the moved worktree                                 |
| `gwt lock <worktree> [--reason]`   |                          | `wtlk`                 | record of the locked worktree                                |
| `gwt unlock <worktree>`            |                          | `wtul`                 | record of the unlocked worktree                              |
| `gwt prune [--dry-run] [--expire]` |                          | `wtp`                  | table of pruned worktrees                                    |
| `gwt repair [...paths]`            |                          |                        | table of repairs                                             |
| `gwt`                              |                          |                        | table of these commands with their aliases and abbreviations |

An alias runs as soon as you press enter. An abbreviation expands into the full command in the line editor first. [Aliases and abbreviations](#aliases-and-abbreviations) explains the split.

`help gwt <subcommand>` shows each command's flags and examples. `gwt` on its own lists the commands:

```nushell
> gwt
╭───┬────────────┬───────────┬───────────────┬───────────────────────────────────────────────────────────────────────────────────────╮
│ # │  command   │  aliases  │ abbreviations │                                      description                                      │
├───┼────────────┼───────────┼───────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
│ 0 │ gwt add    │           │ wta, wtac     │ Create a worktree for a branch and return its row from `gwt list --long`.             │
│ 1 │ gwt cd     │ wtcd      │               │ Change to a worktree, picked interactively when none is named.                        │
│ 2 │ gwt list   │ wtl, wtll │               │ List the repository's worktrees, main worktree first.                                 │
│ 3 │ gwt lock   │           │ wtlk          │ Lock a worktree against prune, move, and remove, and return its updated row.          │
│ 4 │ gwt move   │           │ wtmv          │ Move a linked worktree to a new directory and return its new row.                     │
│ 5 │ gwt prune  │           │ wtp           │ Delete git's records of worktrees whose directories are gone, and return them.        │
│ 6 │ gwt remove │           │ wtrm          │ Remove worktrees, optionally deleting their branches, and return what was removed.    │
│ 7 │ gwt repair │           │               │ Reconnect worktrees moved by hand, and return each repair git made or could not make. │
│ 8 │ gwt status │ wts       │               │ Show each worktree's branch, upstream, ahead/behind counts, and changes.              │
│ 9 │ gwt unlock │           │ wtul          │ Unlock a worktree and return its updated row.                                         │
╰───┴────────────┴───────────┴───────────────┴───────────────────────────────────────────────────────────────────────────────────────╯
```

Wherever a command takes a worktree, you can name it by path (absolute, or relative to the current directory), by directory name, or by the branch it has checked out. If a name matches more than one worktree, the error lists their paths so you can pick one.

### gwt list

Columns are `name`, `branch` (null when detached), `head` (abbreviated commit), `committed` (commit date), `current` (contains the current directory), `main`, `locked`, and `prunable`. The path is left out to keep the table narrow. `--long` (alias `wtll`) adds `path`, `commit` (the full id), `subject`, `bare`, `detached`, `lock_reason`, and `prune_reason`.

The listing runs three git processes no matter how many worktrees there are: one `git worktree list --porcelain -z`, one `git rev-parse` to find the current worktree, and one `git log --no-walk` for every HEAD's date and subject.

### gwt status

Runs `git status --porcelain=v2 --branch` in every worktree in parallel. It passes `--no-optional-locks`, so checking status never rewrites a worktree's index. Bare and prunable worktrees have no files to check and are left out.

```nushell
> gwt status | reject path
╭───┬────────────┬────────────┬───────────────────┬───────┬────────┬────────┬──────────┬───────────┬───────────┬───────╮
│ # │    name    │   branch   │     upstream      │ ahead │ behind │ staged │ modified │ untracked │ conflicts │ clean │
├───┼────────────┼────────────┼───────────────────┼───────┼────────┼────────┼──────────┼───────────┼───────────┼───────┤
│ 0 │ nushell    │ main       │ origin/main       │     0 │      0 │      0 │        0 │         0 │         0 │ true  │
│ 1 │ 0.116.0    │            │                   │       │        │      0 │        0 │         0 │         0 │ true  │
│ 2 │ backport   │ backport   │                   │       │        │      0 │        0 │         0 │         0 │ true  │
│ 3 │ fix_parser │ fix_parser │ origin/fix_parser │     1 │      0 │      0 │        1 │         1 │         0 │ false │
╰───┴────────────┴────────────┴───────────────────┴───────┴────────┴────────┴──────────┴───────────┴───────────┴───────╯
```

`ahead` and `behind` are null for a branch with no upstream.

### gwt add

The `branch` argument decides what gets checked out:

- An existing local branch is checked out as it is.
- A branch that only a remote has becomes a local branch that tracks it. Write `topic` when one remote has it, or `origin/topic` to choose the remote.
- Any other name becomes a new branch, started from `--base` or from HEAD of the worktree you run the command in.

`--detach` checks out any commit, branch, or tag as a detached HEAD, and `--orphan` creates an unborn branch. `--lock` and `--reason` lock the worktree as git creates it. `--cd` moves the shell into it.

Without a path, the worktree goes in `<root>/<repo>/<branch>`. `<root>` is `~/src/worktrees` unless you set `$env.GWT_ROOT`, and `<repo>` is the main worktree's directory name. Where the main worktree lives doesn't matter:

| Main worktree        | Branch           | New worktree                             |
| -------------------- | ---------------- | ---------------------------------------- |
| `~/src/nushell`      | `abc`            | `~/src/worktrees/nushell/abc`            |
| `~/src/nushell`      | `feature/tables` | `~/src/worktrees/nushell/feature-tables` |
| `~/work/clients/api` | `fix_auth`       | `~/src/worktrees/api/fix_auth`           |

A `/` in the branch name becomes `-`, which keeps every worktree one directory deep.

To use a different root for every repository, set `GWT_ROOT` in `env.nu` or `config.nu`. A leading `~` is expanded:

```nushell
$env.GWT_ROOT = '~/worktrees'
```

To put a single worktree somewhere else, pass its path as the second argument:

```nushell
gwt add abc /tmp/abc
```

Before git touches the disk, the command checks a new branch name with `git check-ref-format`. It rejects `--base` for a branch that already exists instead of silently ignoring it. The result is the new worktree's `gwt list --long` row plus `new_branch`:

```nushell
gwt add backport --base 0.116.0 --cd
gwt add origin/feature
gwt add 0.116.0 --detach
```

### gwt remove

Takes worktrees as arguments, or as rows from pipeline input, so the output of `gwt list`, `gwt list --long`, and `gwt status` can go straight in. A row names its worktree by `path`, or by `name` when it has no path, as with plain `gwt list`. If two worktrees share a directory name, pipe `gwt list --long` instead so the paths tell them apart.

- git refuses to remove a worktree with modified or untracked files. `--force` overrides that.
- The main worktree and locked worktrees are always refused. git removes a locked worktree when given `--force` twice, but this command asks you to run `gwt unlock` first, so a lock still protects the worktree after you add `--force`.
- `--delete-branch` (`-d`) also deletes the branch with `git branch -d`, which refuses unmerged branches. `--force-delete-branch` (`-D`) uses `git branch -D`.
- If the shell is inside a worktree being removed, it changes to the main worktree first.

### gwt move, lock, unlock

`gwt move` follows `git worktree move`, so an existing directory as the destination means "move it inside that directory". If the shell is inside the worktree, it follows to the same subdirectory at the new location. Like `remove`, it refuses locked worktrees and the main worktree.

`gwt lock` and `gwt unlock` return the worktree's updated row. `gwt list --long` shows the reason.

### gwt prune

Runs git's dry run first and reads where each stale worktree used to be from git's records, then prunes. `--dry-run` stops after the report. `--expire 1.week.ago` limits pruning to worktrees missing for longer than that. The table has `name` (git's id for the worktree), `path`, and `reason`.

### gwt repair

Wraps `git worktree repair` and turns its `repair:` and `error:` lines into a table with `status` (`repaired` or `failed`), `problem`, and `path`. Pass the new location of a worktree you moved with `mv` to reconnect it.

### gwt cd

`gwt cd fix_parser` changes to that worktree, and `gwt cd --main` to the main one. With no argument it opens a fuzzy picker.

## Aliases and abbreviations

Commands that only read or navigate are aliases. They run as typed and work in pipelines.

| Alias (runs on enter) | Runs              |
| --------------------- | ----------------- |
| `wtl`                 | `gwt list`        |
| `wtll`                | `gwt list --long` |
| `wts`                 | `gwt status`      |
| `wtcd`                | `gwt cd`          |

Commands that create, change, or delete worktrees are abbreviations. Nushell expands an abbreviation in the line editor when you press space or enter. You see the full command before it runs, you can add flags to it, and history records the full command, not the abbreviation.

| Abbreviation (expands first) | Expands to     |
| ---------------------------- | -------------- |
| `wta`                        | `gwt add`      |
| `wtac`                       | `gwt add --cd` |
| `wtrm`                       | `gwt remove`   |
| `wtmv`                       | `gwt move`     |
| `wtlk`                       | `gwt lock`     |
| `wtul`                       | `gwt unlock`   |
| `wtp`                        | `gwt prune`    |

`abbr list` shows them. If you already have an abbreviation with one of these names, yours wins. To drop one, remove it below the `use` line:

```nushell
$env.config.abbreviations = $env.config.abbreviations | reject wtp
```

## Completions

- Worktree arguments complete worktree names, described by branch, state, and path. `remove` and `move` offer linked worktrees only, `lock` offers unlocked ones, and `unlock` offers locked ones.
- `gwt add <branch>` completes local branches that no worktree has checked out, newest first, then remote branches that have no local branch of the same name.
- `--base` completes local branches, remote branches, and tags.

The module also defines `extern` signatures for the raw `git worktree` subcommands (`add`, `list`, `lock`, `move`, `prune`, `remove`, `repair`, and `unlock`), so `git worktree remove <Tab>` completes as well. Nushell passes flags those signatures leave out straight through to git. If another module defines the same externs, the one you import last wins.

## Tests

```sh
nu --no-config-file test.nu
```

The script builds a throwaway repository with two bare remotes under `mktemp`, points `GWT_ROOT` inside it, ignores your global and system git config, and runs every command against it, error cases included. It deletes the fixture once every check passes.

## License

MIT. See [LICENSE](LICENSE).
