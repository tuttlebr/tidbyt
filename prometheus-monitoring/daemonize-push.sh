#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://192.168.1.234:30500}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"
RETRY_INTERVAL_SECONDS="${RETRY_INTERVAL_SECONDS:-90}"
COMMAND_TIMEOUT_SECONDS="${COMMAND_TIMEOUT_SECONDS:-30}"
EXPECTED_GPU_COUNT="${EXPECTED_GPU_COUNT:-0}"
STATUS_DIR="${STATUS_DIR:-/tmp/tidbyt-status}"

log() {
    printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

for setting in POLL_INTERVAL_SECONDS RETRY_INTERVAL_SECONDS COMMAND_TIMEOUT_SECONDS; do
    if [[ ! "${!setting}" =~ ^[1-9][0-9]{0,5}$ ]]; then
        log "Configuration error: $setting must be a positive integer (at most 999999)."
        exit 1
    fi
done
if [[ ! "$EXPECTED_GPU_COUNT" =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
    log "Configuration error: EXPECTED_GPU_COUNT must be a nonnegative integer."
    exit 1
fi
HEALTH_MAX_AGE_SECONDS="${HEALTH_MAX_AGE_SECONDS:-$((POLL_INTERVAL_SECONDS + RETRY_INTERVAL_SECONDS + 3 * COMMAND_TIMEOUT_SECONDS + 60))}"
if [[ ! "$HEALTH_MAX_AGE_SECONDS" =~ ^[1-9][0-9]{0,6}$ ]]; then
    log "Configuration error: HEALTH_MAX_AGE_SECONDS must be a positive integer."
    exit 1
fi

mode="${1:-daemonize}"
if [[ "$mode" == healthcheck ]]; then
    last_success=""
    [[ -r "$STATUS_DIR/last-success" ]] || exit 1
    read -r last_success < "$STATUS_DIR/last-success"
    [[ "$last_success" =~ ^[1-9][0-9]{0,11}$ ]] || exit 1
    age=$(( $(date +%s) - last_success ))
    (( age >= 0 && age <= HEALTH_MAX_AGE_SECONDS ))
    exit $?
fi
if [[ "$mode" != render && "$mode" != daemonize ]]; then
    log "Usage: $0 [daemonize|render|healthcheck]"
    exit 1
fi
if [[ "$mode" == daemonize ]]; then
    for setting in DEVICE_ID TIDBYT_API_TOKEN; do
        if [[ -z "${!setting:-}" ]]; then
            log "Configuration error: $setting is required."
            exit 1
        fi
    done
    mkdir -p -- "$STATUS_DIR" || exit 1
    rm -f -- "$STATUS_DIR/last-success" || exit 1
fi

work_dir="$(mktemp -d)" || exit 1
child_pid=""
trap 'rm -rf -- "$work_dir"' EXIT
stop() {
    trap '' TERM INT
    if [[ -n "$child_pid" ]]; then
        kill -TERM "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    exit 0
}
trap stop TERM INT

run_command() {
    "$@" &
    child_pid=$!
    wait "$child_pid"
    local result=$?
    child_pid=""
    return "$result"
}

render_frame() {
    degraded=0
    # A private output path prevents reuse of images from earlier runs/builds.
    rm -f -- "$work_dir/frame.webp" || return 1
    if ! run_command timeout --kill-after=5s "${COMMAND_TIMEOUT_SECONDS}s" \
        pixlet render "$SCRIPT_DIR/prometheus-monitoring.star" \
        "prometheus_url=$PROMETHEUS_URL" "expected_gpu_count=$EXPECTED_GPU_COUNT" \
        --timeout "$((COMMAND_TIMEOUT_SECONDS * 1000))" --output "$work_dir/frame.webp"; then
        degraded=1
        log "Render failed or timed out; rendering an offline Unavailable frame."
        rm -f -- "$work_dir/frame.webp" || return 1
        if ! run_command timeout --kill-after=5s "${COMMAND_TIMEOUT_SECONDS}s" \
            pixlet render "$SCRIPT_DIR/prometheus-monitoring.star" offline=true \
            --timeout "$((COMMAND_TIMEOUT_SECONDS * 1000))" --output "$work_dir/frame.webp"; then
            log "Offline render failed; no image will be pushed."
            return 1
        fi
    fi
    if [[ ! -s "$work_dir/frame.webp" ]]; then
        log "Render produced no image; no image will be pushed."
        return 1
    fi
}

if [[ "$mode" == render ]]; then
    render_frame || exit 1
    mv -- "$work_dir/frame.webp" "$SCRIPT_DIR/prometheus-monitoring.webp" || exit 1
    log "Rendered $SCRIPT_DIR/prometheus-monitoring.webp"
    exit 0
fi

log "Starting GPU power updates (poll=${POLL_INTERVAL_SECONDS}s, retry=${RETRY_INTERVAL_SECONDS}s)."
while true; do
    delay="$RETRY_INTERVAL_SECONDS"
    if render_frame; then
        if run_command timeout --kill-after=5s "${COMMAND_TIMEOUT_SECONDS}s" \
            pixlet push "$DEVICE_ID" "$work_dir/frame.webp"; then
            if date +%s > "$STATUS_DIR/last-success.tmp" && \
                mv -- "$STATUS_DIR/last-success.tmp" "$STATUS_DIR/last-success"; then
                log "Tidbyt upload succeeded."
            else
                log "Tidbyt upload succeeded, but recording the health timestamp failed."
            fi
            if (( degraded == 0 )); then
                delay="$POLL_INTERVAL_SECONDS"
            fi
        else
            log "Tidbyt upload failed or timed out; retrying with a new render in ${delay}s."
        fi
    else
        log "No new frame available; retrying in ${delay}s."
    fi
    run_command sleep "$delay"
done
