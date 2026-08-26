#!/usr/bin/env bash
#
# pve-telegram-event.sh
#
# Proxmox VM/LXC event -> Telegram notification
# Version: 2.1.0
#

set -u
set -o pipefail

VERSION="2.1.0"

CONFIG_FILE="/etc/pve-telegram-monitor/config"

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""


# ============================================================
# Configuration
# ============================================================

load_config() {

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        echo "ERROR: TELEGRAM_BOT_TOKEN is not configured." >&2
        exit 1
    fi

    if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        echo "ERROR: TELEGRAM_CHAT_ID is not configured." >&2
        exit 1
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
# Logging
# ============================================================

log() {

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
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
# Send state change
# ============================================================

send_state_change() {

    local type="$1"
    local id="$2"
    local action="$3"

    local name
    name=$(get_name "$type" "$id")

    local emoji

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
# Parse Proxmox pvedaemon event
# ============================================================

handle_event() {

    local line="$1"

    local type=""
    local id=""
    local action=""

    # --------------------------------------------------------
    # QEMU VM
    # --------------------------------------------------------

    if [[ "$line" =~ qmstart:([0-9]+) ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="start"

    elif [[ "$line" =~ qmshutdown:([0-9]+) ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="stop"

    elif [[ "$line" =~ qmstop:([0-9]+) ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="stop"

    elif [[ "$line" =~ qmreboot:([0-9]+) ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="reboot"


    # --------------------------------------------------------
    # LXC
    # --------------------------------------------------------

    elif [[ "$line" =~ vzstart:([0-9]+) ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="start"

    elif [[ "$line" =~ vzstop:([0-9]+) ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="stop"

    elif [[ "$line" =~ vzshutdown:([0-9]+) ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="stop"

    elif [[ "$line" =~ vzreboot:([0-9]+) ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="reboot"

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

    journalctl \
        -f \
        -n 0 \
        -o cat |
    while IFS= read -r line; do

        # Only process Proxmox VM/LXC lifecycle events.
        if [[ "$line" =~ qm(start|shutdown|stop|reboot):[0-9]+ ]] ||
           [[ "$line" =~ vz(start|shutdown|stop|reboot):[0-9]+ ]]; then

            handle_event "$line"

        fi

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
# Version
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

EOF
        ;;

    *)
        echo "Usage: $0 {--monitor|--test|--version|--help}"
        exit 1
        ;;

esac