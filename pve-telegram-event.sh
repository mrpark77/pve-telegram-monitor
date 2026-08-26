#!/usr/bin/env bash
#
# pve-telegram-event.sh
#
# Proxmox VM/LXC + Host Telegram Event Monitor
# Version: 2.5.0
#

set -u
set -o pipefail

VERSION="2.5.0"

CONFIG_FILE="/etc/pve-telegram-monitor/config"
SCRIPT_PATH="/usr/local/bin/pve-telegram-event.sh"

EVENT_SERVICE="pve-telegram-event.service"
HOST_START_SERVICE="pve-telegram-host-start.service"
HOST_STOP_SERVICE="pve-telegram-host-stop.service"

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
# Send Host state notification
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

    local hostname
    hostname=$(hostname)

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    local message

    message="${emoji} Proxmox 호스트 ${action_text}"
    message+=$'\n'
    message+=$'\n'
    message+="Host · ${hostname}"
    message+=$'\n'
    message+="${now}"

    if telegram_send "$message"; then

        log "Host (${action_text}): notification sent"

    else

        log "ERROR: Failed to send host notification"

    fi
}


# ============================================================
# Parse Proxmox task start event
# ============================================================

handle_event() {

    local line="$1"

    # --------------------------------------------------------
    # Only process actual task-start lines.
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
# Host notifications
# ============================================================

host_start() {

    load_config

    send_host_state "start"
}


host_stop() {

    load_config

    send_host_state "stop"
}


host_reboot() {

    load_config

    send_host_state "reboot"
}


# ============================================================
# Install systemd services
# ============================================================

install_services() {

    [[ $EUID -eq 0 ]] || die "Installation requires root privileges."

    log "Installing Proxmox Telegram Event Monitor ${VERSION}..."

    mkdir -p /etc/systemd/system/pve-telegram-event.service.d
    mkdir -p /etc/systemd/system/systemd-reboot.service.d
    mkdir -p /etc/systemd/system/systemd-halt.service.d
    mkdir -p /etc/systemd/system/systemd-poweroff.service.d


    # --------------------------------------------------------
    # Main event monitor
    # --------------------------------------------------------

    cat > /etc/systemd/system/${EVENT_SERVICE} <<EOF
[Unit]
Description=Proxmox VM/LXC Event Telegram Monitor
After=pvedaemon.service
Wants=pvedaemon.service
Before=pve-guests.service

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} --monitor
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


    # --------------------------------------------------------
    # Host start
    # --------------------------------------------------------

    cat > /etc/systemd/system/${HOST_START_SERVICE} <<EOF
[Unit]
Description=Proxmox Host Start Telegram Notification
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --host-start

[Install]
WantedBy=multi-user.target
EOF


    # --------------------------------------------------------
    # Host stop
    # --------------------------------------------------------

    cat > /etc/systemd/system/${HOST_STOP_SERVICE} <<EOF
[Unit]
Description=Proxmox Host Stop Telegram Notification
DefaultDependencies=no
Before=systemd-reboot.service systemd-halt.service systemd-poweroff.service
After=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --host-stop
TimeoutStartSec=30
EOF


    # --------------------------------------------------------
    # Make host-stop run before final reboot/poweroff
    # --------------------------------------------------------

    cat > /etc/systemd/system/systemd-reboot.service.d/pve-telegram.conf <<EOF
[Unit]
Requires=${HOST_STOP_SERVICE}
After=${HOST_STOP_SERVICE}
EOF


    cat > /etc/systemd/system/systemd-halt.service.d/pve-telegram.conf <<EOF
[Unit]
Requires=${HOST_STOP_SERVICE}
After=${HOST_STOP_SERVICE}
EOF


    cat > /etc/systemd/system/systemd-poweroff.service.d/pve-telegram.conf <<EOF
[Unit]
Requires=${HOST_STOP_SERVICE}
After=${HOST_STOP_SERVICE}
EOF


    # --------------------------------------------------------
    # Reload systemd
    # --------------------------------------------------------

    systemctl daemon-reload


    # --------------------------------------------------------
    # Enable services
    # --------------------------------------------------------

    systemctl enable "${EVENT_SERVICE}"
    systemctl enable "${HOST_START_SERVICE}"


    # --------------------------------------------------------
    # Restart main monitor
    # --------------------------------------------------------

    systemctl restart "${EVENT_SERVICE}"


    # --------------------------------------------------------
    # Start notification service
    # --------------------------------------------------------

    log "Installation completed."
    log "Version: ${VERSION}"

    echo
    echo "Installed services:"
    echo "  ${EVENT_SERVICE}"
    echo "  ${HOST_START_SERVICE}"
    echo "  ${HOST_STOP_SERVICE}"
    echo
    echo "Systemd dependencies configured."
}


