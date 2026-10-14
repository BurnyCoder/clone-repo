# lib/config.sh: load settings from .env and the environment, apply defaults, validate.
# Global context: load_config runs first in every run (clone-repo.sh main). All settings are documented
# in .env.example. Environment variables win over .env, so `DEST_REPO=x/y ./clone-repo.sh` works for one-offs.

# load_config: read $ENV_FILE (default <repo>/.env) without executing it, then default and check settings.
load_config() {
  local key val name
  ENV_FILE="${ENV_FILE:-$ROOT/.env}"
  if [ -f "$ENV_FILE" ]; then
    # Only KEY=VALUE lines; comments and blank lines are skipped by the grep. The file is parsed, not
    # sourced, so it can't run code. `read` with IFS='=' leaves any later '=' in the value.
    while IFS='=' read -r key val; do
      val="${val%$'\r'}"                                   # drop a Windows CR line ending
      val="${val#[\"\']}"; val="${val%[\"\']}"             # drop surrounding quotes
      [ -n "${!key+x}" ] || export "$key=$val"             # ${!key}: indirect expansion, set vars win
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE")
  fi                                                       # https://www.gnu.org/software/bash/manual/bash.html#Shell-Parameter-Expansion

  # Defaults (`:=` assigns when unset or empty).
  : "${DEST_VISIBILITY:=private}"       # private | public | internal, used only when creating the destination
  : "${SECRETS_ENV_FILE:=}"             # optional dotenv file of Actions secrets for the destination
  : "${MERGE_TIMEOUT_SECONDS:=60}"      # how long to wait for GitHub to mark one replayed PR merged
  : "${POLL_SECONDS:=2}"                # pause between merge-state polls
  : "${WORK_DIR:=$ROOT/work}"           # bare clone + per-PR JSON + verify snapshots
  : "${LOG_DIR:=$ROOT/logs}"            # timestamped run logs
  mkdir -p "$WORK_DIR" "$LOG_DIR"
  LOG="$LOG_DIR/clone-repo_$(date '+%Y%m%d_%H%M%S').log"   # one file per run, also gets config errors

  for name in SOURCE_REPO DEST_REPO; do
    [[ "${!name:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "$name must be set to owner/name (got '${!name:-}'). See .env.example"
  done
  [ "$SOURCE_REPO" != "$DEST_REPO" ] || die "SOURCE_REPO and DEST_REPO are the same repo"
  [[ "$DEST_VISIBILITY" =~ ^(private|public|internal)$ ]] || die "DEST_VISIBILITY must be private, public or internal"
  # Git remotes; tests point these at local bare repos.
  : "${SOURCE_GIT_URL:=https://github.com/$SOURCE_REPO.git}"
  : "${DEST_GIT_URL:=https://github.com/$DEST_REPO.git}"
}
