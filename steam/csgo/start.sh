#!/bin/bash
# start.sh - crash loop guard for csgo srcds
# wraps srcds_run, handles crash detection + cleanup
# sits in /home/container/ and gets called by ptero's startup cmd

# how many crashes before we give up (configurable from panel)
CRASH_LIMIT="${CRASH_LIMIT:-3}"
CRASH_WINDOW="${CRASH_WINDOW:-300}"   # seconds (5 min window)

# paths
CONTAINER_DIR="/home/container"
SENTINEL_FILE="${CONTAINER_DIR}/.shutdown_requested"
CRASH_TIMESTAMPS_FILE="${CONTAINER_DIR}/.crash_timestamps"
CRASH_LOG="${CONTAINER_DIR}/logs/crash_guard.log"

mkdir -p "${CONTAINER_DIR}/logs"

# logging helper
log() {
    echo "[crash-guard] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${CRASH_LOG}"
}

# nuke any .mdmp / core dumps so they don't eat disk space
clean_crash_dumps() {
    local count=0
    while IFS= read -r -d '' f; do
        rm -f -- "$f" && (( count++ ))
    done < <(find "${CONTAINER_DIR}" -maxdepth 5 \
        -type f \( -name "*.mdmp" -o -name "core" -o -name "core.*" \) \
        -print0 2>/dev/null)
    [ "${count}" -gt 0 ] && log "Cleaned ${count} crash dump(s)."
}

# count recent crashes, drop anything older than the window
crashes_in_window() {
    local now
    now=$(date +%s)
    local cutoff=$(( now - CRASH_WINDOW ))
    local recent=()
    if [ -f "${CRASH_TIMESTAMPS_FILE}" ]; then
        while IFS= read -r ts; do
            [ -n "${ts}" ] && [ "${ts}" -ge "${cutoff}" ] && recent+=("${ts}")
        done < "${CRASH_TIMESTAMPS_FILE}"
    fi
    printf '%s\n' "${recent[@]}" > "${CRASH_TIMESTAMPS_FILE}"
    echo "${#recent[@]}"
}

record_crash() {
    date +%s >> "${CRASH_TIMESTAMPS_FILE}"
}

# sigterm = user hit Stop in the panel
_sigterm_received=0
handle_sigterm() {
    # if we're already in the crash-lock sleep, just bail out
    if [ "${_in_sleep_lock}" -eq 1 ]; then
        log "Got shutdown while in crash-lock, exiting."
        rm -f "${SENTINEL_FILE}" "${CRASH_TIMESTAMPS_FILE}"
        exit 0
    fi
    _sigterm_received=1
    log "SIGTERM caught, forwarding to server..."
    touch "${SENTINEL_FILE}"
    # tell srcds to stop if it's still running
    if [ -n "${SRCDS_PID}" ] && kill -0 "${SRCDS_PID}" 2>/dev/null; then
        kill -TERM "${SRCDS_PID}"
        # wait up to 15s for it to die gracefully
        local waited=0
        while kill -0 "${SRCDS_PID}" 2>/dev/null && [ "${waited}" -lt 15 ]; do
            sleep 1; (( waited++ ))
        done
        kill -0 "${SRCDS_PID}" 2>/dev/null && kill -KILL "${SRCDS_PID}"
    fi
}
trap 'handle_sigterm' SIGTERM

# fresh start, clean up leftover files from last run
rm -f "${SENTINEL_FILE}" "${CRASH_TIMESTAMPS_FILE}"
log "Crash-loop guard started. CRASH_LIMIT=${CRASH_LIMIT}, CRASH_WINDOW=${CRASH_WINDOW}s"

