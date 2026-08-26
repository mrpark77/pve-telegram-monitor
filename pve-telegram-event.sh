#!/usr/bin/env bash
#
# pve-telegram-event.sh
#
# Proxmox VM/LXC state monitor
# Version: 2.4.0
#

set -u
set -o pipefail

VERSION="2.4.0"

CONFIG_FILE="/etc/pve-telegram-monitor/config"

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""


# ============================================================
# Basic functions
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}


die() {
    echo "ERROR: $*" >&2
    exit 1
}


# ============================================================
# Configuration
# ============================================================

load_config() {

    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Configuration file not found: $CONFIG_FILE"
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        die "TELEGRAM_BOT_TOKEN is not configured."
    fi

    if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        die "TELEGRAM_CHAT_ID is not configured."
    fi
}


# ============================================================
# Telegram
# ============================================================

telegram_send() {

    local message="$1"

    curl -fsS \
        --max-time 30 \
        -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --data-urlencode "disable_web_page_preview=true" \
        >/dev/null
}


# ============================================================
# Get VM/LXC name
# ============================================================

get_name() {

    local type="$1"
    local id="$2"

    local name=""

    if [[ "$type" == "VM" ]]; then

        name=$(qm config "$id" 2>/dev/null |
            awk -F': ' '/^name:/ {
                print $2
                exit
            }')

    elif [[ "$type" == "LXC" ]]; then

        name=$(pct config "$id" 2>/dev/null |
            awk -F': ' '/^hostname:/ {
                print $2
                exit
            }')

    fi

    [[ -z "$name" ]] && name="Unknown"

    echo "$name"
}


# ============================================================
# Send VM/LXC state notification
# ============================================================

send_state_change() {

    local type="$1"
    local id="$2"
    local action="$3"

    local name
    name=$(get_name "$type" "$id")

    local emoji
    local action_text

    case "$action" in

        start)
            emoji="🟢"
            action_text="시작"
            ;;

        stop)
            emoji="🔴"
            action_text="종료"
            ;;

        *)
            emoji="🟠"
            action_text="$action"
            ;;

    esac

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    local message

    message="${emoji} Proxmox ${type} ${action_text}"
    message+=$'\n'
    message+=$'\n'
    message+="${type} ${id} · ${name}"
    message+=$'\n'
    message+="${now}"

    if telegram_send "$message"; then

        log "${type} ${id} (${name}): ${action_text} notification sent"

    else

        log "ERROR: Failed to send Telegram notification for ${type} ${id}"

    fi
}


# ============================================================
# Send host notification
# ============================================================

send_host_state() {

    local action="$1"

    local emoji
    local action_text

    case "$action" in

        start)
            emoji="🟢"
            action_text="시작"
            ;;

        stop)
            emoji="🔴"
            action_text="종료"
            ;;

        reboot)
            emoji="🔄"
            action_text="재부팅"
            ;;

        *)
            emoji="🟠"
            action_text="$action"
            ;;

    esac

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    local message

    message="${emoji} Proxmox 호스트 ${action_text}"
    message+=$'\n'
    message+=$'\n'
    message+="Host · $(hostname)"
    message+=$'\n'
    message+="${now}"

    if telegram_send "$message"; then

        log "Host (${action_text}): notification sent"

    else

        log "ERROR: Failed to send Telegram host notification"

    fi
}


# ============================================================
# Parse Proxmox task start event
#
# Only process "starting task UPID" lines.
#
# A reboot is intentionally NOT handled as "reboot".
#
# qmreboot / vzreboot produces the actual shutdown/start
# events as the guest is restarted.
#
# Therefore:
#
#   reboot request
#       ↓
#   shutdown event → 🔴 종료
#       ↓
#   start event    → 🟢 시작
#
# This gives the same result for both manual reboot and
# host reboot/autostart.
# ============================================================

handle_event() {

    local line="$1"

    [[ "$line" == *"starting task UPID:"* ]] || return 0


    local type=""
    local id=""
    local action=""


    # --------------------------------------------------------
    # QEMU VM
    # --------------------------------------------------------

    if [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:qmstart:([0-9]+): ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="start"

    elif [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:qmshutdown:([0-9]+): ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="stop"

    elif [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:qmstop:([0-9]+): ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="stop"

    # --------------------------------------------------------
    # Ignore qmreboot itself.
    #
    # The actual shutdown/start events are what we want.
    # --------------------------------------------------------

    elif [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:qmreboot:([0-9]+): ]]; then

        return 0


    # --------------------------------------------------------
    # LXC
    # --------------------------------------------------------

    elif [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:vzstart:([0-9]+): ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="start"

    elif [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:vzshutdown:([0-9]+): ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="stop"

    elif [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:vzstop:([0-9]+): ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="stop"

    # --------------------------------------------------------
    # Ignore vzreboot itself.
    # --------------------------------------------------------

    elif [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:vzreboot:([0-9]+): ]]; then

        return 0

    else

        return 0

    fi


    send_state_change "$type" "$id" "$action"
}


# ============================================================
# Monitor
# ============================================================

monitor() {

    load_config

    log "Proxmox VM/LXC event monitor started."
    log "Mode: system journal event monitoring"
    log "Version: ${VERSION}"

    journalctl \
        -f \
        -n 0 \
        -o cat |
    while IFS= read -r line; do

        handle_event "$line"

    done
}


# ============================================================
# Host start
#
# Called by systemd after the monitor service starts.
# The service unit should invoke this only after boot.
# ============================================================

host_start() {

    load_config

    send_host_state "start"
}


# ============================================================
# Host stop
#
# Called by systemd while the host is shutting down.
# The service unit will invoke this during shutdown.
# ============================================================

host_stop() {

    load_config

    send_host_state "stop"
}


# ============================================================
# Host reboot
#
# Reserved for explicit reboot notification if needed later.
# Normal host reboot will be represented as:
#
#   🔴 Proxmox 호스트 종료
#   🟢 Proxmox 호스트 시작
#
# ============================================================

host_reboot() {

    load_config

    send_host_state "reboot"
}


# ============================================================
# Test
# ============================================================

send_test() {

    load_config

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    local message

    message="🟢 Proxmox VM/LXC 이벤트 모니터 테스트"
    message+=$'\n'
    message+=$'\n'
    message+="시간: ${now}"
    message+=$'\n'
    message+=$'\n'
    message+="이벤트 감시가 정상적으로 실행되고 있습니다."

    if telegram_send "$message"; then

        log "Test message sent successfully."

    else

        log "ERROR: Failed to send Telegram test message."
        return 1

    fi
}


# ============================================================
# Version / Help
# ============================================================

case "${1:-}" in

    --monitor)

        monitor
        ;;

    --host-start)

        host_start
        ;;

    --host-stop)

        host_stop
        ;;

    --host-reboot)

        host_reboot
        ;;

    --test)

        send_test
        ;;

    --version)

        echo "$VERSION"
        ;;

    --help|-h)

        cat <<EOF

Proxmox VM/LXC Telegram Event Monitor ${VERSION}

Usage:

  $0 --monitor
      Monitor Proxmox VM/LXC start/stop events.

  $0 --host-start
      Send Proxmox host start notification.

  $0 --host-stop
      Send Proxmox host stop notification.

  $0 --host-reboot
      Send Proxmox host reboot notification.

  $0 --test
      Send a Telegram test message.

  $0 --version
      Show version.

  $0 --help
      Show this help.

Configuration:

  ${CONFIG_FILE}

EOF
        ;;

    *)

        echo "Usage: $0 {--monitor|--host-start|--host-stop|--host-reboot|--test|--version|--help}"
        exit 1
        ;;

esac