# ============================================================
# Uninstall systemd services
# ============================================================

uninstall_services() {

    [[ $EUID -eq 0 ]] || die "Uninstallation requires root privileges."

    log "Removing Proxmox Telegram Event Monitor..."

    systemctl disable --now "${EVENT_SERVICE}" 2>/dev/null || true
    systemctl disable --now "${HOST_START_SERVICE}" 2>/dev/null || true
    systemctl stop "${HOST_STOP_SERVICE}" 2>/dev/null || true


    rm -f \
        "/etc/systemd/system/${EVENT_SERVICE}" \
        "/etc/systemd/system/${HOST_START_SERVICE}" \
        "/etc/systemd/system/${HOST_STOP_SERVICE}"


    rm -f \
        /etc/systemd/system/systemd-reboot.service.d/pve-telegram.conf \
        /etc/systemd/system/systemd-halt.service.d/pve-telegram.conf \
        /etc/systemd/system/systemd-poweroff.service.d/pve-telegram.conf


    rm -rf \
        /etc/systemd/system/${EVENT_SERVICE}.d


    rmdir /etc/systemd/system/systemd-reboot.service.d 2>/dev/null || true
    rmdir /etc/systemd/system/systemd-halt.service.d 2>/dev/null || true
    rmdir /etc/systemd/system/systemd-poweroff.service.d 2>/dev/null || true


    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    log "Uninstallation completed."
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

    --host-start)

        host_start
        ;;

    --host-stop)

        host_stop
        ;;

    --host-reboot)

        host_reboot
        ;;

    --install)

        install_services
        ;;

    --uninstall)

        uninstall_services
        ;;

    --test)

        send_test
        ;;

    --version)

        echo "$VERSION"
        ;;

    --help|-h)

        cat <<EOF

Proxmox VM/LXC + Host Telegram Event Monitor ${VERSION}

Usage:

  $0 --monitor
      Monitor Proxmox VM/LXC start/stop/reboot events.

  $0 --host-start
      Send Proxmox host start notification.

  $0 --host-stop
      Send Proxmox host stop notification.

  $0 --host-reboot
      Send Proxmox host reboot notification.

  $0 --install
      Install and configure all systemd services.

  $0 --uninstall
      Remove all installed systemd services and dependencies.

  $0 --test
      Send a Telegram test message.

  $0 --version
      Show version.

  $0 --help
      Show this help.

Configuration:

  ${CONFIG_FILE}

Services:

  ${EVENT_SERVICE}
  ${HOST_START_SERVICE}
  ${HOST_STOP_SERVICE}

EOF
        ;;

    *)

        echo "Usage:"
        echo
        echo "  $0 --monitor"
        echo "  $0 --host-start"
        echo "  $0 --host-stop"
        echo "  $0 --host-reboot"
        echo "  $0 --install"
        echo "  $0 --uninstall"
        echo "  $0 --test"
        echo "  $0 --version"
        echo "  $0 --help"
        exit 1
        ;;

esac