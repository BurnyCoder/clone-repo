#!/usr/bin/env bats
# test/preflight.bats: the tool must refuse sources it can't copy exactly, before creating anything.

source "$BATS_TEST_DIRNAME/helpers.bash"   # plain source: also works with C:/ paths when run via npm on Windows

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

@test "preflight asks for PR reviews, labels, assignees and milestones (not copied yet), but not comments" {
  run_clone preflight
  [ "$status" -eq 0 ]
  [ "$(calls '^pr list --repo src-owner/project --state all .*--json number,state,isCrossRepository,reviews,labels,assignees,milestone ')" -eq 1 ]
}

@test "a failing merged-PR query stops the run before the destination is created" {
  make_pr 1 feat/a
  touch "$STUB_DIR/fail_merged_list"
  run_clone
  [ "$status" -ne 0 ]
  [ "$(calls '^repo create')" -eq 0 ]
}
