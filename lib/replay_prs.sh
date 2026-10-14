# lib/replay_prs.sh: phase 5. Recreate each merged PR in number order so it ends up MERGED by the
# source's own merge commit.
# Global context: git can't copy PRs, so each one is replayed the way it originally happened:
#   1. base branch -> the merge commit's first parent (the base as it was just before the merge)
#   2. PR branch   -> the PR's head commit
#   3. open the PR with the original title and body; GitHub gives it the next number, checked to equal N
#   4. base branch -> the original merge commit (a fast-forward from step 1)
#   5. GitHub sees the head inside the base and marks the PR merged (https://man.archlinux.org/man/hub-merge.1.en)
#   6. delete the PR branch, like "Delete branch" after a merge; sync_refs restores any the source still has
# PRs already in the destination are skipped, so re-running syncs new PRs only.

# replay_prs: replay every merged source PR that the destination doesn't have yet.
replay_prs() {
  log "== replay_prs"
  local n merge head ref base_ref base got copied
  copied=" $(gh pr list --repo "$DEST_REPO" --state all --limit 1000 --json number --jq '[.[].number] | join(" ")') "
  merged_prs_tsv
  while IFS=$'\t' read -r n merge head ref base_ref; do
    [[ "$copied" == *" $n "* ]] && { log "PR #$n already in $DEST_REPO, skipping"; continue; }
    base="$(srcgit rev-parse "$merge^1")"
    log "PR #$n ($ref -> $base_ref): $base_ref at ${base:0:7}, head ${head:0:7}, merge ${merge:0:7}"
    push_ref "$base" "$base_ref"
    push_ref "$head" "$ref"
    # Title/body/head/base go through a JSON file, so the body arrives byte for byte.
    # REST create-PR fields: https://docs.github.com/en/rest/pulls/pulls#create-a-pull-request
    gh api "repos/$SOURCE_REPO/pulls/$n" --jq '{title, body, head: .head.ref, base: .base.ref}' > "$WORK_DIR/pr_$n.json"
    got="$(gh api "repos/$DEST_REPO/pulls" --input "$WORK_DIR/pr_$n.json" --jq .number)"   # https://cli.github.com/manual/gh_api
    [ "$got" = "$n" ] || die "created PR #$got in $DEST_REPO, expected #$n (was something else created there?)"
    push_ref "$merge" "$base_ref"
    wait_merged "$n"
    run_logged "${GIT[@]}" -C "$WORK_DIR/src.git" push "$DEST_GIT_URL" --delete "$ref"
  done < "$MERGED_PRS"
}
