# test/helpers.bash: shared setup for the bats tests (loaded with `load helpers`).
# Global context: each test gets a fresh temp dir holding
#   - source/   a real git repo playing the GitHub source, with PRs merged by `git merge --no-ff`
#               (what GitHub's "Create a merge commit" button does: https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/about-pull-request-merges),
#   - dest.git  an empty bare repo playing the GitHub destination,
#   - stub/     state for the fake gh in test/stub/gh.
# clone-repo is pointed at them through SOURCE_GIT_URL / DEST_GIT_URL, so real git pushes are tested.
# bats docs: https://bats-core.readthedocs.io/en/stable/writing-tests.html

ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"   # repo root: where clone-repo.sh lives

# setup: runs before every test (bats hook). Builds the sandbox and exports clone-repo's config.
setup() {
  T="$BATS_TEST_TMPDIR"
  export STUB_DIR="$T/stub"; mkdir -p "$STUB_DIR"
  export PATH="$ROOT/test/stub:$PATH"                     # fake gh first on PATH
  export SOURCE_REPO=src-owner/project DEST_REPO=dst-owner/project
  export SOURCE_GIT_URL="$T/source" DEST_GIT_URL="$T/dest.git"
  export WORK_DIR="$T/work" LOG_DIR="$T/logs"
  export ENV_FILE="$T/none.env"                           # no .env unless a test writes one
  export POLL_SECONDS=0 MERGE_TIMEOUT_SECONDS=5
  unset SECRETS_ENV_FILE DEST_VISIBILITY
  git init -q --bare -b main "$DEST_GIT_URL"
  git init -q -b main "$SOURCE_GIT_URL"
  src commit -q --allow-empty -m "Initial commit"
}

# src ARGS...: run git inside the source repo with a fixed test identity.
src() { git -C "$SOURCE_GIT_URL" -c user.name=Test -c user.email=test@example.com "$@"; }

# make_pr N BRANCH [squash]: add a PR branch with one commit and merge it into main the way GitHub does.
# Records "N, merge SHA, head SHA, head ref, base ref" in prs.tsv, which the gh stub serves as the
# source's merged-PR list. The branch is deleted afterwards, like "Delete branch" after a merge.
make_pr() {
  local n="$1" ref="$2" head merge
  src checkout -q -b "$ref"
  echo "$ref" > "$SOURCE_GIT_URL/$n.txt"; src add "$n.txt"; src commit -q -m "Work for PR $n"
  head="$(src rev-parse HEAD)"
  src checkout -q main
  if [ "${3:-}" = squash ]; then src merge -q --squash "$ref"; src commit -q -m "PR $n squashed"
  else src merge -q --no-ff -m "Merge pull request #$n from src-owner/$ref" "$ref"; fi
  merge="$(src rev-parse HEAD)"
  src branch -q -D "$ref"
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$merge" "$head" "$ref" main >> "$STUB_DIR/prs.tsv"
}

# refs URL: branch and tag refs of a repo, the same filter verify uses.
refs() { git ls-remote "$1" | grep -E 'refs/(heads|tags)/' | sort; }

# run_clone ARGS...: run the tool under bats `run`, output goes to $output / $status.
run_clone() { run bash "$ROOT/clone-repo.sh" "$@"; }

# calls PATTERN: number of recorded gh calls matching an extended regex.
calls() { grep -cE "$1" "$STUB_DIR/calls.log" || true; }
