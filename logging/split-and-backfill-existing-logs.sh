#!/usr/bin/env bash
# ==============================================================================
# Split & Backfill Traefik Access Logs into VictoriaLogs (with GeoIP & Bot Tags)
# ==============================================================================
# Usage:
#   # 1. Split active access.log (if unsplit) AND backfill all access-*.log[.gz]
#   #    archives through Vector (adds GeoIP + is_bot + is_internal) into VictoriaLogs:
#   bash logging/split-and-backfill-existing-logs.sh --backfill
#
#   # 2. Wipe existing VictoriaLogs DB first (to avoid duplicates from an earlier
#   #    partial/unenriched run) and backfill all historical + active logs cleanly:
#   bash logging/split-and-backfill-existing-logs.sh --backfill --reset-db
#
#   # 3. Only split & compress access.log without backfilling VictoriaLogs:
#   bash logging/split-and-backfill-existing-logs.sh
# ==============================================================================

set -euo pipefail

LOG_DIR="./ACCESS_LOGS"
ACTIVE_LOG="${LOG_DIR}/access.log"
STAGING_LOG="${LOG_DIR}/access-pre-split.log"
DO_BACKFILL="NO"
DO_RESET_DB="NO"

for arg in "$@"; do
    case "$arg" in
        --backfill)
            DO_BACKFILL="YES"
            ;;
        --reset-db)
            DO_RESET_DB="YES"
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: bash logging/split-and-backfill-existing-logs.sh [--backfill] [--reset-db]"
            exit 1
            ;;
    esac
done

if [[ ! -d "${LOG_DIR}" ]]; then
    echo "ERROR: Directory ${LOG_DIR} does not exist. Run this from the repo root."
    exit 1
fi

