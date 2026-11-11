#!/usr/bin/env bats
# test/destination.bats: a destination where people also work. Its own PRs, branches and commits must
# survive every sync; copies of new source PRs take the next free number and link back to the original.

source "$BATS_TEST_DIRNAME/helpers.bash"   # plain source: also works with C:/ paths when run via npm on Windows

@test "a PR opened in the destination shifts later copies: source #2 becomes #3 and links back" {
  make_pr 1 feat/a
  run_clone; [ "$status" -eq 0 ]
  echo 2 >> "$STUB_DIR/dest_prs"                      # someone opened PR #2 in the destination
  make_pr 2 feat/b
  run_clone
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #1 already in dst-owner/project, skipping"* ]]
  [[ "$output" == *"source PR #2 is #3 in dst-owner/project"* ]]
  [ "$(tail -1 "$STUB_DIR/created.tsv" | cut -f1-3)" = "$(printf '3\tfeat/b\tmain')" ]
  [ "$(calls '^api -X PATCH repos/dst-owner/project/pulls/3 --input')" -eq 1 ]   # the link back
  [ "$(calls '^api -X PATCH')" -eq 1 ]                                            # and only there
  [ "$(calls '^pr view 3 --repo dst-owner/project')" -ge 1 ]                      # waited for #3, not #2
  [[ "$output" == *"ALL CHECKS PASSED"* ]]
}

@test "a branch that exists only in the destination is kept (a mirror push would delete it)" {
  make_pr 1 feat/a
  run_clone; [ "$status" -eq 0 ]
  theirs="$(dest_commit their/work "Their change")"
  make_pr 2 feat/b
  run_clone
  [ "$status" -eq 0 ]
  [ "$(git -C "$DEST_GIT_URL" rev-parse refs/heads/their/work)" = "$theirs" ]
  [[ "$output" == *"only in dst-owner/project, kept: their/work"* ]]
  [[ "$output" == *"ALL CHECKS PASSED"* ]]
}

@test "a merged PR's branch that the source deleted is removed from the destination too" {
  make_pr 1 feat/a
  src branch -q feat/a "$(cut -f3 "$STUB_DIR/prs.tsv")"   # the source still has the PR's branch
  run_clone; [ "$status" -eq 0 ]
  dest_has feat/a
  src branch -q -D feat/a                                   # now it deletes it, as after a merge
  run_clone
  [ "$status" -eq 0 ]
  run dest_has feat/a
  [ "$status" -ne 0 ]
}

@test "when both repos changed the base branch, the sync stops before touching it" {
  make_pr 1 feat/a
  run_clone; [ "$status" -eq 0 ]
  theirs="$(dest_commit main "Their change on main")"
  make_pr 2 feat/b
  run_clone
  [ "$status" -ne 0 ]
  [[ "$output" == *"dst-owner/project's main has commits src-owner/project doesn't"* ]]
  [ "$(git -C "$DEST_GIT_URL" rev-parse refs/heads/main)" = "$theirs" ]
  [ "$(wc -l < "$STUB_DIR/created.tsv")" -eq 1 ]           # PR 2 was not opened
}

@test "when only the destination moved its base branch, the sync keeps it and goes on" {
  make_pr 1 feat/a
  run_clone; [ "$status" -eq 0 ]
  theirs="$(dest_commit main "Their change on main")"
  run_clone
  [ "$status" -eq 0 ]
  [ "$(git -C "$DEST_GIT_URL" rev-parse refs/heads/main)" = "$theirs" ]
  [[ "$output" == *"ahead of src-owner/project, kept: main"* ]]
  [[ "$output" == *"ALL CHECKS PASSED"* ]]
}

@test "a non-default branch changed in both repos keeps the destination's version, with a warning" {
  make_pr 1 feat/a
  src branch -q keep-me
  run_clone; [ "$status" -eq 0 ]
  theirs="$(dest_commit keep-me "Their change")"
  src checkout -q keep-me; src commit -q --allow-empty -m "Source change"; src checkout -q main
  run_clone
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN changed in both repos, kept dst-owner/project's version: keep-me"* ]]
  [ "$(git -C "$DEST_GIT_URL" rev-parse refs/heads/keep-me)" = "$theirs" ]
}

@test "verify matches copies by merge commit: renumbered copies pass, a changed copy fails" {
  make_pr 1 feat/a
  run_clone; [ "$status" -eq 0 ]
  printf 'm1\t5\tTitle\tMERGED\n' > "$STUB_DIR/vprs_source"
  printf -- '-\t5\tTheirs\tOPEN\nm1\t6\tTitle\tMERGED\n' > "$STUB_DIR/vprs_dest"
  run_clone verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS prs"* ]]
  [[ "$output" == *"INFO renumbered copies (source -> destination): #5->#6"* ]]
  [[ "$output" == *"INFO PRs only in dst-owner/project (left alone): #5"* ]]
  printf 'm1\t6\tAnother title\tMERGED\n' > "$STUB_DIR/vprs_dest"
  run_clone verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL prs"* ]]
}

@test "a commit pushed to the destination during the sync is never overwritten" {
  make_pr 1 feat/a
  run_clone; [ "$status" -eq 0 ]
  make_pr 2 feat/b
  touch "$STUB_DIR/race_on_create"          # someone pushes to main right after the copy of PR 2 is opened
  run_clone
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale info"* ]]         # git refused: main is no longer what the sync checked
  [ "$(git -C "$DEST_GIT_URL" log -1 --format=%s refs/heads/main)" = "Pushed during the sync" ]
}

@test "a copy left half done by a run that stopped is reused, and only its missing comments are added" {
  make_pr 1 feat/a
  printf '%s\n' '{"body":"first"}' '{"body":"second"}' > "$STUB_DIR/comments_1.jsonl"
  touch "$STUB_DIR/fail_second_comment"          # the API fails on the second comment, once
  run_clone
  [ "$status" -ne 0 ]
  run_clone
  [ "$status" -eq 0 ]
  [[ "$output" == *"reusing copy #1, left open by an earlier run"* ]]
  [ "$(wc -l < "$STUB_DIR/created.tsv")" -eq 1 ]                  # opened once
  [ "$(grep -c . "$STUB_DIR/posted_comments.log")" -eq 2 ]         # each comment posted once
  [ "$(grep -n -o -E 'first|second' "$STUB_DIR/posted_comments.log" | tr '\n' ' ')" = "1:first 2:second " ]
}
