# lib/verify.sh: phase 8. Compare source and destination and report PASS / FAIL / WARN for each part.
# Global context: this is the proof that the copy is exact. Refs are compared by SHA (branches, tags and
# GitHub's refs/pull/N/head), PRs by number, title, body, state, branches, head SHA and merge commit, the
# number of comments on each PR, plus labels and settings. Secrets can only be compared by name. Missing ones are a WARN, since their values
# have to come from the user (SECRETS_ENV_FILE).

# snapshot REPO GIT_URL NAME: write one repo's refs, PRs, labels, settings and secret names to $WORK_DIR/NAME_*.txt.
snapshot() {
  local repo="$1" url="$2" p="$WORK_DIR/$3"
  # https://git-scm.com/docs/git-ls-remote
  "${GIT[@]}" ls-remote "$url" | grep -E 'refs/(heads|tags|pull/[0-9]+/head)' | sort > "${p}_refs.txt" || true
  gh pr list --repo "$repo" --state all --limit 1000 \
    --json number,title,body,state,headRefName,headRefOid,baseRefName,mergeCommit,isDraft --jq 'sort_by(.number)' > "${p}_prs.txt"
  # Comment counts per PR; dates and authors differ in the copy by design, bodies are checked by the replay.
  gh pr list --repo "$repo" --state all --limit 1000 --json number,comments \
    --jq 'sort_by(.number)[] | "\(.number) \(.comments | length)"' > "${p}_comments.txt"
  gh label list --repo "$repo" --limit 1000 --json name,color,description --jq 'sort_by(.name)' > "${p}_labels.txt"
  gh repo view "$repo" --json description,defaultBranchRef,hasIssuesEnabled,hasWikiEnabled,hasProjectsEnabled,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed,deleteBranchOnMerge \
    > "${p}_settings.txt"
  gh secret list --repo "$repo" --json name --jq '.[].name' | sort > "${p}_secrets.txt"   # https://cli.github.com/manual/gh_secret_list
}

# verify: diff the two snapshots and fail the run if anything other than secrets differs.
verify() {
  log "== verify: $SOURCE_REPO vs $DEST_REPO"
  local what failed=0 missing
  snapshot "$SOURCE_REPO" "$SOURCE_GIT_URL" source
  snapshot "$DEST_REPO" "$DEST_GIT_URL" dest
  for what in refs prs comments labels settings; do
    if diff "$WORK_DIR/source_$what.txt" "$WORK_DIR/dest_$what.txt" > "$WORK_DIR/diff_$what.txt"; then log "PASS $what"
    else log "FAIL $what (< source, > destination):"; run_logged cat "$WORK_DIR/diff_$what.txt"; failed=1; fi
  done
  # comm -23: lines only in the first sorted file (https://www.gnu.org/software/coreutils/manual/html_node/comm-invocation.html).
  missing="$(comm -23 "$WORK_DIR/source_secrets.txt" "$WORK_DIR/dest_secrets.txt" | tr '\n' ' ')"
  if [ -n "$missing" ]; then log "WARN secrets missing in destination: ${missing}(set them with SECRETS_ENV_FILE)"
  else log "PASS secrets"; fi
  [ "$failed" = 0 ] || die "verify: the destination differs from the source"
  log "ALL CHECKS PASSED"
}
