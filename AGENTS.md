# AGENTS.md: working on clone-repo

Notes for contributors and AI coding agents. Read [README.md](README.md) for what the tool does and [docs/how-it-works.md](docs/how-it-works.md) for the replay mechanics.

## Ground rules

- **Never commit secrets or real repo names.**
  - `.env`, `*.secrets.env`, `work/` and `logs/` are git-ignored.
  - Docs and tests use placeholders (`source-owner/project`, `src-owner/project`).
  - Before pushing, check with `git grep -nE 'gh[opsu]_[A-Za-z0-9]{10,}|password='`.
- **Exact or refuse.** A new feature must either reproduce something exactly and be checked in `verify`, or be refused in `preflight` / `check_merges` with a pointer to [docs/roadmap.md](docs/roadmap.md). Never drop data without saying so.
- **LF line endings.** `.gitattributes` forces `eol=lf`, because bash fails on CRLF scripts. Executable bits are tracked with `git update-index --chmod=+x` (needed on Windows).
- **Workflow:** feature branch → PR → merge. TDD: change `test/*.bats` first and watch it fail.
- **Comments:** every file and function starts with a comment explaining what it does here and where it fits overall. Non-obvious commands link to the docs they follow.

## Where things are

- `clone-repo.sh` is the only entry point. `PHASES` lists the phase functions in run order, and `main` runs all of them or the named ones.
- `lib/<phase>.sh` holds one phase function each. To add a phase, write `lib/<name>.sh` defining `<name>()` and add it to `PHASES`. `clone-repo.sh` sources every `lib/*.sh`.
- `lib/common.sh` has the shared helpers:
  - `log` / `die` / `run_logged` for timestamped logging,
  - `GIT`, git with gh as credential helper,
  - `srcgit`, `push_ref`,
  - `merged_prs_tsv`, the one source-PR query that `check_merges` and `replay_prs` share,
  - `wait_merged`.
- `lib/config.sh` (`load_config`) holds every setting and its default, documented in `.env.example`.
- jq filters that are too long to read inline are named constants next to their phase, for example `PR_PROBLEMS_JQ` and `SETTINGS_FLAGS_JQ`. gh runs them with `--jq`, so the tool needs no jq binary.

## Testing

- `npm install` once, then `npm test` (or `./node_modules/.bin/bats test`). The 19 tests take about 2.5 minutes on Windows, mostly git process start-up.
- `test/helpers.bash` (`setup`) creates, per test:
  - a real source repo, where `make_pr N branch [squash]` merges like GitHub,
  - an empty bare destination,
  - stub state in `$STUB_DIR`.

  It exports the config, with `SOURCE_GIT_URL` / `DEST_GIT_URL` pointing at those local repos.
- `test/stub/gh` is a fake gh. It matches the command line against the call shapes clone-repo uses, and **fails on any call it doesn't know**. So when you add a gh call, add its case to the stub. Calls are logged to `$STUB_DIR/calls.log`, and the `calls REGEX` helper counts them. The stub emulates GitHub with real git:
  - it refuses to create a PR whose head is already in its base,
  - it reports MERGED only once the head is reachable from the base.
- **Mutation check:** if you swap the order in `replay_prs`, for example push the merge commit before opening the PR, the full-run test must fail. That proves the tests check the order.
- The jq filters run only inside real gh, so the stub can't test them. Check changes to them with a real run:
  - `./clone-repo.sh preflight` on a repo with only merged PRs should say `preflight: OK`.
  - On a big public repo such as `cli/cli` it must list every problem category.
- Before a release, do a real full run (or sync) of a test repo and read the log. It must end with `ALL CHECKS PASSED`.

## Gotchas

- **PR numbers can't be reused.** If a run stops halfway, re-running skips the PRs already created and replays the rest. If something else took a number in the destination meanwhile, `replay_prs` stops with "created PR #X, expected #N". Then the only fix is to delete the destination and start again. Deleting needs the `delete_repo` gh scope (`gh auth refresh -s delete_repo`), so ask the owner first.
- **The source changing during a run.** If a PR is opened or merged between `preflight` and `verify`, the run refuses it or `verify` fails. Run again once it's quiet. This has been seen in practice.
- **Merge detection is asynchronous.** It usually takes a few seconds. Raise `MERGE_TIMEOUT_SECONDS` if GitHub is slow.
- **`gh issue list` fails on repos with issues disabled.** `preflight` counts that as zero issues. Numbering gaps are still caught by the 1..N check.
- **Windows:**
  - `bats load` rejects `C:/` paths, which is how npm on Windows passes them. That's why test files use `source "$BATS_TEST_DIRNAME/helpers.bash"`.
  - The fixture uses `core.autocrlf=false` to keep git quiet.
  - Paths like `/c/...` passed to `gh.exe` are converted by Git Bash automatically.
