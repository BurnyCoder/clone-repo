# lib/sync_refs.sh: phase 6. Make the destination's branches and tags equal the source's.
# Global context: the documented duplicate step, `git push --mirror`, pushes every ref of the bare clone,
# force-updates them and deletes destination refs the source doesn't have
# (https://git-scm.com/docs/git-push#Documentation/git-push.txt---mirror). That removes branches left over
# from the replay and restores ones the source still has. The first branch pushed became the default
# branch, so the source's default is set explicitly afterwards.

# sync_refs: mirror-push the bare clone, then copy the default branch setting.
sync_refs() {
  log "== sync_refs: git push --mirror"
  run_logged "${GIT[@]}" -C "$WORK_DIR/src.git" push --mirror "$DEST_GIT_URL"
  run_logged gh repo edit "$DEST_REPO" --default-branch "$(gh repo view "$SOURCE_REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
}
