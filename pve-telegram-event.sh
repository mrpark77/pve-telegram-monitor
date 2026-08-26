#!/usr/bin/env bash
#
# pve-telegram-event.sh
#
# Proxmox VM/LXC state monitor
# Version: 2.3.0
#

set -u
set -o pipefail

VERSION="2.3.0"

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
# Send state change notification
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
# Parse Proxmox task start event
#
# IMPORTANT:
#
# Proxmox writes several journal lines for one task.
#
# Example:
#
#   starting task UPID:...:qmreboot:102:...
#   requesting reboot of VM 102: UPID:...:qmreboot:102:...
#   end task UPID:...:qmreboot:102:...
#
# We process ONLY the "starting task" line.
#
# This prevents duplicate Telegram notifications.
# ============================================================

handle_event() {

    local line="$1"

    # --------------------------------------------------------
    # Only process actual task-start lines.
    #
    # This is the important change in 2.3.0.
    # --------------------------------------------------------

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

    elif [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:qmreboot:([0-9]+): ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="reboot"


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

    elif [[ "$line" =~ starting\ task\ UPID:[^:]+:[^:]+:[^:]+:[^:]+:vzreboot:([0-9]+): ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="reboot"

    else

        return 0

    fi


    # --------------------------------------------------------
    # Send notification
    # --------------------------------------------------------

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

        log "ERROR: Failed to send test message."
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
      Monitor Proxmox VM/LXC start/stop/reboot events.

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

        echo "Usage: $0 {--monitor|--test|--version|--help}"
        exit 1
        ;;

esac