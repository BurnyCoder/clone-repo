#!/usr/bin/env bats
# test/replay.bats: a full run against real local git repos (source/ -> dest.git) with the fake gh.

load helpers

# make_source: two merged PRs, plus a branch that still exists and a tag, so mirroring is checked too.
make_source() {
  make_pr 1 feat/a
  make_pr 2 feat/b
  src branch -q keep-me
  src tag v1.0
}

@test "full run copies every ref and replays PRs in number order as merged" {
  make_source
  run_clone
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL CHECKS PASSED"* ]]
  # Destination refs are exactly the source refs (same SHAs, no leftover PR branches).
  [ "$(refs "$DEST_GIT_URL")" = "$(refs "$SOURCE_GIT_URL")" ]
  # PRs were created as #1, #2 from the original head branches into main.
  [ "$(cut -f1-3 "$STUB_DIR/created.tsv")" = "$(printf '1\tfeat/a\tmain\n2\tfeat/b\tmain')" ]
  # Each PR's head is now in main (so GitHub would show MERGED) and the destination has the repo settings.
  [ "$(calls '^repo create dst-owner/project --private ')" -eq 1 ]
  [ "$(calls '^repo edit dst-owner/project --default-branch main')" -eq 1 ]
  [ "$(calls '^label clone src-owner/project --repo dst-owner/project --force')" -eq 1 ]
}

@test "a second run syncs: copied PRs are skipped, new ones replayed" {
  make_pr 1 feat/a
  run_clone
  [ "$status" -eq 0 ]
  make_pr 2 feat/b
  run_clone
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #1 already in dst-owner/project, skipping"* ]]
  [[ "$output" == *"exists, syncing settings"* ]]
  [ "$(calls '^repo create')" -eq 1 ]
  [ "$(wc -l < "$STUB_DIR/created.tsv")" -eq 2 ]
  [ "$(refs "$DEST_GIT_URL")" = "$(refs "$SOURCE_GIT_URL")" ]
}

@test "the destination visibility comes from DEST_VISIBILITY" {
  make_pr 1 feat/a
  export DEST_VISIBILITY=public
  run_clone
  [ "$status" -eq 0 ]
  [ "$(calls '^repo create dst-owner/project --public ')" -eq 1 ]
}

@test "secrets are set from SECRETS_ENV_FILE with gh's dotenv import" {
  make_pr 1 feat/a
  echo "API_TOKEN=x" > "$BATS_TEST_TMPDIR/ci.secrets.env"
  export SECRETS_ENV_FILE="$BATS_TEST_TMPDIR/ci.secrets.env"
  run_clone
  [ "$status" -eq 0 ]
  [ "$(calls "^secret set --env-file $SECRETS_ENV_FILE --repo dst-owner/project")" -eq 1 ]
}

@test "verify warns about secrets missing in the destination" {
  make_pr 1 feat/a
  printf 'A\nB\n' > "$STUB_DIR/source_secrets"; echo A > "$STUB_DIR/dest_secrets"
  run_clone
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN secrets missing in destination: B"* ]]
}

@test "verify fails when the destination refs differ" {
  make_source
  run_clone
  [ "$status" -eq 0 ]
  git -C "$DEST_GIT_URL" branch -q -D keep-me
  run_clone verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL refs"* ]]
}