# ------------------------------------------------------------------------------
# Optional Step 0: Reset VictoriaLogs & Vector checkpoints for a clean backfill
# ------------------------------------------------------------------------------
if [[ "${DO_RESET_DB}" == "YES" ]]; then
    echo "Step 0: Resetting VictoriaLogs database and Vector checkpoints for a clean import..."
    docker service scale traefik_victorialogs=0 || true
    sleep 3
    if ! rm -rf ./logging/data/victorialogs/* ./logging/data/vector/* 2>/dev/null; then
        echo "  Files are owned by root (created by Docker); cleaning via ephemeral container..."
        docker run --rm -v "$(pwd)/logging/data:/data" alpine:3.20 \
            sh -c 'rm -rf /data/victorialogs/* /data/vector/*'
    fi
    docker service scale traefik_victorialogs=1 || true
    echo "  Waiting 5s for VictoriaLogs to start..."
    sleep 5
fi

# ------------------------------------------------------------------------------
# Step 1 & 2: Split multi-month access.log (or access-pre-split.log) if needed
# ------------------------------------------------------------------------------
CURRENT_MONTH="$(date -u +%Y-%m)"
NEED_SPLIT="NO"

shopt -s nullglob
EXISTING_MONTHLY=("${LOG_DIR}"/access-[0-9][0-9][0-9][0-9]-[0-9][0-9]*.log "${LOG_DIR}"/access-[0-9][0-9][0-9][0-9]-[0-9][0-9]*.log.gz)
shopt -u nullglob

if [[ -f "${STAGING_LOG}" && -s "${STAGING_LOG}" ]]; then
    if [[ ${#EXISTING_MONTHLY[@]} -gt 0 ]]; then
        echo "Step 1-2: Monthly archives already exist; skipping re-split of ${STAGING_LOG} to avoid duplicating lines."
    else
        NEED_SPLIT="YES"
    fi
elif [[ -f "${ACTIVE_LOG}" && -s "${ACTIVE_LOG}" ]]; then
    # Check if the first line of access.log belongs to an older month than CURRENT_MONTH
    FIRST_LINE="$(head -n 1 "${ACTIVE_LOG}" || true)"
    if [[ -n "${FIRST_LINE}" ]] && ! grep -q "\"${CURRENT_MONTH}" <<< "${FIRST_LINE}"; then
        echo "Step 1: Rotating multi-month ${ACTIVE_LOG} -> ${STAGING_LOG} and signaling Traefik..."
        mv "${ACTIVE_LOG}" "${STAGING_LOG}"
        TRAEFIK_CIDS="$(docker ps -q --filter "name=traefik_traefik-reverse-proxy" 2>/dev/null || true)"
        if [[ -n "${TRAEFIK_CIDS}" ]]; then
            for CID in ${TRAEFIK_CIDS}; do
                echo "  Sending SIGUSR1 to Traefik container ${CID}..."
                docker kill --signal=USR1 "${CID}" >/dev/null
            done
        fi
        sleep 2
        NEED_SPLIT="YES"
    fi
fi

if [[ "${NEED_SPLIT}" == "YES" ]]; then
    echo "Step 2: Splitting ${STAGING_LOG} into monthly files (${LOG_DIR}/access-YYYY-MM.log)..."
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
    echo "  Split complete."
else
    echo "Step 1-2: No unsplit multi-month access.log found; proceeding to existing monthly archives."
fi

# ------------------------------------------------------------------------------
# Step 3: Backfill all monthly archives (.log and .log.gz) through Vector
#         so every historical entry gets GeoIP + is_bot + is_internal fields!
# ------------------------------------------------------------------------------
if [[ "${DO_BACKFILL}" == "YES" ]]; then
    if [[ -f ./config.bash ]]; then
        # shellcheck disable=SC1091
        source ./config.bash
    fi

    echo "Step 3: Backfilling historical monthly archives through Vector (GeoIP + bot/internal enrichment)..."
    shopt -s nullglob
    ARCHIVES=(
        "${LOG_DIR}"/access-[0-9][0-9][0-9][0-9]-[0-9][0-9]*.log.gz
        "${LOG_DIR}"/access-[0-9][0-9][0-9][0-9]-[0-9][0-9]*.log
    )
    shopt -u nullglob

    if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
        echo "  WARNING: No ${LOG_DIR}/access-YYYY-MM.log[.gz] archives found to backfill."
    else
        ABS_REPO="$(pwd)"
        for archive in "${ARCHIVES[@]}"; do
            [[ -e "${archive}" ]] || continue
            echo "  -> Enriching and ingesting ${archive} into VictoriaLogs..."
            if [[ "${archive}" == *.gz ]]; then
                DECOMPRESS_CMD=(gzip -dc "${archive}")
            else
                DECOMPRESS_CMD=(cat "${archive}")
            fi

            "${DECOMPRESS_CMD[@]}" | docker run --rm -i \
                --network traefik_proxy_net \
                --entrypoint /bin/sh \
                -e INTERNAL_IP_CIDRS="${INTERNAL_IP_CIDRS:-}" \
                -v "${ABS_REPO}/logging/vector/vector.yaml:/etc/vector/vector.yaml:ro" \
                -v "${ABS_REPO}/logging/vector/entrypoint.sh:/etc/vector/entrypoint.sh:ro" \
                -v "${ABS_REPO}/logging/geoip:/etc/vector/geoip:ro" \
                -v "${ABS_REPO}/logging:/etc/logging-config:ro" \
                timberio/vector:0.42.0-alpine -c '
                    sed "s|exec vector --config.*|true|" /etc/vector/entrypoint.sh > /tmp/prep.sh
                    sh /tmp/prep.sh
                    sed "/^sources:/,/^transforms:/c\\
sources:\\
  traefik_access_logs:\\
    type: stdin\\
\\
transforms:" /tmp/vector.yaml > /tmp/vector_stdin.yaml
                    exec vector --config /tmp/vector_stdin.yaml --quiet
                '
            echo "     Finished ${archive}."
        done
    fi
fi

# ------------------------------------------------------------------------------
# Step 4: Compress any uncompressed access-YYYY-MM.log files
# ------------------------------------------------------------------------------
echo "Step 4: Ensuring all monthly access-YYYY-MM.log archives are gzip-compressed..."
shopt -s nullglob
UNCOMPRESSED=("${LOG_DIR}"/access-[0-9][0-9][0-9][0-9]-[0-9][0-9]*.log)
shopt -u nullglob

for f in "${UNCOMPRESSED[@]}"; do
    [[ -e "$f" ]] || continue
    echo "  Compressing $f -> ${f}.gz ..."
    gzip -9 "$f"
done

if [[ "${DO_RESET_DB}" == "YES" ]]; then
    echo "Restarting live traefik_vector service to re-read current ${ACTIVE_LOG}..."
    docker service update --force traefik_vector || true
fi

echo ""
echo "All done!"
if [[ -f "${STAGING_LOG}" ]]; then
    echo "Once you have verified your archives and Grafana stats, you can remove the staging copy:"
    echo "  rm ${STAGING_LOG}"
fi