# build the srcds command
# -norestart because we handle restarts ourselves
# no -autoupdate either, same reason
SRCDS_CMD=(
    ./srcds_run
    -game csgo
    -console
    +game_type "${GAME_TYPE:-0}"
    +game_mode "${GAME_MODE:-0}"
    +ip 0.0.0.0
    -port "${SERVER_PORT}"
    +map "${SRCDS_MAP:-de_dust2}"
    -norestart
    +sv_setsteamaccount "${STEAM_ACC}"
    -tickrate "${SRCDS_TICKRATE:-128}"
    +mapgroup "${SRCDS_MAPGROUP:-mg_allclassic}"
    -maxplayers_override "${MAX_PLAYERS:-32}"
    -steam_dir /home/container/steamcmd
    -steamcmd_script "/home/container/steamcmd/${SRCDS_APPID}_update.txt"
    -timeout 10
    -debuglog logs/latest.log
    -nobreakpad
)

# optional stuff
[ "${NOBOTS:-0}"    != "0" ] && SRCDS_CMD+=( -nobots )
[ "${NOMASTER:-0}"  != "0" ] && SRCDS_CMD+=( -nomaster )
[ "${INSECURE:-0}"  != "0" ] && SRCDS_CMD+=( -insecure )
[ "${NOHLTV:-0}"    != "0" ] && SRCDS_CMD+=( -nohltv )

# pass through any extra args from the panel's startup field
SRCDS_CMD+=( "$@" )

# main loop
_in_sleep_lock=0
while true; do
    log "Starting server..."

    # fifo trick: we pipe panel stdin (like "quit" cmd) into srcds
    # without this, the wrapper would eat stdin and the Stop button wouldn't work
    STDIN_FIFO="${CONTAINER_DIR}/.srcds_stdin_$$"
    mkfifo "${STDIN_FIFO}"
    # open read-write so it doesn't block (no reader yet)
    exec 3<>"${STDIN_FIFO}"

    # background relay: our stdin -> fifo -> srcds
    cat <&0 >"${STDIN_FIFO}" &
    RELAY_PID=$!

    # fire up the server
    "${SRCDS_CMD[@]}" <"${STDIN_FIFO}" &
    SRCDS_PID=$!

    # wait for srcds to exit (or for a signal)
    wait "${SRCDS_PID}"
    EXIT_CODE=$?

    # cleanup the fifo stuff
    exec 3>&-
    kill "${RELAY_PID}" 2>/dev/null
    wait "${RELAY_PID}" 2>/dev/null
    rm -f "${STDIN_FIFO}"

    # user clicked Stop
    if [ "${_sigterm_received}" -eq 1 ] || [ -f "${SENTINEL_FILE}" ]; then
        log "Clean shutdown (exit ${EXIT_CODE}), not restarting."
        rm -f "${SENTINEL_FILE}" "${CRASH_TIMESTAMPS_FILE}"
        exit 0
    fi

    # exit 0 = server processed "quit" on its own, don't loop
    if [ "${EXIT_CODE}" -eq 0 ]; then
        log "Server exited cleanly (exit 0), not restarting."
        exit 0
    fi

    # if we're here, it crashed
    log "Server crashed (exit code ${EXIT_CODE})."
    record_crash
    clean_crash_dumps

    COUNT=$(crashes_in_window)
    log "Crashes in last ${CRASH_WINDOW}s: ${COUNT}/${CRASH_LIMIT}"

    if [ "${COUNT}" -ge "${CRASH_LIMIT}" ]; then
        log "=========================================================="
        log "CRASH LIMIT HIT (${COUNT} crashes in ${CRASH_WINDOW}s)."
        log "Server halted to prevent disk usage from crash dumps."
        log "Check logs/latest.log and logs/crash_guard.log."
        log "Hit Stop or Restart in the panel to try again."
        log "=========================================================="
        # we can't just exit here because ptero would restart us
        # so we sleep forever until the user manually stops/restarts
        _in_sleep_lock=1
        while true; do
            sleep 3600 &
            wait $!
        done
    fi

    WAIT_SECS=5
    log "Waiting ${WAIT_SECS}s before restart..."
    sleep "${WAIT_SECS}"
done
