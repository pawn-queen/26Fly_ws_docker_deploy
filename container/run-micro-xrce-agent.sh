#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh

transport="${XRCE_TRANSPORT:-serial}"
verbosity_args=()
if [[ -n "${XRCE_VERBOSE:-}" ]]; then
    if ! [[ "${XRCE_VERBOSE}" =~ ^[0-6]$ ]]; then
        echo "ERROR: XRCE_VERBOSE must be empty or an integer from 0 to 6." >&2
        exit 2
    fi
    verbosity_args=(-v "${XRCE_VERBOSE}")
fi

case "${transport}" in
    serial)
        mavlink_device="${MAVLINK_SERIAL_DEVICE:-}"
        if [[ "${MAVLINK_TRANSPORT:-serial}" != "serial" ]]; then
            mavlink_device=
        fi
        device="$(resolve-device \
            XRCE \
            "${XRCE_SERIAL_DEVICE:-auto}" \
            "${XRCE_SERIAL_CANDIDATES:-}" \
            "${mavlink_device}")"
        echo "Starting Micro XRCE-DDS Agent on ${device} at ${XRCE_BAUD:-921600}." >&2
        exec MicroXRCEAgent serial --dev "${device}" -b "${XRCE_BAUD:-921600}" "${verbosity_args[@]}"
        ;;
    udp4)
        echo "Starting Micro XRCE-DDS Agent on UDP port ${XRCE_UDP_PORT:-8888}." >&2
        exec MicroXRCEAgent udp4 -p "${XRCE_UDP_PORT:-8888}" "${verbosity_args[@]}"
        ;;
    *)
        echo "ERROR: XRCE_TRANSPORT must be serial or udp4, got '${transport}'." >&2
        exit 2
        ;;
esac
