#!/usr/bin/env bats
# test/config.bats: configuration loading and validation (lib/config.sh, clone-repo.sh argument handling).

load helpers

@test "fails clearly when SOURCE_REPO is missing" {
  unset SOURCE_REPO
  run_clone preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"SOURCE_REPO"* ]]
}

@test "rejects a repo name that isn't owner/name" {
  export DEST_REPO=just-a-name
  run_clone preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEST_REPO"*"owner/name"* ]]
}

@test ".env values are loaded, and environment variables win over them" {
  # Quotes and a Windows CRLF ending must be stripped; comments and blank lines ignored.
  printf '# comment\n\nSOURCE_REPO="from-env-file/a"\r\nDEST_REPO=from-env-file/b\nDEST_VISIBILITY=public\n' > "$ENV_FILE"
  unset SOURCE_REPO
  export DEST_REPO=from-environment/b
  source "$ROOT/lib/common.sh"; source "$ROOT/lib/config.sh"
  load_config
  [ "$SOURCE_REPO" = from-env-file/a ]
  [ "$DEST_REPO" = from-environment/b ]
  [ "$DEST_VISIBILITY" = public ]
}

@test "defaults: private destination and github.com git URLs" {
  unset SOURCE_GIT_URL DEST_GIT_URL
  source "$ROOT/lib/common.sh"; source "$ROOT/lib/config.sh"
  load_config
  [ "$DEST_VISIBILITY" = private ]
  [ "$SOURCE_GIT_URL" = https://github.com/src-owner/project.git ]
  [ "$DEST_GIT_URL" = https://github.com/dst-owner/project.git ]
}

@test "unknown phase names are rejected" {
  run_clone no_such_phase
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown phase: no_such_phase"* ]]
}

@test "every run writes a timestamped log file" {
  run_clone preflight
  [ "$status" -eq 0 ]
  log="$(ls "$LOG_DIR"/clone-repo_*.log)"
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} == preflight' "$log"
}
