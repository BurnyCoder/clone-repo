# lib/replay_prs.sh: phase 5. Recreate each merged PR in number order so it ends up MERGED by the
# source's own merge commit.
# Global context: git can't copy PRs, so each one is replayed the way it originally happened:
#   1. base branch -> the merge commit's first parent (the base as it was just before the merge)
#   2. PR branch   -> the PR's head commit
#   3. open the PR with the original title and body; GitHub gives it the next number, checked to equal N
#   4. copy the PR's conversation comments, in order (copy_comments)
#   5. base branch -> the original merge commit (a fast-forward from step 1)
#   6. GitHub sees the head inside the base and marks the PR merged (https://man.archlinux.org/man/hub-merge.1.en)
#   7. delete the PR branch, like "Delete branch" after a merge; sync_refs restores any the source still has
# PRs already in the destination are skipped, so re-running syncs new PRs only.

# COMMENTS_JQ: turns the PR's comments into one compact JSON object per line, {"body": ...}, with a first
# line naming the original author and time, because the API can't set either. `tojson` makes gh print the
# object as text; gh prints a jq string result raw (https://cli.github.com/manual/gh_help_formatting).
COMMENTS_JQ='.[] | {body: "> Originally posted by @\(.user.login) on \(.created_at)\n\n\(.body)"} | tojson'

# copy_comments N: copy the conversation comments of source PR N to destination PR N (issue comments:
# https://docs.github.com/en/rest/issues/comments). Inline review comments are not conversation comments;
# preflight refuses PRs that have reviews.
copy_comments() {
  local c count
  # Written to a file first, so a failed request stops the run instead of looking like "no comments".
  # --paginate: https://cli.github.com/manual/gh_api
  gh api "repos/$SOURCE_REPO/issues/$1/comments" --paginate --jq "$COMMENTS_JQ" > "$WORK_DIR/comments_$1.jsonl"
  count="$(grep -c . "$WORK_DIR/comments_$1.jsonl" || true)"
  [ "$count" != 0 ] || return 0
  while IFS= read -r c; do
    printf '%s' "$c" | gh api "repos/$DEST_REPO/issues/$1/comments" --input - > /dev/null   # --input -: body from stdin
  done < "$WORK_DIR/comments_$1.jsonl"
  log "PR #$1: copied $count comments"
}

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
    copy_comments "$n"
    push_ref "$merge" "$base_ref"
    wait_merged "$n"
    run_logged "${GIT[@]}" -C "$WORK_DIR/src.git" push "$DEST_GIT_URL" --delete "$ref"
  done < "$MERGED_PRS"
}
