# lib/verify.sh: phase 8. Check that everything from the source is in the destination, and report what
# exists only in the destination. PASS / FAIL / WARN / INFO per part.
# Global context: this is the proof that the sync did its job. It compares
#   - refs: every source branch and tag must be in the destination at the same commit (FAIL if missing or
#     still behind). A ref kept because the destination moved it is a WARN or INFO, never overwritten;
#   - PRs: each source PR must have a copy with the same merge commit and the same title, state, branches,
#     head commit, draft flag, number of comments and body (minus the "Copied from" link). The PR number is
#     only reported, since PRs opened in the destination shift later copies;
#   - labels: every source label must exist in the destination;
#   - settings (WARN only: the destination's admins own them) and secret names (WARN: values must come
#     from SECRETS_ENV_FILE).
# Source refs are those of the bare clone, i.e. the source as it was when this run started.

# PR_FIELDS / PRS_JQ: one tab-separated line per PR: merge commit ("-" if unmerged), number, then the
# fields that must match. tostring keeps @tsv happy; tojson keeps a body on one line.
# https://cli.github.com/manual/gh_pr_list , https://jqlang.org/manual/#format-strings-and-escaping
PR_FIELDS=number,mergeCommit,title,state,headRefName,headRefOid,baseRefName,isDraft,comments,body
PRS_JQ='sort_by(.number)[] | [(.mergeCommit.oid // "-"), (.number | tostring), .title, .state, .headRefName,
  .headRefOid, .baseRefName, (.isDraft | tostring), (.comments | length | tostring),
  ((.body // "") | sub("\n\n---\n_Copied from [^\n]*_$"; "") | tojson)] | @tsv'

# report NAME A B: PASS if files A and B are equal, else FAIL with the diff (< source, > destination).
report() {
  if diff "$2" "$3" > "$WORK_DIR/diff_$1.txt"; then log "PASS $1"
  else log "FAIL $1 (< source, > destination):"; run_logged cat "$WORK_DIR/diff_$1.txt"; FAILED=1; fi
}

# verify_refs: classify every source branch and tag with ref_state (lib/common.sh).
verify_refs() {
  local sha ref bad="" warn="" ahead="" own
  fetch_dest
  srcgit for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags > "$WORK_DIR/source_refs.txt"
  while read -r sha ref; do
    case "$(ref_state "$sha" "$ref")" in
      missing|behind) bad+=" ${ref#refs/*/}" ;;
      ahead) ahead+=" ${ref#refs/*/}" ;;
      diverged) warn+=" ${ref#refs/*/}" ;;
    esac
  done < "$WORK_DIR/source_refs.txt"
  # Destination refs the source doesn't have: refs/dest/x without a refs/x.
  own="$(srcgit for-each-ref --format='%(refname)' refs/dest | sed 's|^refs/dest/|refs/|' \
    | while read -r ref; do srcgit rev-parse -q --verify "$ref" > /dev/null || printf ' %s' "${ref#refs/*/}"; done)"
  if [ -z "$bad" ]; then log "PASS refs"; else log "FAIL refs missing or behind in $DEST_REPO:$bad"; FAILED=1; fi
  [ -z "$warn" ] || log "WARN refs changed in both repos (kept $DEST_REPO's):$warn"
  [ -z "$ahead" ] || log "INFO refs ahead in $DEST_REPO (kept):$ahead"
  [ -z "$own" ] || log "INFO refs only in $DEST_REPO (kept):$own"
}

# verify_prs: match each source PR to its copy by merge commit, then compare everything but the number.
verify_prs() {
  local s="$WORK_DIR/source_prs.txt" d="$WORK_DIR/dest_prs.txt" renumbered own
  gh pr list --repo "$SOURCE_REPO" --state all --limit 1000 --json "$PR_FIELDS" --jq "$PRS_JQ" > "$s"
  gh pr list --repo "$DEST_REPO" --state all --limit 1000 --json "$PR_FIELDS" --jq "$PRS_JQ" > "$d"
  # awk 'NR==FNR' reads the first file into a table, then filters the second against it.
  cut -f1,3- "$s" | sort > "$s.cmp"
  awk -F'\t' 'NR==FNR {k[$1]; next} $1 != "-" && ($1 in k)' "$s" "$d" | cut -f1,3- | sort > "$d.cmp"
  report prs "$s.cmp" "$d.cmp"
  renumbered="$(awk -F'\t' 'NR==FNR {n[$1] = $2; next} ($1 in n) && n[$1] != $2 {printf " #%s->#%s", n[$1], $2}' "$s" "$d")"
  own="$(awk -F'\t' 'NR==FNR {k[$1]; next} $1 == "-" || !($1 in k) {printf " #%s", $2}' "$s" "$d")"
  [ -z "$renumbered" ] || log "INFO renumbered copies (source -> destination):$renumbered"
  [ -z "$own" ] || log "INFO PRs only in $DEST_REPO (left alone):$own"
}

# verify_rest: labels (FAIL if a source label is missing), settings and secret names (WARN).
verify_rest() {
  local r f missing
  for r in "$SOURCE_REPO" "$DEST_REPO"; do
    f="$WORK_DIR/${r//\//_}"
    gh label list --repo "$r" --limit 1000 --json name --jq '.[].name' | sort > "${f}_labels.txt"
    gh repo view "$r" --json description,defaultBranchRef,hasIssuesEnabled,hasWikiEnabled,hasProjectsEnabled,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed,deleteBranchOnMerge > "${f}_settings.txt"
    gh secret list --repo "$r" --json name --jq '.[].name' | sort > "${f}_secrets.txt"   # https://cli.github.com/manual/gh_secret_list
  done
  local s="$WORK_DIR/${SOURCE_REPO//\//_}" d="$WORK_DIR/${DEST_REPO//\//_}"
  # comm -23: lines only in the first sorted file (https://www.gnu.org/software/coreutils/manual/html_node/comm-invocation.html).
  missing="$(comm -23 "${s}_labels.txt" "${d}_labels.txt" | tr '\n' ' ')"
  if [ -z "$missing" ]; then log "PASS labels"; else log "FAIL labels missing in $DEST_REPO: $missing"; FAILED=1; fi
  if diff "${s}_settings.txt" "${d}_settings.txt" > /dev/null; then log "PASS settings"
  else log "WARN settings differ (clone-repo sets them only when it creates the destination): ${s}_settings.txt vs ${d}_settings.txt"; fi
  missing="$(comm -23 "${s}_secrets.txt" "${d}_secrets.txt" | tr '\n' ' ')"
  if [ -n "$missing" ]; then log "WARN secrets missing in destination: ${missing}(set them with SECRETS_ENV_FILE)"
  else log "PASS secrets"; fi
}

# verify: run the checks and fail the run if any FAIL was logged.
verify() {
  log "== verify: $SOURCE_REPO -> $DEST_REPO"
  FAILED=0
  verify_refs
  verify_prs
  verify_rest
  [ "$FAILED" = 0 ] || die "verify: something from the source is missing or different in the destination"
  log "ALL CHECKS PASSED"
}
