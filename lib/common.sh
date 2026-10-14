# lib/common.sh: helpers every phase uses (logging, git with gh credentials, ref pushes, merge polling).
# Global context: sourced by clone-repo.sh before the phase files. Nothing runs at source time except
# defining the GIT array. Config values ($WORK_DIR, $DEST_GIT_URL, $LOG...) come from lib/config.sh.

# log MSG...: print one timestamped line to the terminal and append it to this run's log file.
# `tee -a` writes to both at once (https://www.gnu.org/software/coreutils/manual/html_node/tee-invocation.html).
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "${LOG:-/dev/null}"; }

# die MSG...: log an error and stop the whole run (exit works because phases run in the main shell).
die() { log "ERROR: $*" >&2; exit 1; }

# run_logged CMD...: run a command and log each line it prints, with timestamps. Under `set -o pipefail`
# (set in clone-repo.sh) the pipeline fails when CMD fails, so `set -e` still stops the run.
# Source: https://www.gnu.org/software/bash/manual/bash.html#Pipelines
run_logged() { "$@" 2>&1 | while IFS= read -r line; do log "  $line"; done; }

# GIT: git that uses gh's token for github.com, for this process only. The first, empty credential.helper
# resets the helper list (https://git-scm.com/docs/gitcredentials#_custom_helpers). The second makes gh the
# helper (https://cli.github.com/manual/gh_auth_git-credential). gh's token has the `workflow` scope that
# GitHub requires to push commits touching .github/workflows. Global git config is never modified.
GIT=(git -c credential.helper= -c 'credential.helper=!gh auth git-credential')

# srcgit ARGS...: git inside the bare clone of the source made by clone_source.
srcgit() { git -C "$WORK_DIR/src.git" "$@"; }

# push_ref SHA BRANCH: point BRANCH in the destination at commit SHA. --force because replay_prs
# deliberately moves the base branch to a past commit before each PR is opened.
# Refspec syntax <src>:<dst>: https://git-scm.com/docs/git-push#Documentation/git-push.txt-refspec
push_ref() { run_logged "${GIT[@]}" -C "$WORK_DIR/src.git" push --force "$DEST_GIT_URL" "$1:refs/heads/$2"; }

# merged_prs_tsv: the source's merged PRs, lowest number first, one per line as tab-separated
# "number merge-SHA head-SHA head-branch base-branch". gh's --jq is a built-in jq (https://cli.github.com/manual/gh_help_formatting).
# Fields: https://cli.github.com/manual/gh_pr_list
merged_prs_tsv() {
  gh pr list --repo "$SOURCE_REPO" --state merged --limit 1000 \
    --json number,mergeCommit,headRefOid,headRefName,baseRefName \
    --jq 'sort_by(.number)[] | [.number, .mergeCommit.oid, .headRefOid, .headRefName, .baseRefName] | @tsv'
}

# wait_merged N: poll the destination until PR N shows MERGED. GitHub marks it merged by itself, shortly
# after the push that makes the head reachable from the base (https://man.archlinux.org/man/hub-merge.1.en).
# $SECONDS is bash's built-in seconds counter (https://www.gnu.org/software/bash/manual/bash.html#index-SECONDS).
wait_merged() {
  local deadline=$((SECONDS + MERGE_TIMEOUT_SECONDS)) state
  while :; do
    state="$(gh pr view "$1" --repo "$DEST_REPO" --json state --jq .state)"
    [ "$state" = MERGED ] && { log "PR #$1 is MERGED"; return 0; }
    [ "$SECONDS" -lt "$deadline" ] || die "PR #$1 not marked merged after ${MERGE_TIMEOUT_SECONDS}s (state=$state)"
    sleep "$POLL_SECONDS"
  done
}
