# lib/clone_source.sh: phase 2. Bare clone of the source into $WORK_DIR/src.git.
# Global context: GitHub's documented way to duplicate a repo is a bare clone plus `git push --mirror`
# (https://docs.github.com/en/repositories/creating-and-managing-repositories/duplicating-a-repository).
# A bare clone holds every branch and tag but not GitHub's hidden refs/pull/*, which GitHub refuses on
# push. Each merged PR's head commit is the second parent of its merge commit, so it is in the clone too.

# clone_source: fresh bare clone every run, so a sync always starts from the source's current state.
clone_source() {
  log "== clone_source: $SOURCE_REPO -> $WORK_DIR/src.git"
  rm -rf "$WORK_DIR/src.git"
  run_logged "${GIT[@]}" clone --bare "$SOURCE_GIT_URL" "$WORK_DIR/src.git"   # https://git-scm.com/docs/git-clone#Documentation/git-clone.txt---bare
}
