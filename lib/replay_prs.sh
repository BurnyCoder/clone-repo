# lib/replay_prs.sh: phase 5. Recreate each merged PR in number order so it ends up MERGED by the
# source's own merge commit.
# Global context: git can't copy PRs, so each one is replayed the way it originally happened:
#   1. base branch -> the merge commit's first parent (the base as it was just before the merge)
#   2. PR branch   -> the PR's head commit
#   3. open the PR with the original title and body. GitHub gives it the next free number: the source's
#      number while the destination only holds copies; later, if people opened PRs there, a higher one,
#      and the copy then gets a "Copied from" link to the original
#   4. copy the PR's conversation comments, in order (copy_comments)
#   5. base branch -> the original merge commit (a fast-forward from step 1)
#   6. GitHub sees the head inside the base and marks the PR merged (https://man.archlinux.org/man/hub-merge.1.en)
#   7. delete the PR branch, like "Delete branch" after a merge; sync_refs restores any the source still has
# A source PR is already copied when a merged destination PR has the same merge commit, so re-running
# syncs new PRs only, whatever their numbers. push_ref stops before a branch with destination-only commits.

# NOTE_JQ: the source PR's body plus a link to it, for a copy whose number differs. verify strips this
# exact suffix again before comparing bodies.
NOTE_JQ='{body: ((.body // "") + "\n\n---\n_Copied from \(.html_url)_")}'

# COMMENTS_JQ: turns the PR's comments into one compact JSON object per line, {"body": ...}, with a first
# line naming the original author and time, because the API can't set either. `tojson` makes gh print the
# object as text; gh prints a jq string result raw (https://cli.github.com/manual/gh_help_formatting).
COMMENTS_JQ='.[] | {body: "> Originally posted by @\(.user.login) on \(.created_at)\n\n\(.body)"} | tojson'

# copy_comments N M: copy the conversation comments of source PR N to destination PR M (issue comments:
# https://docs.github.com/en/rest/issues/comments), skipping as many as M already has, so a copy left half
# done by an earlier run gets only the rest. Inline review comments are not conversation comments;
# preflight refuses PRs that have reviews.
copy_comments() {
  local c count have
  # Written to a file first, so a failed request stops the run instead of looking like "no comments".
  # --paginate: https://cli.github.com/manual/gh_api
  gh api "repos/$SOURCE_REPO/issues/$1/comments" --paginate --jq "$COMMENTS_JQ" > "$WORK_DIR/comments_$1.jsonl"
  count="$(grep -c . "$WORK_DIR/comments_$1.jsonl" || true)"
  [ "$count" != 0 ] || return 0
  # --paginate prints one count per page; awk adds them up.
  have="$(gh api "repos/$DEST_REPO/issues/$2/comments" --paginate --jq length | awk '{s += $1} END {print s + 0}')"
  tail -n "+$((have + 1))" "$WORK_DIR/comments_$1.jsonl" > "$WORK_DIR/comments_$1.todo"
  while IFS= read -r c; do
    printf '%s' "$c" | gh api "repos/$DEST_REPO/issues/$2/comments" --input - > /dev/null   # --input -: body from stdin
  done < "$WORK_DIR/comments_$1.todo"
  log "PR #$1: copied $((count - have)) comments ($have were already there)"
}

# replay_prs: replay every merged source PR that the destination doesn't have yet.
replay_prs() {
  log "== replay_prs"
  local n merge head ref base_ref base got copied
  fetch_dest
  # Merge commits of the destination's merged PRs: a copy has the source PR's merge commit.
  copied=" $(gh pr list --repo "$DEST_REPO" --state merged --limit 1000 --json mergeCommit --jq '[.[].mergeCommit.oid] | join(" ")') "
  merged_prs_tsv
  while IFS=$'\t' read -r n merge head ref base_ref; do
    [[ "$copied" == *" $merge "* ]] && { log "PR #$n already in $DEST_REPO, skipping"; continue; }
    base="$(srcgit rev-parse "$merge^1")"
    log "PR #$n ($ref -> $base_ref): $base_ref at ${base:0:7}, head ${head:0:7}, merge ${merge:0:7}"
    push_ref "$base" "$base_ref"
    push_ref "$head" "$ref"
    # A copy an earlier run opened but didn't finish (same head commit, still open) is reused: GitHub
    # refuses a second PR for the same branches. https://cli.github.com/manual/gh_pr_list (--head)
    got="$(gh pr list --repo "$DEST_REPO" --state open --head "$ref" --json number,headRefOid \
      --jq "[.[] | select(.headRefOid == \"$head\") | .number] | first // empty")"
    if [ -n "$got" ]; then log "PR #$n: reusing copy #$got, left open by an earlier run"
    else
      # Title/body/head/base go through a JSON file, so the body arrives byte for byte.
      # REST create-PR fields: https://docs.github.com/en/rest/pulls/pulls#create-a-pull-request
      gh api "repos/$SOURCE_REPO/pulls/$n" --jq '{title, body, head: .head.ref, base: .base.ref}' > "$WORK_DIR/pr_$n.json"
      got="$(gh api "repos/$DEST_REPO/pulls" --input "$WORK_DIR/pr_$n.json" --jq .number)"   # https://cli.github.com/manual/gh_api
    fi
    if [ "$got" != "$n" ]; then   # the destination has PRs or issues of its own: link the copy to its original
      log "source PR #$n is #$got in $DEST_REPO (its own PRs or issues took #$n), adding a link to the original"
      gh api "repos/$SOURCE_REPO/pulls/$n" --jq "$NOTE_JQ" > "$WORK_DIR/note_$n.json"
      gh api -X PATCH "repos/$DEST_REPO/pulls/$got" --input "$WORK_DIR/note_$n.json" > /dev/null   # https://docs.github.com/en/rest/pulls/pulls#update-a-pull-request
    fi
    copy_comments "$n" "$got"
    push_ref "$merge" "$base_ref"
    wait_merged "$got"
    push_ref "" "$ref"
  done < "$MERGED_PRS"
}
