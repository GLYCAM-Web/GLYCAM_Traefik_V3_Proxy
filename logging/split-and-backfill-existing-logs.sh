#!/usr/bin/env bash
# ==============================================================================
# Split & Backfill Existing Large Traefik access.log (e.g., 220+ GB)
# ==============================================================================
# Usage:
#   bash logging/split-and-backfill-existing-logs.sh [--backfill]
#
# What this script does:
# 1. Safely renames the current ./ACCESS_LOGS/access.log to
#    ./ACCESS_LOGS/access-pre-split.log and sends SIGUSR1 to Traefik so live
#    traffic immediately starts writing to a fresh ./ACCESS_LOGS/access.log.
# 2. Streams ./ACCESS_LOGS/access-pre-split.log through a fast single-pass awk
#    splitter that extracts the YYYY-MM month from "StartUTC":"YYYY-MM-..."
#    (or "StartLocal") and appends each line into ./ACCESS_LOGS/access-YYYY-MM.log.
# 3. If --backfill is passed, streams each monthly file into VictoriaLogs
#    (http://127.0.0.1:9428) so all historical months are searchable in Grafana.
# 4. Compresses completed monthly files into ./ACCESS_LOGS/access-YYYY-MM.log.gz.
#    (The original access-pre-split.log is kept until you verify and delete it.)
# ==============================================================================

set -euo pipefail

LOG_DIR="./ACCESS_LOGS"
ACTIVE_LOG="${LOG_DIR}/access.log"
STAGING_LOG="${LOG_DIR}/access-pre-split.log"
VICTORIALOGS_URL="${VICTORIALOGS_URL:-http://127.0.0.1:9428}"
DO_BACKFILL="NO"

if [[ "${1:-}" == "--backfill" ]]; then
    DO_BACKFILL="YES"
fi

if [[ ! -d "${LOG_DIR}" ]]; then
    echo "ERROR: Directory ${LOG_DIR} does not exist. Run this from the repo root."
    exit 1
fi

if [[ -f "${STAGING_LOG}" ]]; then
    echo "Found existing ${STAGING_LOG}; resuming split from it..."
elif [[ -f "${ACTIVE_LOG}" && -s "${ACTIVE_LOG}" ]]; then
    echo "Step 1: Rotating ${ACTIVE_LOG} -> ${STAGING_LOG} and signaling Traefik..."
    mv "${ACTIVE_LOG}" "${STAGING_LOG}"
    TRAEFIK_CIDS="$(docker ps -q --filter "name=traefik_traefik-reverse-proxy" 2>/dev/null || true)"
    if [[ -n "${TRAEFIK_CIDS}" ]]; then
        for CID in ${TRAEFIK_CIDS}; do
            echo "  Sending SIGUSR1 to Traefik container ${CID}..."
            docker kill --signal=USR1 "${CID}" >/dev/null
        done
    else
        echo "  NOTE: No running Traefik container found; skipped SIGUSR1."
    fi
    sleep 2
else
    echo "Nothing to split: ${ACTIVE_LOG} does not exist or is empty."
    exit 0
fi

echo "Step 2: Splitting ${STAGING_LOG} into monthly files (${LOG_DIR}/access-YYYY-MM.log)..."
echo "        (For a ~220 GB file, this single-pass awk stream typically takes ~8-15 minutes.)"

awk -v logdir="${LOG_DIR}" '
{
    month = "unknown"
    if (match($0, /"StartUTC":"[0-9]{4}-[0-9]{2}/)) {
        month = substr($0, RSTART + 12, 7)
    } else if (match($0, /"StartLocal":"[0-9]{4}-[0-9]{2}/)) {
        month = substr($0, RSTART + 14, 7)
    } else if (match($0, /"time":"[0-9]{4}-[0-9]{2}/)) {
        month = substr($0, RSTART + 8, 7)
    }
    outfile = logdir "/access-" month ".log"
    print $0 >> outfile
}
' "${STAGING_LOG}"

echo "Step 2 complete. Monthly files created:"
ls -lh "${LOG_DIR}"/access-[0-9][0-9][0-9][0-9]-[0-9][0-9].log 2>/dev/null || true

if [[ "${DO_BACKFILL}" == "YES" ]]; then
    echo "Step 3: Backfilling monthly files into VictoriaLogs over traefik_proxy_net..."
    for f in "${LOG_DIR}"/access-[0-9][0-9][0-9][0-9]-[0-9][0-9].log; do
        [[ -e "$f" ]] || continue
        echo "  Ingesting $f ..."
        docker run --rm -i --network traefik_proxy_net curlimages/curl:8.11.0 \
            -sS -X POST "http://victorialogs:9428/insert/jsonline?_stream_fields=RequestHost,ServiceName&_time_field=StartUTC&_msg_field=RequestPath" \
            -H "Content-Type: application/stream+json" \
            --data-binary @- < "$f"
        echo "  Done ingesting $f."
    done
fi

echo "Step 4: Compressing monthly files with gzip..."
for f in "${LOG_DIR}"/access-[0-9][0-9][0-9][0-9]-[0-9][0-9].log; do
    [[ -e "$f" ]] || continue
    echo "  Compressing $f -> ${f}.gz ..."
    gzip -9 "$f"
done

echo ""
echo "All done!"
echo "Once you have verified your new ${LOG_DIR}/access-YYYY-MM.log.gz archives, you can remove:"
echo "  rm ${STAGING_LOG}"
