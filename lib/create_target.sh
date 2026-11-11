# lib/create_target.sh: phase 4. Create the destination with the source's settings and labels, or, if it
# exists, leave its settings alone and only add the source labels it lacks.
# Global context: a destination this run creates starts empty, so PR numbers come out the same. An existing
# destination may be a repo people work in, and its admins own its settings, so a sync never changes them.

# SETTINGS_FLAGS_JQ: turns the source's settings into `gh repo edit` flags (https://cli.github.com/manual/gh_repo_edit).
SETTINGS_FLAGS_JQ='"--enable-issues=\(.hasIssuesEnabled) --enable-projects=\(.hasProjectsEnabled) --enable-wiki=\(.hasWikiEnabled) --enable-merge-commit=\(.mergeCommitAllowed) --enable-squash-merge=\(.squashMergeAllowed) --enable-rebase-merge=\(.rebaseMergeAllowed) --delete-branch-on-merge=\(.deleteBranchOnMerge)"'

# create_target: create $DEST_REPO with $DEST_VISIBILITY and the source's settings and labels (sets
# CREATED, which sync_refs reads), or add missing labels to an existing one.
create_target() {
  log "== create_target: $DEST_REPO ($DEST_VISIBILITY)"
  local desc flags
  if gh repo view "$DEST_REPO" --json name > /dev/null 2>&1; then
    log "$DEST_REPO exists: keeping its settings and labels, adding source labels it lacks"
    # Without --force, labels the destination already has are skipped (https://cli.github.com/manual/gh_label_clone).
    run_logged gh label clone "$SOURCE_REPO" --repo "$DEST_REPO"
    return 0
  fi
  desc="$(gh repo view "$SOURCE_REPO" --json description --jq .description)"
  run_logged gh repo create "$DEST_REPO" "--$DEST_VISIBILITY" --description "$desc"   # https://cli.github.com/manual/gh_repo_create (no --add-readme, so it starts empty)
  CREATED=1
  flags="$(gh repo view "$SOURCE_REPO" --json hasIssuesEnabled,hasProjectsEnabled,hasWikiEnabled,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed,deleteBranchOnMerge --jq "$SETTINGS_FLAGS_JQ")"
  # shellcheck disable=SC2086 # $flags is meant to split into separate flags
  run_logged gh repo edit "$DEST_REPO" --description "$desc" $flags
  run_logged gh label clone "$SOURCE_REPO" --repo "$DEST_REPO" --force   # a new repo's default labels take the source's colors
}
