#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh

transport="${MAVLINK_TRANSPORT:-serial}"
args=()

if [[ -n "${MAVLINK_UDP_ENDPOINTS:-}" ]]; then
    read -r -a endpoints <<< "${MAVLINK_UDP_ENDPOINTS}"
    for endpoint in "${endpoints[@]}"; do
        args+=(-e "${endpoint}")
    done
fi

if [[ "${MAVLINK_ENABLE_FLIGHT_LOG:-false}" == "true" ]]; then
    mkdir -p /workspace/log/mavlink
    args+=(-l /workspace/log/mavlink)
fi

case "${transport}" in
    serial)
        xrce_device="${XRCE_SERIAL_DEVICE:-}"
        if [[ "${XRCE_TRANSPORT:-serial}" != "serial" ]]; then
            xrce_device=
        fi
        device="$(resolve-device \
            MAVLink \
            "${MAVLINK_SERIAL_DEVICE:-auto}" \
            "${MAVLINK_SERIAL_CANDIDATES:-/dev/ttyACM0}" \
            "${xrce_device}")"
        echo "Starting mavlink-routerd on ${device} at ${MAVLINK_BAUD:-921600}." >&2
        exec mavlink-routerd "${args[@]}" "${device}:${MAVLINK_BAUD:-921600}"
        ;;
    udp)
        echo "Starting mavlink-routerd UDP server on ${MAVLINK_UDP_LISTEN:-0.0.0.0:24550}." >&2
        exec mavlink-routerd "${args[@]}" "${MAVLINK_UDP_LISTEN:-0.0.0.0:24550}"
        ;;
    *)
        echo "ERROR: MAVLINK_TRANSPORT must be serial or udp, got '${transport}'." >&2
        exit 2
        ;;
esac
