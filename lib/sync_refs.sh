# lib/sync_refs.sh: phase 6. Bring the destination's branches and tags up to the source's, without
# losing anything that exists only in the destination.
# Global context: this used to be GitHub's documented `git push --mirror`, which force-updates every ref
# and deletes the destination's other branches (https://git-scm.com/docs/git-push#Documentation/git-push.txt---mirror).
# Once people work in the destination too, that deletes their branches (and GitHub closes their PRs), so
# each ref is now classified by ref_state (lib/common.sh) and only refs holding nothing but source history
# are moved. The first branch pushed into a new repo becomes its default, so a repo created by this run
# gets the source's default branch set explicitly afterwards.

# sync_refs: push missing and behind source refs in one push, delete only branches the source deleted
# after merging their PR, and report everything kept.
sync_refs() {
  log "== sync_refs: source branches and tags -> $DEST_REPO (work that exists only there is kept)"
  local sha ref name default specs=() ahead="" diverged="" own=""
  fetch_dest
  merged_prs_tsv
  default="refs/heads/$(srcgit symbolic-ref --short HEAD)"   # the source's default branch (HEAD of the bare clone)
  srcgit for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags > "$WORK_DIR/source_refs.txt"
  while read -r sha ref; do
    case "$(ref_state "$sha" "$ref")" in
      missing|behind) specs+=("+$sha:$ref") ;;   # a leading + forces just this ref (git-push <refspec>: https://git-scm.com/docs/git-push)
      ahead) ahead+=" ${ref#refs/*/}" ;;
      diverged) [ "$ref" != "$default" ] || die "$DEST_REPO's ${ref#refs/heads/} has commits $SOURCE_REPO doesn't, and the source moved it too. Merge one into the other, then sync again"
                diverged+=" ${ref#refs/*/}" ;;
    esac
  done < "$WORK_DIR/source_refs.txt"
  # Branches only in the destination. One that is a merged source PR's branch and holds only source
  # history was deleted in the source after the merge, so it goes; anything else is someone's work.
  srcgit for-each-ref --format='%(refname)' refs/dest/heads > "$WORK_DIR/dest_branches.txt"
  while read -r ref; do
    name="${ref#refs/dest/heads/}"
    ! srcgit rev-parse -q --verify "refs/heads/$name" > /dev/null || continue          # the source has it: done above
    if awk -F'\t' -v b="$name" '$4 == b {f = 1} END {exit !f}' "$MERGED_PRS" && from_source "$(dest_tip "refs/heads/$name")"
    then specs+=(":refs/heads/$name")                                                  # an empty <src> deletes the ref
    else own+=" $name"; fi
  done < "$WORK_DIR/dest_branches.txt"
  if [ ${#specs[@]} -gt 0 ]; then run_logged "${GIT[@]}" -C "$WORK_DIR/src.git" push "$DEST_GIT_URL" "${specs[@]}"
  else log "branches and tags already up to date"; fi
  [ -z "$ahead" ] || log "ahead of $SOURCE_REPO, kept:$ahead"
  [ -z "$diverged" ] || log "WARN changed in both repos, kept $DEST_REPO's version:$diverged"
  [ -z "$own" ] || log "only in $DEST_REPO, kept:$own"
  [ -z "${CREATED:-}" ] || run_logged gh repo edit "$DEST_REPO" --default-branch "${default#refs/heads/}"
}
