# lib/check_merges.sh: phase 3. Every merged PR must have a real merge commit to replay.
# Global context: replay_prs ends each PR by pushing the source's merge commit. GitHub then sees the PR
# head inside the base branch and marks the PR merged. That only works when the merge commit's second
# parent is the PR head, which is what "Create a merge commit" produces. Squash and rebase merges make
# new commits that don't contain the head
# (https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/about-pull-request-merges).

# check_merges: stop with the PR numbers that weren't merged with a merge commit, or log OK.
check_merges() {
  log "== check_merges: were all PRs merged with a merge commit?"
  local n merge head bad=""
  merged_prs_tsv
  while IFS=$'\t' read -r n merge head _ _; do
    # <sha>^2 is a commit's second parent (https://git-scm.com/docs/gitrevisions). It doesn't exist for
    # single-parent squash/rebase commits, or when the merge commit isn't in any branch.
    [ "$(srcgit rev-parse -q --verify "$merge^2" || true)" = "$head" ] || bad+=" #$n"
  done < "$MERGED_PRS"
  [ -z "$bad" ] || die "not supported yet:$bad merged by squash or rebase (no merge commit to replay). See docs/roadmap.md"
  log "check_merges: OK"
}
