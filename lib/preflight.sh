# lib/preflight.sh: phase 1. Refuse sources this tool can't copy exactly, before anything is created.
# Global context: issues and PRs share one number sequence, and the destination hands out numbers in
# creation order, so the copy only matches when the source holds nothing but merged PRs numbered 1..N.
# A replayed PR carries its title, body, commits and conversation comments, so PRs with reviews or
# metadata (labels, assignees, milestone) are refused.
# Supporting more is planned in docs/roadmap.md. The squash/rebase check needs the commits, so it is a
# separate phase (check_merges) after clone_source.

# PR_PROBLEMS_JQ: jq (run by gh) that turns the source's PR list into a "; "-separated problem list,
# or "" when every PR can be replayed. `nums` lists at most 10 numbers, so big repos get a readable line.
# jq manual: https://jqlang.org/manual/
PR_PROBLEMS_JQ='
  def nums: length as $c | (sort_by(.number) | .[:10] | map("#\(.number)") | join(" "))
    + (if $c > 10 then " ... (\($c) in total)" else "" end);
  [ (map(select(.state != "MERGED")) | select(length > 0) | "PRs not merged: \(nums)"),
    (map(select(.isCrossRepository)) | select(length > 0) | "PRs from forks: \(nums)"),
    (map(select(([.reviews, .labels, .assignees] | map(length) | add) > 0 or .milestone != null))
      | select(length > 0) | "PRs with reviews, labels, assignees or a milestone (not copied yet): \(nums)"),
    ((map(.number) | sort) as $n | select($n != [range(1; ($n | length) + 1)])
      | "PR numbers are not 1..N (the gaps belong to deleted issues or discussions)")
  ] | join("; ")'

# preflight: stop with a list of everything unsupported, or log OK.
preflight() {
  log "== preflight: can $SOURCE_REPO be copied exactly?"
  local issues problems
  # A repo with issues turned off makes `gh issue list` fail; then it has no issues to count.
  issues="$(gh issue list --repo "$SOURCE_REPO" --state all --limit 1 --json number --jq length 2>/dev/null || echo 0)"
  problems="$(gh pr list --repo "$SOURCE_REPO" --state all --limit 1000 \
    --json number,state,isCrossRepository,reviews,labels,assignees,milestone --jq "$PR_PROBLEMS_JQ")"
  [ "$issues" = 0 ] || problems="source has issues (they share numbers with PRs and aren't copied yet)${problems:+; $problems}"
  [ -z "$problems" ] || die "not supported yet: $problems. See docs/roadmap.md"
  log "preflight: OK"
}
