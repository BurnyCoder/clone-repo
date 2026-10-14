# lib/create_target.sh: phase 4. Create the empty destination (or reuse it on a sync) and copy settings
# and labels. Global context: the destination must start empty so PR numbers come out the same. Each
# setting here is one that verify compares.

# SETTINGS_FLAGS_JQ: turns the source's settings into `gh repo edit` flags (https://cli.github.com/manual/gh_repo_edit).
SETTINGS_FLAGS_JQ='"--enable-issues=\(.hasIssuesEnabled) --enable-projects=\(.hasProjectsEnabled) --enable-wiki=\(.hasWikiEnabled) --enable-merge-commit=\(.mergeCommitAllowed) --enable-squash-merge=\(.squashMergeAllowed) --enable-rebase-merge=\(.rebaseMergeAllowed) --delete-branch-on-merge=\(.deleteBranchOnMerge)"'

# create_target: create $DEST_REPO with $DEST_VISIBILITY if it doesn't exist, then match the source's settings and labels.
create_target() {
  log "== create_target: $DEST_REPO ($DEST_VISIBILITY)"
  local desc flags
  desc="$(gh repo view "$SOURCE_REPO" --json description --jq .description)"
  if gh repo view "$DEST_REPO" --json name > /dev/null 2>&1; then
    log "$DEST_REPO exists, syncing settings only"
  else   # https://cli.github.com/manual/gh_repo_create (no --add-readme etc., so it starts empty)
    run_logged gh repo create "$DEST_REPO" "--$DEST_VISIBILITY" --description "$desc"
  fi
  flags="$(gh repo view "$SOURCE_REPO" --json hasIssuesEnabled,hasProjectsEnabled,hasWikiEnabled,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed,deleteBranchOnMerge --jq "$SETTINGS_FLAGS_JQ")"
  # shellcheck disable=SC2086 # $flags is meant to split into separate flags
  run_logged gh repo edit "$DEST_REPO" --description "$desc" $flags
  run_logged gh label clone "$SOURCE_REPO" --repo "$DEST_REPO" --force   # https://cli.github.com/manual/gh_label_clone
}
