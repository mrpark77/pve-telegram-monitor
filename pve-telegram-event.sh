#!/usr/bin/env bash
#
# pve-telegram-event.sh
#
# Proxmox VM/LXC state monitor
# Version: 2.2.0
#

set -u
set -o pipefail

VERSION="2.2.0"

CONFIG_FILE="/etc/pve-telegram-monitor/config"

# Prevent duplicate start notification after reboot.
REBOOT_STATE_DIR="/var/lib/pve-telegram-monitor"
REBOOT_STATE_FILE="${REBOOT_STATE_DIR}/reboot-state"

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
# State directory
# ============================================================

prepare_state_dir() {

    mkdir -p "$REBOOT_STATE_DIR"
    chmod 700 "$REBOOT_STATE_DIR"

    touch "$REBOOT_STATE_FILE"
    chmod 600 "$REBOOT_STATE_FILE"
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
# Reboot state
# ============================================================

mark_reboot() {

    local type="$1"
    local id="$2"

    local key="${type}|${id}"

    grep -Fqx "$key" "$REBOOT_STATE_FILE" 2>/dev/null || {
        echo "$key" >> "$REBOOT_STATE_FILE"
    }
}


is_rebooting() {

    local type="$1"
    local id="$2"

    local key="${type}|${id}"

    grep -Fqx "$key" "$REBOOT_STATE_FILE" 2>/dev/null
}


clear_reboot() {

    local type="$1"
    local id="$2"

    local key="${type}|${id}"

    if [[ ! -f "$REBOOT_STATE_FILE" ]]; then
        return 0
    fi

    grep -Fvx "$key" "$REBOOT_STATE_FILE" > "${REBOOT_STATE_FILE}.tmp" || true

    mv "${REBOOT_STATE_FILE}.tmp" "$REBOOT_STATE_FILE"
    chmod 600 "$REBOOT_STATE_FILE"
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
# Handle VM/LXC event
# ============================================================

handle_event() {

    local line="$1"

    local type=""
    local id=""
    local action=""

    # --------------------------------------------------------
    # QEMU VM
    # --------------------------------------------------------

    if [[ "$line" =~ qmreboot:([0-9]+) ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="reboot"

        # Mark this VM so the following qmstart is ignored.
        mark_reboot "$type" "$id"

        send_state_change "$type" "$id" "$action"

        return 0


    elif [[ "$line" =~ qmstart:([0-9]+) ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="start"

        # qmstart immediately following qmreboot is not a new event.
        if is_rebooting "$type" "$id"; then

            clear_reboot "$type" "$id"

            log "VM ${id}: qmstart ignored because it follows qmreboot"

            return 0

        fi

        send_state_change "$type" "$id" "$action"

        return 0


    elif [[ "$line" =~ qmshutdown:([0-9]+) ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="stop"

        send_state_change "$type" "$id" "$action"

        return 0


    elif [[ "$line" =~ qmstop:([0-9]+) ]]; then

        type="VM"
        id="${BASH_REMATCH[1]}"
        action="stop"

        send_state_change "$type" "$id" "$action"

        return 0


    # --------------------------------------------------------
    # LXC
    # --------------------------------------------------------

    elif [[ "$line" =~ vzreboot:([0-9]+) ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="reboot"

        mark_reboot "$type" "$id"

        send_state_change "$type" "$id" "$action"

        return 0


    elif [[ "$line" =~ vzstart:([0-9]+) ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="start"

        if is_rebooting "$type" "$id"; then

            clear_reboot "$type" "$id"

            log "LXC ${id}: vzstart ignored because it follows vzreboot"

            return 0

        fi

        send_state_change "$type" "$id" "$action"

        return 0


    elif [[ "$line" =~ vzshutdown:([0-9]+) ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="stop"

        send_state_change "$type" "$id" "$action"

        return 0


    elif [[ "$line" =~ vzstop:([0-9]+) ]]; then

        type="LXC"
        id="${BASH_REMATCH[1]}"
        action="stop"

        send_state_change "$type" "$id" "$action"

        return 0

    fi


    return 0
}


# ============================================================
# Monitor
# ============================================================

monitor() {

    load_config
    prepare_state_dir

    log "Proxmox VM/LXC event monitor started."
    log "Mode: system journal event monitoring"
    log "Version: ${VERSION}"

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
    message+="버전: ${VERSION}"
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
# Main
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