#!/bin/sh
# ==============================================================================
# Vector Container Entrypoint Wrapper
# ==============================================================================
# 1. Copies /etc/vector/vector.yaml to /tmp/vector.yaml.
# 2. Loads any local internal IP/CIDR ranges from:
#    - /etc/logging-config/internal_ips.local.conf (git-ignored file)
#    - $INTERNAL_IP_CIDRS (environment variable from config.bash)
#    and injects them into the VRL ip_cidr_contains() list in /tmp/vector.yaml.
# 3. Checks if /etc/vector/geoip/GeoLite2-City.mmdb exists; if missing, disables
#    the GeoIP enrichment block so Vector starts cleanly without failing.
# ==============================================================================

set -eu

SRC_CFG="/etc/vector/vector.yaml"
RUNTIME_CFG="/tmp/vector.yaml"
LOCAL_IPS_FILE="/etc/logging-config/internal_ips.local.conf"
MMDB_FILE="/etc/vector/geoip/GeoLite2-City.mmdb"

cp "${SRC_CFG}" "${RUNTIME_CFG}"

# Collect extra internal CIDRs from local file and environment variable
EXTRA_CIDRS=""

append_cidr() {
    raw="$1"
    if [ -z "${raw}" ]; then
        return 0
    fi
    # Reject anything with characters outside valid IPv4/IPv6/CIDR charset
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
    if [ -z "${EXTRA_CIDRS}" ]; then
        EXTRA_CIDRS="\"${cidr}\""
    else
        EXTRA_CIDRS="${EXTRA_CIDRS}, \"${cidr}\""
    fi
}

if [ -f "${LOCAL_IPS_FILE}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
        clean="$(printf '%s' "${line}" | sed 's/#.*//; s/[[:space:]]//g')"
        if [ -n "${clean}" ]; then
            append_cidr "${clean}"
        fi
    done < "${LOCAL_IPS_FILE}"
fi

if [ -n "${INTERNAL_IP_CIDRS:-}" ]; then
    OLD_IFS="${IFS}"
    IFS=", "
    for token in ${INTERNAL_IP_CIDRS}; do
        if [ -n "${token}" ]; then
            append_cidr "${token}"
        fi
    done
    IFS="${OLD_IFS}"
fi

if [ -n "${EXTRA_CIDRS}" ]; then
    echo "[vector-entrypoint] Loaded local internal IP CIDRs into runtime config."
    sed -i "s|\"192.168.0.0/16\"|\"192.168.0.0/16\", ${EXTRA_CIDRS}|g" "${RUNTIME_CFG}"
fi

# Gracefully disable GeoIP lookup if GeoLite2-City.mmdb has not been placed in logging/geoip/ yet
if [ ! -s "${MMDB_FILE}" ]; then
    echo "[vector-entrypoint] NOTE: ${MMDB_FILE} not found; starting Vector without GeoIP enrichment."
    sed -i '/^enrichment_tables:/,/^sources:/{ /^sources:/!d; }' "${RUNTIME_CFG}"
    sed -i '/# BEGIN_GEOIP_ENRICHMENT/,/# END_GEOIP_ENRICHMENT/d' "${RUNTIME_CFG}"
fi

exec vector --config "${RUNTIME_CFG}"
