#!/usr/bin/env bash
# clone-repo.sh: copy a GitHub repo to another owner with the same commit SHAs, branches, tags, merged
# PRs (same numbers, shown as merged by the original merge commits), labels, settings and secrets.
# Global context: this is the only entry point. It loads config, then runs the named phases from lib/
# in order. Each phase is a function in its own file. Usage:
#   ./clone-repo.sh                    full copy, or a sync if the destination already exists
#   ./clone-repo.sh preflight verify   only the named phases, in the order given
# Config: .env (see .env.example) or environment variables. How it works: docs/how-it-works.md.

# Stop on any failed command, unset variable or failed pipeline stage.
# Source: https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"    # repo folder, for .env, work/ and logs/
for lib in "$ROOT"/lib/*.sh; do source "$lib"; done     # helpers + one function per phase

# PHASES: the full run, in order. Nothing is created on GitHub until the first three checks have passed.
PHASES=(preflight clone_source check_merges create_target replay_prs sync_refs copy_secrets verify)

# main [PHASE...]: run the given phases (default: all), after checking that each name is known.
main() {
  load_config
  local phases=("$@") p
  [ $# -gt 0 ] || phases=("${PHASES[@]}")
  for p in "${phases[@]}"; do
    [[ " ${PHASES[*]} " == *" $p "* ]] || die "unknown phase: $p (phases: ${PHASES[*]})"
  done
  log "clone-repo: $SOURCE_REPO -> $DEST_REPO, phases: ${phases[*]}"
  for p in "${phases[@]}"; do "$p"; done
  log "done: https://github.com/$DEST_REPO (log: $LOG)"
}

main "$@"
