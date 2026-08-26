cat > /usr/local/bin/pve-telegram-event.sh <<'EOF'
#!/usr/bin/env bash
#
# pve-telegram-event.sh
#
# Proxmox VM/LXC state monitor
# Version: 1.0.0
#

set -u
set -o pipefail

VERSION="1.0.0"

CONFIG_FILE="/etc/pve-telegram-monitor/config"
STATE_DIR="/var/lib/pve-telegram-monitor"
STATE_FILE="${STATE_DIR}/vm-lxc-state"

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

CHECK_INTERVAL=10


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

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
}


# ============================================================
# Current VM/LXC state
# ============================================================

get_current_state() {

    {
        qm list 2>/dev/null |
            awk '
                NR > 1 && $1 ~ /^[0-9]+$/ {
                    print "VM|" $1 "|" $2
                }
            '

        pct list 2>/dev/null |
            awk '
                NR > 1 && $1 ~ /^[0-9]+$/ {
                    print "LXC|" $1 "|" $2
                }
            '
    } |
    sort -t'|' -k1,1 -k2,2n
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
    local old_state="$3"
    local new_state="$4"

    local name
    name=$(get_name "$type" "$id")

    local emoji
    local action

    if [[ "$new_state" == "running" ]]; then
        emoji="🟢"
        action="시작"
    elif [[ "$new_state" == "stopped" ]]; then
        emoji="🔴"
        action="종료"
    else
        emoji="🟠"
        action="$new_state"
    fi

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    local message=""

    message+="${emoji} ${type} ${action}"
    message+=$'\n'
    message+=$'\n'
    message+="${type} ${id} · ${name}"
    message+=$'\n'
    message+="${now}"

    telegram_send "$message"

    log "${type} ${id} (${name}): ${old_state} -> ${new_state}"
}


# ============================================================
# Compare states
# ============================================================

check_states() {

    local current_file
    current_file=$(mktemp)

    trap 'rm -f "$current_file"' RETURN

    get_current_state > "$current_file"

    # --------------------------------------------------------
    # First run
    # --------------------------------------------------------

    if [[ ! -f "$STATE_FILE" ]]; then

        cp "$current_file" "$STATE_FILE"
        chmod 600 "$STATE_FILE"

        log "Initial VM/LXC state saved."

        return 0
    fi


    # --------------------------------------------------------
    # Compare existing resources
    # --------------------------------------------------------

    while IFS='|' read -r type id new_state; do

        [[ -z "$type" ]] && continue
        [[ -z "$id" ]] && continue

        local old_state

        old_state=$(awk -F'|' \
            -v t="$type" \
            -v i="$id" \
            '$1 == t && $2 == i {print $3; exit}' \
            "$STATE_FILE")

        # New resource
        if [[ -z "$old_state" ]]; then
            continue
        fi

        # State changed
        if [[ "$old_state" != "$new_state" ]]; then

            send_state_change \
                "$type" \
                "$id" \
                "$old_state" \
                "$new_state"

        fi

    done < "$current_file"


    # --------------------------------------------------------
    # Save current state
    # --------------------------------------------------------

    cp "$current_file" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}


# ============================================================
# Test
# ============================================================

send_test() {

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    local message=""

    message+="🟢 Proxmox VM/LXC 이벤트 모니터 테스트"
    message+=$'\n'
    message+=$'\n'
    message+="시간: ${now}"
    message+=$'\n'
    message+=$'\n'
    message+="VM/LXC 상태 감시가 정상적으로 실행되고 있습니다."

    telegram_send "$message"

    log "Event monitor test message sent successfully."
}


# ============================================================
# Main monitor loop
# ============================================================

monitor() {

    load_config
    prepare_state_dir

    log "Proxmox VM/LXC event monitor started."
    log "Check interval: ${CHECK_INTERVAL} seconds"

    while true; do

        check_states

        sleep "$CHECK_INTERVAL"

    done
}


# ============================================================
# Help
# ============================================================

usage() {

    cat <<EOF

Proxmox VM/LXC Event Monitor ${VERSION}

Usage:

  ${0} --monitor
      Monitor VM/LXC state changes continuously.

  ${0} --test
      Send a Telegram connection test message.

  ${0} --version
      Show script version.

  ${0} --help
      Show this help.

Configuration:

  ${CONFIG_FILE}

State:

  ${STATE_FILE}

EOF
}


# ============================================================
# Main
# ============================================================

main() {

    case "${1:-}" in

        --monitor)

            monitor

            ;;

        --test)

            load_config
            send_test

            ;;

        --version)

            echo "${VERSION}"

            ;;

        --help|-h)

            usage

            ;;

        *)

            usage
            exit 1

            ;;

    esac
}


main "$@"
EOF

chmod +x /usr/local/bin/pve-telegram-event.sh