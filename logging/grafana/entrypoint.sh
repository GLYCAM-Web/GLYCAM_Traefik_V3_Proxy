#!/bin/sh
# ==============================================================================
# Grafana Container Entrypoint Wrapper
# ==============================================================================
# Copies provisioned dashboards from /var/lib/grafana/dashboards-src to
# /tmp/dashboards and injects any local internal IP/CIDR exclusions from
# /etc/logging-config/internal_ips.local.conf or $INTERNAL_IP_CIDRS into the
# dashboard filter queries at runtime, keeping git-tracked JSON files free of
# private/team IP addresses.
# ==============================================================================

set -eu

SRC_DIR="/var/lib/grafana/dashboards-src"
DST_DIR="/tmp/dashboards"
LOCAL_IPS_FILE="/etc/logging-config/internal_ips.local.conf"

mkdir -p "${DST_DIR}"
cp -f "${SRC_DIR}"/*.json "${DST_DIR}/" 2>/dev/null || true

EXTRA_OR_LIST=""

append_cidr() {
    raw="$1"
    [ -z "${raw}" ] && return 0
    case "${raw}" in
        *[!0-9a-fA-F.:/]*)
            return 0
            ;;
    esac
    case "${raw}" in
        */*) cidr="${raw}" ;;
        *:*) cidr="${raw}/128" ;;
        *.*) cidr="${raw}/32" ;;
        *)   return 0 ;;
    esac
    EXTRA_OR_LIST="${EXTRA_OR_LIST} or ${cidr}"
}

if [ -f "${LOCAL_IPS_FILE}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
        clean="$(printf '%s' "${line}" | sed 's/#.*//; s/[[:space:]]//g')"
        [ -n "${clean}" ] && append_cidr "${clean}"
    done < "${LOCAL_IPS_FILE}"
fi

if [ -n "${INTERNAL_IP_CIDRS:-}" ]; then
    OLD_IFS="${IFS}"
    IFS=", "
    for token in ${INTERNAL_IP_CIDRS}; do
        [ -n "${token}" ] && append_cidr "${token}"
    done
    IFS="${OLD_IFS}"
fi

if [ -n "${EXTRA_OR_LIST}" ]; then
    for f in "${DST_DIR}"/*.json; do
        [ -f "$f" ] || continue
        sed -i "s|192.168.0.0/16|192.168.0.0/16${EXTRA_OR_LIST}|g" "$f"
    done
fi

exec /run.sh "$@"
