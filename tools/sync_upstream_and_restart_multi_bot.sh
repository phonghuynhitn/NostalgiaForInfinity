#!/bin/bash
#
# Periodically sync upstream/main into a local branch (default: pi2) and restart
# the multi-bot Docker Compose stack. Restarts even when there are no new commits.
#
# Cron example (every 6 hours):
#   0 */6 * * * /path/to/NostalgiaForInfinity/tools/sync_upstream_and_restart_multi_bot.sh
#
# Check for updates without merging or restarting:
#   ./tools/sync_upstream_and_restart_multi_bot.sh --check-only
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/sync-upstream.log}"
LOCK_DIR="${LOCK_DIR:-/tmp/nfi-sync-upstream.lock}"

LOCAL_BRANCH="${LOCAL_BRANCH:-pi2}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/iterativv/NostalgiaForInfinity.git}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
PUSH_AFTER_MERGE="${PUSH_AFTER_MERGE:-true}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-docker-compose.multi-bot.yml}"

CHECK_ONLY=false

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [--check-only] [--help]

Sync ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH} into ${LOCAL_BRANCH} and restart
${DOCKER_COMPOSE_FILE}. Restarts even when there are no new upstream commits.

Environment overrides:
  LOCAL_BRANCH         Target branch (default: pi2)
  UPSTREAM_REMOTE      Upstream remote name (default: upstream)
  UPSTREAM_BRANCH      Upstream branch (default: main)
  ORIGIN_REMOTE        Push target after merge (default: origin)
  PUSH_AFTER_MERGE     Push merged branch (default: true)
  DOCKER_COMPOSE_FILE  Compose file to restart (default: docker-compose.multi-bot.yml)
  LOG_FILE             Log file path

Options:
  --check-only, -c  Report pending upstream commits only
  --help, -h        Show this help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check-only|-c)
                CHECK_ONLY=true
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                show_usage
                echo ""
                echo "Unknown argument: $1"
                exit 1
                ;;
        esac
        shift
    done
}

acquire_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "Another sync is already running. Exiting."
        exit 0
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

ensure_upstream_remote() {
    if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
        return 0
    fi

    log "Remote '$UPSTREAM_REMOTE' not found. Adding $UPSTREAM_URL ..."
    if ! git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL" 2>&1 | tee -a "$LOG_FILE"; then
        if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
            log "Remote '$UPSTREAM_REMOTE' is already configured."
            return 0
        fi
        log "ERROR: Failed to configure remote '$UPSTREAM_REMOTE'."
        exit 1
    fi
}

ensure_clean_worktree() {
    if ! git diff-index --quiet HEAD --; then
        log "ERROR: Working tree has uncommitted changes. Commit or stash them first."
        exit 1
    fi
}

restart_multi_bot() {
    local compose_file="$REPO_ROOT/$DOCKER_COMPOSE_FILE"

    if [[ ! -f "$compose_file" ]]; then
        log "ERROR: Compose file not found: $compose_file"
        exit 1
    fi

    log "Restarting Docker Compose ($DOCKER_COMPOSE_FILE)..."
    (
        cd "$REPO_ROOT"
        docker compose -f "$DOCKER_COMPOSE_FILE" down
        docker compose -f "$DOCKER_COMPOSE_FILE" up -d --build
    ) 2>&1 | tee -a "$LOG_FILE"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log "ERROR: Docker Compose restart failed."
        exit 1
    fi

    log "Docker Compose restarted successfully."
}

main() {
    parse_args "$@"

    if ! command -v git >/dev/null 2>&1; then
        echo "git is required."
        exit 1
    fi

    if [[ "$CHECK_ONLY" != "true" ]] && ! command -v docker >/dev/null 2>&1; then
        echo "docker is required."
        exit 1
    fi

    acquire_lock
    cd "$REPO_ROOT"

    log "========================================================================"
    log "Sync upstream -> $LOCAL_BRANCH"
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log "Mode: check-only"
    fi
    log "========================================================================"

    ensure_clean_worktree
    ensure_upstream_remote

    if ! git rev-parse --verify "$LOCAL_BRANCH" >/dev/null 2>&1; then
        log "ERROR: Local branch '$LOCAL_BRANCH' not found."
        exit 1
    fi

    log "Fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH..."
    git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" 2>&1 | tee -a "$LOG_FILE"

    local local_sha upstream_sha
    local_sha="$(git rev-parse "$LOCAL_BRANCH")"
    upstream_sha="$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"

    local merged=false

    if git merge-base --is-ancestor "$upstream_sha" "$local_sha"; then
        if [[ "$local_sha" == "$upstream_sha" ]]; then
            log "No updates. $LOCAL_BRANCH matches $UPSTREAM_REMOTE/$UPSTREAM_BRANCH ($upstream_sha)."
        else
            log "No new upstream commits. $LOCAL_BRANCH is ahead of $UPSTREAM_REMOTE/$UPSTREAM_BRANCH."
        fi
    else
        local pending_count
        pending_count="$(git rev-list --count "$local_sha..$upstream_sha")"
        log "Found $pending_count new commit(s) on $UPSTREAM_REMOTE/$UPSTREAM_BRANCH."

        if [[ "$CHECK_ONLY" == "true" ]]; then
            log "Pending commits:"
            git --no-pager log --oneline "$local_sha..$upstream_sha" | tee -a "$LOG_FILE"
            exit 0
        fi

        local original_branch
        original_branch="$(git branch --show-current)"

        log "Checking out $LOCAL_BRANCH..."
        git checkout "$LOCAL_BRANCH" 2>&1 | tee -a "$LOG_FILE"

        log "Merging $UPSTREAM_REMOTE/$UPSTREAM_BRANCH into $LOCAL_BRANCH..."
        if ! git merge "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --no-edit \
            -m "Merge $UPSTREAM_REMOTE/$UPSTREAM_BRANCH into $LOCAL_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
            log "ERROR: Merge failed. Resolve conflicts manually, then rerun this script."
            if [[ -n "$original_branch" && "$original_branch" != "$LOCAL_BRANCH" ]]; then
                git checkout "$original_branch" >/dev/null 2>&1 || true
            fi
            exit 1
        fi

        if [[ "$PUSH_AFTER_MERGE" == "true" ]]; then
            log "Pushing $LOCAL_BRANCH to $ORIGIN_REMOTE..."
            git push "$ORIGIN_REMOTE" "$LOCAL_BRANCH" 2>&1 | tee -a "$LOG_FILE"
        fi

        if [[ -n "$original_branch" && "$original_branch" != "$LOCAL_BRANCH" ]]; then
            git checkout "$original_branch" >/dev/null 2>&1 || true
        fi

        merged=true
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        exit 0
    fi

    restart_multi_bot
    if [[ "$merged" == "true" ]]; then
        log "Sync complete (merged upstream updates and restarted)."
    else
        log "Sync complete (no upstream updates, restarted anyway)."
    fi
}

main "$@"
