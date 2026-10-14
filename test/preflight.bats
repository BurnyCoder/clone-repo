#!/usr/bin/env bats
# test/preflight.bats: the tool must refuse sources it can't copy exactly, before creating anything.

load helpers

@test "preflight passes on a source with only merged PRs" {
  make_pr 1 feat/a
  run_clone preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight: OK"* ]]
}

@test "preflight refuses a source with issues" {
  echo 3 > "$STUB_DIR/issue_count"
  run_clone
  [ "$status" -ne 0 ]
  [[ "$output" == *"issues"* ]]
  [ "$(calls '^repo create')" -eq 0 ]
}

@test "preflight reports PR problems found by the GitHub query" {
  echo "PRs not merged: #2 #5" > "$STUB_DIR/pr_problems"
  run_clone
  [ "$status" -ne 0 ]
  [[ "$output" == *"PRs not merged: #2 #5"* ]]
  [ "$(calls '^repo create')" -eq 0 ]
}

@test "check_merges refuses squash-merged PRs before the destination is created" {
  make_pr 1 feat/a
  make_pr 2 feat/b squash
  run_clone
  [ "$status" -ne 0 ]
  [[ "$output" == *"#2"*"squash or rebase"* ]]
  [ "$(calls '^repo create')" -eq 0 ]
}

@test "preflight also asks for PR comments, reviews, labels, assignees and milestones (not copied yet)" {
  run_clone preflight
  [ "$status" -eq 0 ]
  [ "$(calls '^pr list --repo src-owner/project --state all .*--json number,state,isCrossRepository,comments,reviews,labels,assignees,milestone ')" -eq 1 ]
}
