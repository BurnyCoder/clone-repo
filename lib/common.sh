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

# fetch_dest: copy the destination's branches and tags into the bare clone as refs/dest/heads/* and
# refs/dest/tags/*, so destination commits can be compared with the source's locally. --prune drops
# snapshot refs the destination no longer has; --no-tags keeps destination tags out of the source's
# refs/tags (https://git-scm.com/docs/git-fetch). An empty destination simply has nothing to fetch.
fetch_dest() {
  run_logged "${GIT[@]}" -C "$WORK_DIR/src.git" fetch --prune --no-tags "$DEST_GIT_URL" \
    '+refs/heads/*:refs/dest/heads/*' '+refs/tags/*:refs/dest/tags/*'
}

# dest_tip REF: the destination's object for REF (refs/heads/x or refs/tags/x) in the last fetch_dest, or "".
dest_tip() { srcgit rev-parse -q --verify "refs/dest/${1#refs/}" || true; }

# from_source SHA: true when a source branch or tag contains SHA, i.e. it is the source's own history.
# A destination commit that isn't is work done only in the destination, which clone-repo never removes.
# https://git-scm.com/docs/git-for-each-ref#Documentation/git-for-each-ref.txt---containsltobjectgt
from_source() { [ -n "$(srcgit for-each-ref --contains "$1" --count=1 refs/heads refs/tags 2>/dev/null)" ]; }

# ref_state SHA REF: how the destination's REF compares with the source's SHA for it.
#   same      the destination has SHA
#   missing   the destination has no REF
#   behind    the destination has source history only, so moving it to SHA loses nothing
#   ahead     the destination added its own commits on top of SHA: kept, nothing to copy
#   diverged  both repos changed it: kept, a person has to merge them
ref_state() {
  local tip; tip="$(dest_tip "$2")"
  if [ "$tip" = "$1" ]; then echo same
  elif [ -z "$tip" ]; then echo missing
  elif from_source "$tip"; then echo behind
  elif srcgit merge-base --is-ancestor "$1" "$tip"; then echo ahead   # https://git-scm.com/docs/git-merge-base
  else echo diverged; fi
}

# push_ref SHA BRANCH: point BRANCH in the destination at commit SHA. --force because replay_prs
# deliberately moves the base branch to a past commit before each PR is opened. It refuses to move a
# branch that holds destination-only commits (as of the last fetch_dest), so their work is never lost.
# Refspec syntax <src>:<dst>, see <refspec> in https://git-scm.com/docs/git-push
push_ref() {
  case "$(ref_state "$1" "refs/heads/$2")" in ahead|diverged)
    die "$DEST_REPO's $2 has commits $SOURCE_REPO doesn't, so both repos changed it. Merge one into the other, then sync again" ;;
  esac
  run_logged "${GIT[@]}" -C "$WORK_DIR/src.git" push --force "$DEST_GIT_URL" "$1:refs/heads/$2"
}

# merged_prs_tsv: write the source's merged PRs to $MERGED_PRS, lowest number first, one per line as
# tab-separated "number merge-SHA head-SHA head-branch base-branch". gh's --jq is a built-in jq
# (https://cli.github.com/manual/gh_help_formatting). Fields: https://cli.github.com/manual/gh_pr_list
# Callers read the file instead of a `< <(...)` process substitution, because bash ignores that
# command's exit status. A failed query has to stop the run, not look like "no PRs".
merged_prs_tsv() {
  MERGED_PRS="$WORK_DIR/merged_prs.tsv"
  gh pr list --repo "$SOURCE_REPO" --state merged --limit 1000 \
    --json number,mergeCommit,headRefOid,headRefName,baseRefName \
    --jq 'sort_by(.number)[] | [.number, .mergeCommit.oid, .headRefOid, .headRefName, .baseRefName] | @tsv' > "$MERGED_PRS"
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
