#!/bin/sh
# ==============================================================================
# Monthly Traefik Access Log Rotation Script
# ==============================================================================
# - Runs inside the traefik-logrotate container (or manually via docker exec).
# - Renames /var/log/ACCESS_LOGS/access.log to access-YYYY-MM.log
# - Sends SIGUSR1 to the Traefik container so it reopens a fresh access.log
#   immediately without dropping any requests.
# - Waits briefly for in-flight writes and log shippers (Vector) to finish
#   reading the rotated file, then compresses it to access-YYYY-MM.log.gz.
# - Keeps all rotated monthly logs forever (never deletes old archives).
# ==============================================================================

set -eu

LOG_DIR="/var/log/ACCESS_LOGS"
ACTIVE_LOG="${LOG_DIR}/access.log"
ROTATE_LOG="${LOG_DIR}/rotation.log"

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_msg() {
    echo "$(timestamp) [logrotate] $*" | tee -a "${ROTATE_LOG}"
}

if [ ! -f "${ACTIVE_LOG}" ]; then
    log_msg "No ${ACTIVE_LOG} found; nothing to rotate."
    exit 0
fi

if [ ! -s "${ACTIVE_LOG}" ]; then
    log_msg "${ACTIVE_LOG} is empty (0 bytes); skipping rotation."
    exit 0
fi

# When triggered on the 1st of the month (e.g. 2026-12-01 00:00), label the
# archive with the month that just ended (e.g. 2026-11).
# If triggered mid-month, label with current YYYY-MM.
DAY_OF_MONTH="$(date +%d)"
if [ "${DAY_OF_MONTH}" = "01" ] || [ "${DAY_OF_MONTH}" = "1" ]; then
    # 12 hours ago is guaranteed to be the last day of the previous month
    ARCHIVE_MONTH="$(date -d "@$(( $(date +%s) - 43200 ))" +%Y-%m)"
else
    ARCHIVE_MONTH="$(date +%Y-%m)"
fi

ROTATED_BASE="${LOG_DIR}/access-${ARCHIVE_MONTH}"
ROTATED_FILE="${ROTATED_BASE}.log"

# Never overwrite an existing monthly archive if one already exists
if [ -e "${ROTATED_FILE}" ] || [ -e "${ROTATED_FILE}.gz" ]; then
    SUFFIX="$(date +%Y%m%d-%H%M%S)"
    ROTATED_FILE="${ROTATED_BASE}_${SUFFIX}.log"
fi

log_msg "Rotating ${ACTIVE_LOG} -> ${ROTATED_FILE}"
mv "${ACTIVE_LOG}" "${ROTATED_FILE}"

# Send SIGUSR1 to all local Traefik containers so Traefik closes the rotated
# file descriptor and opens a new /var/log/ACCESS_LOGS/access.log immediately.
TRAEFIK_CONTAINERS="$(docker ps -q --filter "name=traefik_traefik-reverse-proxy" 2>/dev/null || true)"
if [ -z "${TRAEFIK_CONTAINERS}" ]; then
    # Fallback filter by image ancestor in case stack name differs
    TRAEFIK_CONTAINERS="$(docker ps -q --filter "ancestor=traefik:3.6" 2>/dev/null || true)"
fi

if [ -n "${TRAEFIK_CONTAINERS}" ]; then
    for CID in ${TRAEFIK_CONTAINERS}; do
        log_msg "Sending SIGUSR1 to Traefik container ${CID}"
        docker kill --signal=USR1 "${CID}" >/dev/null
    done
else
    log_msg "WARNING: No running Traefik container found to send SIGUSR1."
fi

# Wait 10 seconds to ensure Traefik flushes final lines and Vector finishes
# reading the end of the rotated file before compression.
sleep 10

log_msg "Compressing ${ROTATED_FILE} -> ${ROTATED_FILE}.gz"
gzip -9 "${ROTATED_FILE}"

log_msg "Rotation complete: ${ROTATED_FILE}.gz"
