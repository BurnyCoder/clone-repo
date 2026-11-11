# AGENTS.md: working on clone-repo

Notes for contributors and AI coding agents. Read [README.md](README.md) for what the tool does and [docs/how-it-works.md](docs/how-it-works.md) for the replay mechanics.

## Ground rules

- **Never commit secrets or real repo names.**
  - `.env`, `*.secrets.env`, `work/` and `logs/` are git-ignored.
  - Docs and tests use placeholders (`source-owner/project`, `src-owner/project`).
  - Before pushing, check with `git grep -nE 'gh[opsu]_[A-Za-z0-9]{10,}|password='`.
- **Exact or refuse.** A new feature must either reproduce something exactly and be checked in `verify`, or be refused in `preflight` / `check_merges` with a pointer to [docs/roadmap.md](docs/roadmap.md). Never drop data without saying so.
- **Never remove the destination's own work.**
  - A destination commit that no source branch or tag contains was made there, and no push may delete or move a branch that holds one (`ref_state` in `lib/common.sh`).
  - Every push goes through `push_ref` or `sync_refs`, with a `--force-with-lease` from `lease`. Never use `--force`, `--mirror` or a `+` refspec: git ignores a stale lease for a `+` refspec.
- **LF line endings.** `.gitattributes` forces `eol=lf`, because bash fails on CRLF scripts. Executable bits are tracked with `git update-index --chmod=+x` (needed on Windows).
- **Workflow:** feature branch → PR → merge. TDD: change `test/*.bats` first and watch it fail.
- **Comments:** every file and function starts with a comment explaining what it does here and where it fits overall. Non-obvious commands link to the docs they follow.

## Where things are

- `clone-repo.sh` is the only entry point. `PHASES` lists the phase functions in run order, and `main` runs all of them or the named ones.
- `lib/<phase>.sh` holds one phase function each. To add a phase, write `lib/<name>.sh` defining `<name>()` and add it to `PHASES`. `clone-repo.sh` sources every `lib/*.sh`.
- `lib/common.sh` has the shared helpers:
  - `log` / `die` / `run_logged` for timestamped logging,
  - `GIT`, git with gh as credential helper,
  - `srcgit`,
  - `fetch_dest`, which snapshots the destination's branches and tags into the bare clone as `refs/dest/*`,
  - `dest_tip`, `from_source` and `ref_state` (same / missing / behind / ahead / diverged), which compare a destination ref with the source,
  - `lease` and `push_ref`, the only ways to push,
  - `merged_prs_tsv`, the one source-PR query that `check_merges`, `replay_prs` and `sync_refs` share,
  - `wait_merged`.
- `lib/config.sh` (`load_config`) holds every setting and its default, documented in `.env.example`.
- jq filters that are too long to read inline are named constants next to their phase, for example `PR_PROBLEMS_JQ` and `SETTINGS_FLAGS_JQ`. gh runs them with `--jq`, so the tool needs no jq binary.

## Testing

- `npm install` once, then `npm test` (or `./node_modules/.bin/bats test`). The 28 tests take about 8 minutes on Windows, mostly git process start-up.
- `test/helpers.bash` (`setup`) creates, per test:
  - a real source repo, where `make_pr N branch [squash]` merges like GitHub,
  - an empty bare destination, where `dest_commit BRANCH MSG` adds "their" commits,
  - stub state in `$STUB_DIR`.

  It exports the config, with `SOURCE_GIT_URL` / `DEST_GIT_URL` pointing at those local repos.
- `test/stub/gh` is a fake gh. It matches the command line against the call shapes clone-repo uses, and **fails on any call it doesn't know**. So when you add a gh call, add its case to the stub. Calls are logged to `$STUB_DIR/calls.log`, and the `calls REGEX` helper counts them. The stub emulates GitHub with real git:
  - it refuses to create a PR whose head is already in its base,
  - it reports MERGED only once the head is reachable from the base,
  - a PR's merge commit is the oldest merge on the ancestry path from its head to its base.

  Some stub files make things happen:
  - a line appended to `dest_prs` is a PR opened in the destination,
  - `race_on_create` pushes to the destination's `main` right after a PR is opened,
  - `fail_second_comment` makes a comment post fail once.
- **Mutation checks:**
  - If you swap the order in `replay_prs` (for example, push the merge commit before opening the PR), the full-run test must fail.
  - If `from_source` always says yes, the tests in `test/destination.bats` about the destination's own commits must fail.

  Both were checked. They prove the tests check the order and the protection.
- **Real-GitHub check:** before merging a change to `sync_refs`, `replay_prs` or `verify`, sync a small source into a throwaway destination with work of its own: an open PR, a branch, and, as a second step, a commit merged into its `main`. Read the log. Each case must end the way the tests say. That check was done on 2026-11-11 with this repo as the source.
- The jq filters run only inside real gh, so the stub can't test them. Check changes to them with a real run:
  - `./clone-repo.sh preflight` on a repo with only merged PRs should say `preflight: OK`.
  - On a big public repo such as `cli/cli` it must list every problem category.
- Before a release, do a real full run (or sync) of a test repo and read the log. It must end with `ALL CHECKS PASSED`.

## Gotchas

- **Numbers.**
  - A copy keeps its original number only while the destination has no PRs or issues of its own. After that, copies take the next free number and get a `Copied from` link (`NOTE_JQ`), which `verify` strips again before comparing bodies.
  - A sync knows which PRs are copied by merge commit, so it doesn't matter which numbers they got.
  - If a run stops half way, the next run reuses the open copy (same head commit) and posts only its missing comments. GitHub refuses a second PR for the same branches.
- **Why not `git push --mirror`.** It deletes every destination branch the source lacks. On 2026-11-11 that deleted a collaborator's PR branch in a shared destination, and GitHub closed the PR. The branch was restored from `refs/pull/<n>/head` and the PR reopened. `sync_refs` now pushes ref by ref.
- **`refs/dest/*` live only in `work/src.git`.** Never push all refs from it: `--mirror` would publish the snapshot.
- **A `+` refspec beats a lease.** With git 2.56, `push --force-with-lease=<ref>:<stale> +<sha>:<ref>` still force-updated the ref. Without the `+`, the same push was rejected ("stale info"). Tested locally, 2026-11-11.
- **The source changing during a run.** If a PR is opened or merged between `preflight` and `verify`, the run refuses it or `verify` fails. Run again once it's quiet. This has been seen in practice. Ref checks use the bare clone, i.e. the source as it was at the start, so a branch pushed to the source mid-run doesn't fail `verify`.
- **Merge detection is asynchronous.** It usually takes a few seconds. Raise `MERGE_TIMEOUT_SECONDS` if GitHub is slow.
- **`gh issue list` fails on repos with issues disabled.** `preflight` counts that as zero issues. Numbering gaps are still caught by the 1..N check.
- **Windows:**
  - `bats load` rejects `C:/` paths, which is how npm on Windows passes them. That's why test files use `source "$BATS_TEST_DIRNAME/helpers.bash"`.
  - The fixture uses `core.autocrlf=false` to keep git quiet.
  - Paths like `/c/...` passed to `gh.exe` are converted by Git Bash automatically.
