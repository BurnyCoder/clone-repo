# lib/copy_secrets.sh: phase 7. Set the destination's Actions secrets from a local dotenv file.
# Global context: GitHub never returns secret values (the API lists names only), so they can't be read
# from the source. If SECRETS_ENV_FILE is set, gh imports that file itself, so values never pass through
# this tool or its log (https://cli.github.com/manual/gh_secret_set, -f/--env-file). verify then warns
# about any source secret names still missing.

# copy_secrets: import $SECRETS_ENV_FILE into the destination, or skip when it isn't configured.
copy_secrets() {
  log "== copy_secrets"
  [ -n "$SECRETS_ENV_FILE" ] || { log "SECRETS_ENV_FILE not set, skipping (GitHub never returns secret values)"; return 0; }
  [ -f "$SECRETS_ENV_FILE" ] || die "SECRETS_ENV_FILE not found: $SECRETS_ENV_FILE"
  run_logged gh secret set --env-file "$SECRETS_ENV_FILE" --repo "$DEST_REPO"
}
