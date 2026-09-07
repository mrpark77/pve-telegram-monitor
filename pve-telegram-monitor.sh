#!/usr/bin/env bash
#
# pve-telegram-monitor.sh
#
# Proxmox VE Telegram Monitor
# Version: 1.6.0
#

set -u
set -o pipefail

VERSION="1.6.0"

CONFIG_DIR="/etc/pve-telegram-monitor"
CONFIG_FILE="${CONFIG_DIR}/config"

REPORT_SERVICE="/etc/systemd/system/pve-telegram-report.service"
REPORT_TIMER="/etc/systemd/system/pve-telegram-report.timer"

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

TELEGRAM_MAX_LENGTH=4000


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
# Installation
# ============================================================

install_monitor() {

    echo
    echo "=============================================="
    echo " Proxmox Telegram Monitor ${VERSION} 설치"
    echo "=============================================="
    echo

    if [[ "$EUID" -ne 0 ]]; then
        die "root 권한으로 실행해야 합니다."
    fi

    echo "Telegram Bot Token을 입력하세요."
    read -r -p "Bot Token: " TELEGRAM_BOT_TOKEN

    if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
        die "Bot Token이 입력되지 않았습니다."
    fi

    echo
    echo "Telegram Chat ID를 입력하세요."
    read -r -p "Chat ID: " TELEGRAM_CHAT_ID

    if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        die "Chat ID가 입력되지 않았습니다."
    fi

    echo
    echo "매일 실행할 리포트 시간을 입력하세요."
    echo "예: 09:00"
    read -r -p "실행 시간 [09:00]: " REPORT_TIME

    [[ -z "$REPORT_TIME" ]] && REPORT_TIME="09:00"

    if [[ ! "$REPORT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        die "실행 시간 형식이 올바르지 않습니다. 예: 09:00"
    fi

    echo
    echo "설정을 저장합니다..."

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
EOF

    chmod 600 "$CONFIG_FILE"

    cat > "$REPORT_SERVICE" <<EOF
[Unit]
Description=Proxmox Telegram Daily Report
After=network-online.target pve-guests.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pve-telegram-monitor.sh --report
EOF

    cat > "$REPORT_TIMER" <<EOF
[Unit]
Description=Run Proxmox Telegram Daily Report at ${REPORT_TIME}

[Timer]
OnCalendar=*-*-* ${REPORT_TIME}:00
Persistent=true
Unit=pve-telegram-report.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now pve-telegram-report.timer

    echo
    echo "=============================================="
    echo " 설치가 완료되었습니다."
    echo "=============================================="
    echo
    echo "Version       : ${VERSION}"
    echo "Report time   : ${REPORT_TIME}"
    echo "Config file   : ${CONFIG_FILE}"
    echo "Timer         : pve-telegram-report.timer"
    echo
    echo "Telegram 연결 테스트:"
    echo
    echo "  ${0} --test"
    echo
}


# ============================================================
# Uninstallation
# ============================================================

uninstall_monitor() {

    if [[ "$EUID" -ne 0 ]]; then
        die "root 권한으로 실행해야 합니다."
    fi

    echo
    echo "Proxmox Telegram Monitor를 제거합니다."
    echo

    systemctl disable --now pve-telegram-report.timer 2>/dev/null || true
    systemctl stop pve-telegram-report.service 2>/dev/null || true

    rm -f "$REPORT_TIMER"
    rm -f "$REPORT_SERVICE"

    rm -rf "$CONFIG_DIR"

    systemctl daemon-reload
    systemctl reset-failed

    echo
    echo "제거가 완료되었습니다."
    echo
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


telegram_send_long() {

    local message="$1"
    local length=${#message}

    if (( length <= TELEGRAM_MAX_LENGTH )); then
        telegram_send "$message"
        return
    fi

    local start=0
    local chunk

    while (( start < length )); do

        chunk="${message:start:TELEGRAM_MAX_LENGTH}"

        telegram_send "$chunk"

        start=$((start + TELEGRAM_MAX_LENGTH))

        sleep 1
    done
}


# ============================================================
# Version information
# ============================================================

get_pve_version() {

    pveversion 2>/dev/null |
        sed -n 's/^pve-manager\/\([^\/ ]*\).*/\1/p' |
        head -n 1
}


get_kernel_version() {

    uname -r
}


# ============================================================
# Host uptime
# ============================================================

get_uptime() {

    uptime -p 2>/dev/null |
        sed 's/^up //'
}


# ============================================================
# VM information
# ============================================================

get_vm_ip() {

    local vmid="$1"

    local result

    result=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null || true)

    if [[ -z "$result" ]]; then
        echo "-"
        return
    fi

    echo "$result" |
        jq -r '
            .[]
            | .["ip-addresses"][]?
            | select(.["ip-address-type"] == "ipv4")
            | .["ip-address"]
        ' 2>/dev/null |
        grep -v '^127\.' |
        head -n 1
}


get_vm_mac() {

    local config="$1"

    echo "$config" |
        awk '
            /^net[0-9]+:/ {

                line=$0

                if (match(line, /[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}/)) {
                    print substr(line, RSTART, RLENGTH)
                    exit
                }
            }
        '
}


get_vm_info() {

    local vmid="$1"

    local config
    config=$(qm config "$vmid" 2>/dev/null || true)

    local name
    local cores
    local memory
    local mac
    local ip

    name=$(echo "$config" |
        awk -F': ' '/^name:/ {print $2; exit}')

    cores=$(echo "$config" |
        awk -F': ' '/^cores:/ {print $2; exit}')

    memory=$(echo "$config" |
        awk -F': ' '/^memory:/ {print $2; exit}')

    mac=$(get_vm_mac "$config")

    ip=$(get_vm_ip "$vmid")

    [[ -z "$name" ]] && name="Unknown"
    [[ -z "$cores" ]] && cores="-"
    [[ -z "$memory" ]] && memory="-"
    [[ -z "$mac" ]] && mac="-"
    [[ -z "$ip" ]] && ip="-"

    local ram_display

    if [[ "$memory" =~ ^[0-9]+$ ]]; then
        ram_display="$(awk -v m="$memory" 'BEGIN {
            if (m >= 1024)
                printf "%.0f GB", m/1024;
            else
                printf "%d MB", m;
        }')"
    else
        ram_display="$memory"
    fi

    local disks=""

    while IFS= read -r line; do

        [[ -z "$line" ]] && continue

        local disk_name
        local disk_value

        disk_name=$(echo "$line" | cut -d: -f1)
        disk_value=$(echo "$line" | cut -d: -f2-)

        if [[ "$disk_name" =~ ^(scsi|sata|virtio|ide)[0-9]+$ ]]; then

            local storage
            local size

            storage=$(echo "$disk_value" |
                sed -n 's/^\([^:]*\):.*/\1/p')

            size=$(echo "$disk_value" |
                sed -n 's/.*size=\([^,]*\).*/\1/p')

            if [[ -n "$storage" && -n "$size" ]]; then

                if [[ -n "$disks" ]]; then
                    disks+=$'\n'
                fi

                disks+="Disk: ${storage} · ${size}"
            fi
        fi

    done <<< "$config"

    [[ -z "$disks" ]] && disks="Disk: -"

    echo "🟢 VM ${vmid} · ${name}"
    echo "CPU ${cores} Core · RAM ${ram_display}"
    echo "IP ${ip}"
    echo "MAC ${mac}"
    echo "$disks"
}


# ============================================================
# LXC information
# ============================================================

get_lxc_info() {

    local ctid="$1"

    local config
    config=$(pct config "$ctid" 2>/dev/null || true)

    local hostname
    local cores
    local memory
    local mac
    local ip

    hostname=$(echo "$config" |
        awk -F': ' '/^hostname:/ {print $2; exit}')

    cores=$(echo "$config" |
        awk -F': ' '/^cores:/ {print $2; exit}')

    memory=$(echo "$config" |
        awk -F': ' '/^memory:/ {print $2; exit}')

    mac=$(echo "$config" |
        awk '
            /^net[0-9]+:/ {
                match($0, /hwaddr=[^,]+/)
                if (RSTART) {
                    value=substr($0, RSTART, RLENGTH)
                    sub(/^hwaddr=/, "", value)
                    print value
                    exit
                }
            }
        ')

    ip=$(echo "$config" |
        awk '
            /^net[0-9]+:/ {
                match($0, /ip=[^,]+/)
                if (RSTART) {
                    value=substr($0, RSTART, RLENGTH)
                    sub(/^ip=/, "", value)
                    sub(/\/.*/, "", value)
                    if (value != "dhcp") {
                        print value
                        exit
                    }
                }
            }
        ')

    [[ -z "$hostname" ]] && hostname="Unknown"
    [[ -z "$cores" ]] && cores="-"
    [[ -z "$memory" ]] && memory="-"
    [[ -z "$mac" ]] && mac="-"
    [[ -z "$ip" ]] && ip="-"

    echo "🟢 LXC ${ctid} · ${hostname}"
    echo "CPU ${cores} Core · RAM ${memory} MB"
    echo "IP ${ip}"
    echo "MAC ${mac}"

    local rootfs

    rootfs=$(echo "$config" |
        awk -F': ' '/^rootfs:/ {print $2; exit}')

    if [[ -n "$rootfs" ]]; then

        local storage
        local size

        storage=$(echo "$rootfs" |
            sed -n 's/^\([^:]*\):.*/\1/p')

        size=$(echo "$rootfs" |
            sed -n 's/.*size=\([^,]*\).*/\1/p')

        if [[ -n "$storage" && -n "$size" ]]; then
            echo "Disk: ${storage} · ${size}"
        fi
    fi
}


# ============================================================
# SMART
# ============================================================

smart_status() {

    local device="$1"
    local type="$2"

    local output

    output=$(smartctl -a -d "$type" "$device" 2>/dev/null || true)

    local severity=0
    local problem=""

    if [[ -z "$output" ]]; then
        echo "🔴|SMART 정보를 읽을 수 없습니다."
        return
    fi

    local reallocated=0
    local pending=0
    local offline_uncorrectable=0
    local reported_uncorrect=0
    local crc=0
    local media_errors=0
    local critical_warning=""

    reallocated=$(echo "$output" |
        awk '$1 == 5 {print $10; exit}')

    pending=$(echo "$output" |
        awk '$1 == 197 {print $10; exit}')

    offline_uncorrectable=$(echo "$output" |
        awk '$1 == 198 {print $10; exit}')

    reported_uncorrect=$(echo "$output" |
        awk '$1 == 187 {print $10; exit}')

    crc=$(echo "$output" |
        awk '$1 == 199 {print $10; exit}')

    critical_warning=$(echo "$output" |
        awk -F: '/Critical Warning:/ {
            gsub(/^[ \t]+/, "", $2)
            print $2
            exit
        }')

    media_errors=$(echo "$output" |
        awk -F: '/Media and Data Integrity Errors:/ {
            gsub(/^[ \t]+/, "", $2)
            print $2
            exit
        }')

    # 🔴 위험

    if [[ "$critical_warning" =~ ^0x ]] &&
       [[ "$critical_warning" != "0x00" ]]; then

        problem+="Critical Warning: ${critical_warning}"$'\n'
        severity=2
    fi

    if [[ "$media_errors" =~ ^[0-9]+$ ]] &&
       (( media_errors > 0 )); then

        problem+="Media/Data Integrity Errors: ${media_errors}"$'\n'
        severity=2
    fi

    if [[ "$pending" =~ ^[0-9]+$ ]] &&
       (( pending > 0 )); then

        problem+="Current Pending Sector: ${pending}"$'\n'
        severity=2
    fi

    if [[ "$offline_uncorrectable" =~ ^[0-9]+$ ]] &&
       (( offline_uncorrectable > 0 )); then

        problem+="Offline Uncorrectable: ${offline_uncorrectable}"$'\n'
        severity=2
    fi

    if [[ "$reported_uncorrect" =~ ^[0-9]+$ ]] &&
       (( reported_uncorrect > 0 )); then

        problem+="Reported Uncorrectable: ${reported_uncorrect}"$'\n'
        severity=2
    fi

    # 🟠 주의

    if [[ "$reallocated" =~ ^[0-9]+$ ]] &&
       (( reallocated > 0 )); then

        problem+="Reallocated Sector Count: ${reallocated}"$'\n'

        if (( severity < 1 )); then
            severity=1
        fi
    fi

    if [[ "$crc" =~ ^[0-9]+$ ]] &&
       (( crc > 0 )); then

        problem+="UDMA CRC Error Count: ${crc}"$'\n'

        if (( severity < 1 )); then
            severity=1
        fi
    fi

    # 결과 반환
    case "$severity" in

        2)
            printf '🔴|%s' "$problem"
            ;;

        1)
            printf '🟠|%s' "$problem"
            ;;

        *)
            printf '🟢|없음'
            ;;

    esac
}

# ============================================================
# SMART report
# ============================================================

generate_smart_report() {

    echo
    echo "=================================================="
    echo " SMART 상태 및 판정 기준"
    echo "=================================================="
    echo

    echo "📌 판정 기준"
    echo

    echo "🟢 정상"
    echo "  위험/주의 조건이 확인되지 않음"
    echo

    echo "🟠 주의"
    echo "  Reallocated Sector Count > 0"
    echo "  UDMA CRC Error Count > 0"
    echo

    echo "🔴 위험"
    echo "  SMART 정보를 읽을 수 없음"
    echo "  Current Pending Sector > 0"
    echo "  Offline Uncorrectable > 0"
    echo "  Reported Uncorrectable > 0"
    echo "  NVMe Critical Warning != 0x00"
    echo "  NVMe Media and Data Integrity Errors > 0"
    echo

    echo "=================================================="
    echo " 💾 현재 저장장치"
    echo "=================================================="
    echo

    local disks

    disks=$(smartctl --scan-open 2>/dev/null || true)

    if [[ -z "$disks" ]]; then
        echo "감지된 SMART 저장장치가 없습니다."
        echo
        return
    fi

    while IFS= read -r line; do

        [[ -z "$line" ]] && continue

        local device
        local type

        device=$(echo "$line" | awk '{print $1}')

        type=$(echo "$line" |
            sed -n 's/.*-d \([^ ]*\).*/\1/p')

        [[ -z "$type" ]] && type="sat"

        local status
        local model
        local size
        local rotation
        local smart_result
        local status
        local problem
        local model
        local size
        local rotation

        smart_result=$(smart_status "$device" "$type")

        status="${smart_result%%|*}"
        problem="${smart_result#*|}"

        model=$(get_disk_model "$device" "$type")
        size=$(get_disk_size "$device" "$type")
        rotation=$(get_disk_rotation "$device" "$type")

        echo "${status} ${device}"

        [[ -n "$model" ]] && \
            echo "모델: ${model}"

        [[ -n "$size" ]] && \
            echo "용량: ${size}"

        [[ -n "$rotation" ]] && \
            echo "회전속도: ${rotation}"

        echo "문제:"

        if [[ "$problem" == "없음" ]]; then
            echo "  없음"
        else
            while IFS= read -r problem_line; do
                [[ -z "$problem_line" ]] && continue
                echo "  ${problem_line}"
            done <<< "$problem"
        fi

        echo

    done <<< "$disks"

    echo "=================================================="
    echo
}


get_disk_model() {

    local device="$1"
    local type="$2"

    smartctl -a -d "$type" "$device" 2>/dev/null |
        awk -F: '
            /Device Model:/ {
                gsub(/^[ \t]+/, "", $2)
                print $2
                exit
            }
            /Model Number:/ {
                gsub(/^[ \t]+/, "", $2)
                print $2
                exit
            }
        '
}


get_disk_size() {

    local device="$1"
    local type="$2"

    smartctl -a -d "$type" "$device" 2>/dev/null |
        awk -F: '
            /User Capacity:/ {
                value=$2
                sub(/^[ \t]+/, "", value)
                match(value, /\[[^]]+\]/)
                if (RSTART) {
                    size=substr(value, RSTART+1, RLENGTH-2)
                    print size
                    exit
                }
            }
            /Namespace 1 Size\/Capacity:/ {
                value=$2
                sub(/^[ \t]+/, "", value)
                match(value, /\[[^]]+\]/)
                if (RSTART) {
                    size=substr(value, RSTART+1, RLENGTH-2)
                    print size
                    exit
                }
            }
        '
}


get_disk_rotation() {

    local device="$1"
    local type="$2"

    smartctl -a -d "$type" "$device" 2>/dev/null |
        awk -F: '/Rotation Rate:/ {
            gsub(/^[ \t]+/, "", $2)
            print $2
            exit
        }'
}


get_disk_info() {

    local device="$1"
    local type="$2"

    local status
    local model
    local size
    local rotation

    status_result=$(smart_status "$device" "$type")
    status="${status_result%%|*}"
    model=$(get_disk_model "$device" "$type")
    size=$(get_disk_size "$device" "$type")
    rotation=$(get_disk_rotation "$device" "$type")

    [[ -z "$model" ]] && model="Unknown"
    [[ -z "$size" ]] && size="Unknown"

    if [[ -n "$rotation" ]]; then
        echo "${status} ${model}"
        echo "${size} · ${rotation}"
    else
        echo "${status} ${model}"
        echo "${size} · NVMe"
    fi
}


# ============================================================
# Proxmox storage
# ============================================================

format_kib() {

    local kib="$1"

    if [[ ! "$kib" =~ ^[0-9]+$ ]]; then
        echo "-"
        return
    fi

    awk -v k="$kib" 'BEGIN {

        gb = k / 1024 / 1024

        if (gb >= 1000)
            printf "%.1f TB", gb / 1024
        else if (gb >= 1)
            printf "%.2f GB", gb
        else
            printf "%.0f MB", k / 1024

    }'
}


get_storage_info() {

    local output

    output=$(pvesm status 2>/dev/null || true)

    if [[ -z "$output" ]]; then
        echo "Storage 정보를 가져올 수 없습니다."
        return
    fi


    while read -r name type status total used available percent; do

        [[ "$name" == "Name" ]] && continue
        [[ -z "$name" ]] && continue


        local icon="🟢"

        if [[ "$status" != "active" ]]; then
            icon="🔴"
        fi


        local total_display
        local used_display

        total_display=$(format_kib "$total")
        used_display=$(format_kib "$used")


        if [[ "$percent" == "N/A" ]]; then

            echo "${icon} ${name}"
            echo "${used_display} used / ${total_display} · N/A"

        else

            echo "${icon} ${name}"
            echo "${used_display} used / ${total_display} · ${percent}"

        fi

    done <<< "$output"
}


# ============================================================
# Backup information
# ============================================================

get_backup_directory() {

    local storage="$1"

    awk -v target="$storage" '
        $1 == "dir:" && $2 == target {
            found=1
            next
        }

        found && $1 == "path" {
            print $2
            exit
        }

        found && $1 ~ /^[A-Za-z0-9_-]+:/ {
            exit
        }
    ' /etc/pve/storage.cfg
}


get_backup_info() {

    local storage_cfg="/etc/pve/storage.cfg"
    local backup_base=""
    local backup_dir=""

    # --------------------------------------------------------
    # Find Proxmox backup storage path automatically
    # --------------------------------------------------------

    if [[ ! -f "$storage_cfg" ]]; then
        echo "Proxmox Storage 설정을 찾을 수 없습니다."
        return
    fi

    local current_storage=""
    local current_type=""
    local current_path=""
    local current_content=""

    while IFS= read -r line || [[ -n "$line" ]]; do

        # New storage definition
        if [[ "$line" =~ ^(dir|nfs|cifs):[[:space:]]+(.+)$ ]]; then

            # Check previous storage
            if [[ "$current_type" == "dir" ]] &&
               [[ "$current_content" == *"backup"* ]] &&
               [[ -n "$current_path" ]]; then

                backup_base="$current_path"
                break
            fi

            current_type="${BASH_REMATCH[1]}"
            current_storage="${BASH_REMATCH[2]}"
            current_path=""
            current_content=""
            continue
        fi

        # Storage path
        if [[ "$line" =~ ^[[:space:]]+path[[:space:]]+(.+)$ ]]; then
            current_path="${BASH_REMATCH[1]}"
            continue
        fi

        # Storage content
        if [[ "$line" =~ ^[[:space:]]+content[[:space:]]+(.+)$ ]]; then
            current_content="${BASH_REMATCH[1]}"
            continue
        fi

    done < "$storage_cfg"

    # Check final storage entry
    if [[ -z "$backup_base" ]] &&
       [[ "$current_type" == "dir" ]] &&
       [[ "$current_content" == *"backup"* ]] &&
       [[ -n "$current_path" ]]; then

        backup_base="$current_path"
    fi


    # --------------------------------------------------------
    # Validate backup path
    # --------------------------------------------------------

    if [[ -z "$backup_base" ]]; then
        echo "백업 Storage를 찾을 수 없습니다."
        return
    fi

    backup_dir="${backup_base%/}/dump"

    if [[ ! -d "$backup_dir" ]]; then
        echo "백업 디렉터리를 찾을 수 없습니다."
        return
    fi


    # --------------------------------------------------------
    # Find latest 5 actual backup files
    # --------------------------------------------------------

    local files

    files=$(find "$backup_dir" \
        -maxdepth 1 \
        -type f \
        \( -name "*.vma.zst" -o -name "*.tar.zst" \) \
        -printf '%T@|%p\n' 2>/dev/null |
        sort -nr |
        head -n 5)

    if [[ -z "$files" ]]; then
        echo "백업 파일이 없습니다."
        return
    fi


    # --------------------------------------------------------
    # Display backup information
    # --------------------------------------------------------

    while IFS='|' read -r timestamp file; do

        [[ -z "$file" ]] && continue

        local filename
        filename=$(basename "$file")


        # ----------------------------------------------------
        # Backup date
        # ----------------------------------------------------

        local date_text
        date_text=$(date -d "@${timestamp%.*}" '+%Y-%m-%d %H:%M')


        # ----------------------------------------------------
        # Backup size
        # ----------------------------------------------------

        local size
        size=$(du -h "$file" 2>/dev/null |
            awk '{print $1}')

        [[ -z "$size" ]] && size="Unknown"


        # ----------------------------------------------------
        # Identify VM / LXC
        # ----------------------------------------------------

        local backup_type="Unknown"
        local vmid=""

        if [[ "$filename" =~ ^vzdump-qemu-([0-9]+)- ]]; then

            backup_type="VM"
            vmid="${BASH_REMATCH[1]}"

        elif [[ "$filename" =~ ^vzdump-lxc-([0-9]+)- ]]; then

            backup_type="LXC"
            vmid="${BASH_REMATCH[1]}"

        fi


        # ----------------------------------------------------
        # Get VM / LXC name
        # ----------------------------------------------------

        local guest_name=""

        if [[ "$backup_type" == "VM" ]] &&
           [[ -n "$vmid" ]]; then

            guest_name=$(qm config "$vmid" 2>/dev/null |
                awk -F': ' '/^name:/ {
                    print $2
                    exit
                }')

        elif [[ "$backup_type" == "LXC" ]] &&
             [[ -n "$vmid" ]]; then

            guest_name=$(pct config "$vmid" 2>/dev/null |
                awk -F': ' '/^hostname:/ {
                    print $2
                    exit
                }')

        fi


        [[ -z "$guest_name" ]] && guest_name="ID ${vmid}"


        # ----------------------------------------------------
        # Check backup log
        # ----------------------------------------------------

        local log_file=""

        if [[ "$file" == *.vma.zst ]]; then
            log_file="${file%.vma.zst}.log"

        elif [[ "$file" == *.tar.zst ]]; then
            log_file="${file%.tar.zst}.log"
        fi


        local status="🟢"
        local result_text="정상"

        if [[ ! -f "$log_file" ]]; then

            status="🟠"
            result_text="로그 없음"

        else

            if grep -qiE \
                'ERROR|FAILED|FAILURE|vzdump.*error|backup.*failed' \
                "$log_file"; then

                status="🔴"
                result_text="실패"

            elif grep -qiE \
                'TASK ERROR|ERROR:|unable to|cannot' \
                "$log_file"; then

                status="🔴"
                result_text="실패"

            fi
        fi


        # ----------------------------------------------------
        # Output
        # ----------------------------------------------------

        echo "${status} ${date_text} · ${backup_type} ${vmid} · ${guest_name}"
        echo "${size} · ${result_text}"

    done <<< "$files"
}


# ============================================================
# Hardware information
# ============================================================

get_hardware_info() {

    local cpu
    local board
    local ram
    local bios

    cpu=$(lscpu 2>/dev/null |
        awk -F: '/Model name:/ {
            gsub(/^[ \t]+/, "", $2)
            print $2
            exit
        }')

    board=$(dmidecode -s baseboard-manufacturer 2>/dev/null)

    local board_product
    board_product=$(dmidecode -s baseboard-product-name 2>/dev/null)

    if [[ -n "$board" && -n "$board_product" ]]; then
        board="${board} ${board_product}"
    fi

    # --------------------------------------------------------
    # Physical RAM
    #
    # dmidecode counts only installed memory modules.
    # This avoids displaying reserved/usable memory such as
    # "14Gi" from free -h when the machine physically has 16 GB.
    # --------------------------------------------------------

    ram=$(dmidecode --type memory 2>/dev/null |
        awk '
            /^Memory Device$/ {
                size=""
                in_device=1
                next
            }

            in_device && /^[[:space:]]*Size:/ {
                value=$0
                sub(/^[^:]*:[[:space:]]*/, "", value)

                if (value != "No Module Installed" &&
                    value != "No Module Installed " &&
                    value != "") {
                    print value
                }

                in_device=0
            }
        ' |
        awk '
            {
                if ($2 == "GB")
                    total += $1
                else if ($2 == "MB")
                    total += $1 / 1024
            }

            END {
                if (total > 0)
                    printf "%.0f GB", total
            }
        ')

    bios=$(dmidecode -t bios 2>/dev/null |
        awk -F: '
            /Version:/ {
                gsub(/^[ \t]+/, "", $2)
                version=$2
            }
            /Release Date:/ {
                gsub(/^[ \t]+/, "", $2)
                date=$2
            }
            END {
                if (version != "")
                    print version " · " date
            }
        ')

    [[ -z "$cpu" ]] && cpu="-"
    [[ -z "$board" ]] && board="-"
    [[ -z "$ram" ]] && ram="-"
    [[ -z "$bios" ]] && bios="-"

    echo "CPU: ${cpu}"
    echo "Mainboard: ${board}"
    echo "RAM: ${ram}"
    echo "BIOS: ${bios}"
}


# ============================================================
# 24-hour activity analysis
# ============================================================

format_activity_rate() {
    local bytes="$1"

    awk -v b="$bytes" 'BEGIN {
        if (b >= 1024*1024*1024)
            printf "%.1f GB/s", b/1024/1024/1024
        else if (b >= 1024*1024)
            printf "%.1f MB/s", b/1024/1024
        else if (b >= 1024)
            printf "%.1f KB/s", b/1024
        else
            printf "%.0f B/s", b
    }'
}


make_percent_graph() {
    local values="$1"

    awk -v values="$values" '
    BEGIN {
        n = split(values, a, " ")
        chars = "▁▂▃▄▅▆▇█"

        for (i = 1; i <= n; i++) {
            value = a[i]

            if (value < 0)
                value = 0

            if (value > 100)
                value = 100

            level = int(value / 100 * 8)

            if (level > 7)
                level = 7

            printf "%s", substr(chars, level + 1, 1)
        }

        printf "\n"
    }'
}


make_relative_graph() {
    local values="$1"
    local max_value="$2"

    awk -v values="$values" -v max="$max_value" '
    BEGIN {
        n = split(values, a, " ")
        chars = "▁▂▃▄▅▆▇█"

        for (i = 1; i <= n; i++) {
            value = a[i]

            if (max <= 0) {
                level = 0
            } else {
                level = int(value / max * 8)
            }

            if (level < 0)
                level = 0

            if (level > 7)
                level = 7

            printf "%s", substr(chars, level + 1, 1)
        }

        printf "\n"
    }'
}


get_guest_rrd() {
    local type="$1"
    local id="$2"
    local node

    node=$(pvesh get /nodes --output-format json 2>/dev/null |
        jq -r '.[0].node // empty')

    [[ -z "$node" ]] && node=$(hostname)

    if [[ "$type" == "VM" ]]; then
        pvesh get \
            "/nodes/${node}/qemu/${id}/rrddata" \
            --timeframe day \
            --output-format json \
            2>/dev/null || true

    elif [[ "$type" == "LXC" ]]; then
        pvesh get \
            "/nodes/${node}/lxc/${id}/rrddata" \
            --timeframe day \
            --output-format json \
            2>/dev/null || true
    fi
}


build_guest_activity_report() {

    local type="$1"
    local id="$2"
    local guest_name="$3"
    local rrd="$4"
    local start_time="$5"
    local end_time="$6"

    local start_display
    local end_display

    start_display=$(date -d "@${start_time}" '+%m/%d %H:%M')
    end_display=$(date -d "@${end_time}" '+%m/%d %H:%M')


    # ------------------------------------------------------------
    # 정확한 24시간 범위만 추출
    # ------------------------------------------------------------

    local filtered_rrd

    filtered_rrd=$(jq -c \
        --argjson start "$start_time" \
        --argjson end "$end_time" '
        [
            .[]
            | select(
                (.time // 0) >= $start and
                (.time // 0) < $end and
                (.cpu != null) and
                (.maxcpu != null) and
                (.mem != null) and
                (.maxmem != null) and
                (.diskread != null) and
                (.diskwrite != null)
            )
        ]
    ' <<< "${rrd:-[]}")


    # ------------------------------------------------------------
    # 24시간 전체 평균 / 최대값
    # ------------------------------------------------------------

    local summary

    summary=$(jq -c \
        --argjson start "$start_time" \
        --argjson end "$end_time" '
        def cpu:
            if (.maxcpu // 0) > 0
            then ((.cpu // 0) / .maxcpu * 100)
            else 0
            end;

        def ram:
            if (.maxmem // 0) > 0
            then ((.mem // 0) / .maxmem * 100)
            else 0
            end;

        def avg($values):
            if ($values | length) == 0
            then 0
            else ($values | add / length)
            end;

        def maxv($values):
            if ($values | length) == 0
            then 0
            else ($values | max)
            end;

        . as $all |

        ($all | map(cpu)) as $cpu_values |
        ($all | map(ram)) as $ram_values |
        ($all | map(.diskread // 0)) as $read_values |
        ($all | map(.diskwrite // 0)) as $write_values |

        {
            cpu_avg: avg($cpu_values),
            cpu_max: maxv($cpu_values),

            ram_avg: avg($ram_values),
            ram_max: maxv($ram_values),

            read_avg: avg($read_values),
            read_max: maxv($read_values),

            write_avg: avg($write_values),
            write_max: maxv($write_values),

            cpu_graph: [
                range(0; 12) as $i |
                (
                    $all
                    | map(select(
                        .time >= ($start + ($i * 7200)) and
                        .time < ($start + (($i + 1) * 7200))
                    ))
                    | map(cpu)
                    | avg(.)
                )
            ],

            ram_graph: [
                range(0; 12) as $i |
                (
                    $all
                    | map(select(
                        .time >= ($start + ($i * 7200)) and
                        .time < ($start + (($i + 1) * 7200))
                    ))
                    | map(ram)
                    | avg(.)
                )
            ],

            read_graph: [
                range(0; 12) as $i |
                (
                    $all
                    | map(select(
                        .time >= ($start + ($i * 7200)) and
                        .time < ($start + (($i + 1) * 7200))
                    ))
                    | map(.diskread // 0)
                    | avg(.)
                )
            ],

            write_graph: [
                range(0; 12) as $i |
                (
                    $all
                    | map(select(
                        .time >= ($start + ($i * 7200)) and
                        .time < ($start + (($i + 1) * 7200))
                    ))
                    | map(.diskwrite // 0)
                    | avg(.)
                )
            ]
        }
    ' <<< "$filtered_rrd")


    local cpu_avg
    local cpu_max
    local ram_avg
    local ram_max
    local read_avg
    local read_max
    local write_avg
    local write_max

    cpu_avg=$(jq -r '.cpu_avg' <<< "$summary")
    cpu_max=$(jq -r '.cpu_max' <<< "$summary")

    ram_avg=$(jq -r '.ram_avg' <<< "$summary")
    ram_max=$(jq -r '.ram_max' <<< "$summary")

    read_avg=$(jq -r '.read_avg' <<< "$summary")
    read_max=$(jq -r '.read_max' <<< "$summary")

    write_avg=$(jq -r '.write_avg' <<< "$summary")
    write_max=$(jq -r '.write_max' <<< "$summary")


    # ------------------------------------------------------------
    # 12칸 그래프
    # ------------------------------------------------------------

    local cpu_values
    local ram_values
    local read_values
    local write_values

    cpu_values=$(jq -r '.cpu_graph | join(" ")' <<< "$summary")
    ram_values=$(jq -r '.ram_graph | join(" ")' <<< "$summary")
    read_values=$(jq -r '.read_graph | join(" ")' <<< "$summary")
    write_values=$(jq -r '.write_graph | join(" ")' <<< "$summary")


    local cpu_graph
    local ram_graph
    local read_graph
    local write_graph

    cpu_graph=$(make_percent_graph "$cpu_values")
    ram_graph=$(make_percent_graph "$ram_values")

    read_graph=$(make_relative_graph "$read_values" "$read_max")
    write_graph=$(make_relative_graph "$write_values" "$write_max")


    # ------------------------------------------------------------
    # 특이사항
    #
    # 반드시 24시간 전체 평균을 먼저 계산하고,
    # 그 고정된 평균을 기준으로 급증 여부를 판정한다.
    # ------------------------------------------------------------

    local detail_output

    detail_output=$(jq -r \
        --argjson cpu_avg "$cpu_avg" \
        --argjson ram_avg "$ram_avg" \
        --argjson read_avg "$read_avg" \
        --argjson write_avg "$write_avg" '

        .[]
        | [
            (.time // 0),

            (
                if (.maxcpu // 0) > 0
                then ((.cpu // 0) / .maxcpu * 100)
                else 0
                end
            ),

            (
                if (.maxmem // 0) > 0
                then ((.mem // 0) / .maxmem * 100)
                else 0
                end
            ),

            (.diskread // 0),
            (.diskwrite // 0)
        ]
        | @tsv
    ' <<< "$filtered_rrd" |
    awk \
        -v cpu_avg="$cpu_avg" \
        -v ram_avg="$ram_avg" \
        -v read_avg="$read_avg" \
        -v write_avg="$write_avg" '

        function rate(bytes) {

            if (bytes >= 1024*1024*1024)
                return sprintf("%.1f GB/s", bytes/1024/1024/1024)

            if (bytes >= 1024*1024)
                return sprintf("%.1f MB/s", bytes/1024/1024)

            if (bytes >= 1024)
                return sprintf("%.1f KB/s", bytes/1024)

            return sprintf("%.0f B/s", bytes)
        }


        function reset_group() {

            group_active = 0

            group_start = 0
            group_end = 0

            cpu_spike = 0
            ram_spike = 0
            read_spike = 0
            write_spike = 0

            cpu_sum = 0
            ram_sum = 0
            read_sum = 0
            write_sum = 0

            cpu_count = 0
            ram_count = 0
            read_count = 0
            write_count = 0

            cpu_peak = 0
            ram_peak = 0
            read_peak = 0
            write_peak = 0
        }


        function flush_group(    reason) {

            if (!group_active)
                return

            reason = ""

            if (cpu_spike)
                reason = reason "CPU, "

            if (ram_spike)
                reason = reason "RAM, "

            if (read_spike)
                reason = reason "Read, "

            if (write_spike)
                reason = reason "Write, "

            sub(/, $/, "", reason)


            if (group_start == group_end) {

                printf "🕐 %s %s 급증\n",
                    strftime("%H:%M", group_start),
                    reason

            } else {

                printf "🕐 %s~%s %s 급증\n",
                    strftime("%H:%M", group_start),
                    strftime("%H:%M", group_end),
                    reason
            }


            if (cpu_spike)
                printf "CPU 평균 %.1f%% · 최대 %.1f%%\n",
                    cpu_sum / cpu_count,
                    cpu_peak


            if (ram_spike)
                printf "RAM 평균 %.1f%% · 최대 %.1f%%\n",
                    ram_sum / ram_count,
                    ram_peak


            if (read_spike)
                printf "Read 평균 %s · 최대 %s\n",
                    rate(read_sum / read_count),
                    rate(read_peak)


            if (write_spike)
                printf "Write 평균 %s · 최대 %s\n",
                    rate(write_sum / write_count),
                    rate(write_peak)


            reset_group()
        }


        BEGIN {
            reset_group()
            previous_time = 0
        }


        {

            timestamp = $1
            cpu = $2
            ram = $3
            read = $4
            write = $5


            if (read < 0)
                read = 0

            if (write < 0)
                write = 0


            cpu_is_spike = 0
            ram_is_spike = 0
            read_is_spike = 0
            write_is_spike = 0


            # CPU
            if (cpu >= 5)
                cpu_is_spike = 1


            # RAM
            if (ram_avg > 0 && ram > ram_avg * 10)
                ram_is_spike = 1


            # Read
            if (read_avg > 0 &&
                read > read_avg * 10 &&
                read >= 1024*1024)
                read_is_spike = 1


            # Write
            if (write_avg > 0 &&
                write > write_avg * 10 &&
                write >= 1024*1024)
                write_is_spike = 1


            any_spike = 0

            if (cpu_is_spike ||
                ram_is_spike ||
                read_is_spike ||
                write_is_spike)
                any_spike = 1


            # ------------------------------------------------
            # 급증 그룹 시작/연결
            # ------------------------------------------------

            if (any_spike) {

                if (group_active &&
                    previous_time > 0 &&
                    timestamp - previous_time > 120) {

                    flush_group()
                }


                if (!group_active) {

                    group_active = 1

                    group_start = timestamp
                    group_end = timestamp

                    cpu_spike = 0
                    ram_spike = 0
                    read_spike = 0
                    write_spike = 0

                    cpu_sum = 0
                    ram_sum = 0
                    read_sum = 0
                    write_sum = 0

                    cpu_count = 0
                    ram_count = 0
                    read_count = 0
                    write_count = 0

                    cpu_peak = 0
                    ram_peak = 0
                    read_peak = 0
                    write_peak = 0
                }


                group_end = timestamp


                if (cpu_is_spike) {

                    cpu_spike = 1
                    cpu_sum += cpu
                    cpu_count++

                    if (cpu > cpu_peak)
                        cpu_peak = cpu
                }


                if (ram_is_spike) {

                    ram_spike = 1
                    ram_sum += ram
                    ram_count++

                    if (ram > ram_peak)
                        ram_peak = ram
                }


                if (read_is_spike) {

                    read_spike = 1
                    read_sum += read
                    read_count++

                    if (read > read_peak)
                        read_peak = read
                }


                if (write_is_spike) {

                    write_spike = 1
                    write_sum += write
                    write_count++

                    if (write > write_peak)
                        write_peak = write
                }

            } else if (group_active) {

                flush_group()
            }


            previous_time = timestamp
        }


        END {

            if (group_active)
                flush_group()
        }
    ')


    # ------------------------------------------------------------
    # 최종 메시지
    # ------------------------------------------------------------

    local message=""

    message+="📈 ${type} ${id} · ${guest_name} (${start_display} ~ ${end_display})"
    message+=$'\n'
    message+="-----------------------"
    message+=$'\n'
    message+="📊 24시간 요약"
    message+=$'\n'

    message+="CPU (평균 $(printf '%.1f' "$cpu_avg")% · 최대 $(printf '%.1f' "$cpu_max")%)"
    message+=$'\n'
    message+="${cpu_graph}"

    message+="RAM (평균 $(printf '%.1f' "$ram_avg")% · 최대 $(printf '%.1f' "$ram_max")%)"
    message+=$'\n'
    message+="${ram_graph}"

    message+="Read (평균 $(format_activity_rate "$read_avg") · 최대 $(format_activity_rate "$read_max"))"
    message+=$'\n'
    message+="${read_graph}"

    message+="Write (평균 $(format_activity_rate "$write_avg") · 최대 $(format_activity_rate "$write_max"))"
    message+=$'\n'
    message+="${write_graph}"

    message+=$'\n'
    message+="-----------------------"
    message+=$'\n'
    message+="⚠️ 특이사항"
    message+=$'\n'

    if [[ -n "$detail_output" ]]; then
        message+="${detail_output}"
    else
        message+="특이사항 없음"
    fi


    printf '%s' "$message"
}


generate_activity_reports() {

    local mode="${1:-send}"

    local now
    local start_time
    local end_time

    now=$(date +%s)
    start_time=$((now - 86400))
    end_time="$now"

    local vmid
    local vm_name
    local rrd
    local message

    # --------------------------------------------------------
    # VM
    # --------------------------------------------------------

    while read -r vmid; do

        [[ -z "$vmid" ]] && continue

        vm_name=$(qm config "$vmid" 2>/dev/null |
            awk -F': ' '/^name:/ {print $2; exit}')

        [[ -z "$vm_name" ]] && vm_name="VM ${vmid}"

        rrd=$(get_guest_rrd "VM" "$vmid")

        message=$(build_guest_activity_report \
            "VM" \
            "$vmid" \
            "$vm_name" \
            "$rrd" \
            "$start_time" \
            "$end_time")

        if [[ "$mode" == "test" ]]; then
            printf '%s\n\n' "$message"
        else
            telegram_send_long "$message"
        fi

    done < <(qm list 2>/dev/null | awk 'NR > 1 {print $1}')

    # --------------------------------------------------------
    # LXC
    # --------------------------------------------------------

    local ctid
    local ct_name

    while read -r ctid; do

        [[ -z "$ctid" ]] && continue

        ct_name=$(pct config "$ctid" 2>/dev/null |
            awk -F': ' '/^hostname:/ {print $2; exit}')

        [[ -z "$ct_name" ]] && ct_name="LXC ${ctid}"

        rrd=$(get_guest_rrd "LXC" "$ctid")

        message=$(build_guest_activity_report \
            "LXC" \
            "$ctid" \
            "$ct_name" \
            "$rrd" \
            "$start_time" \
            "$end_time")

        if [[ "$mode" == "test" ]]; then
            printf '%s\n\n' "$message"
        else
            telegram_send_long "$message"
        fi

    done < <(pct list 2>/dev/null | awk 'NR > 1 {print $1}')
}


# ============================================================
# Daily report
# ============================================================

generate_report() {

    local now
    now=$(date '+%Y-%m-%d %H:%M')

    local hostname
    hostname=$(hostname)

    local pve_version
    pve_version=$(get_pve_version)

    local kernel
    kernel=$(get_kernel_version)

    local uptime
    uptime=$(get_uptime)

    local message=""

    message+="🖥️ Proxmox 서버 리포트"
    message+=$'\n'
    message+="${now}"
    message+=$'\n'
    message+=$'\n'

    # --------------------------------------------------------
    # Server status
    # --------------------------------------------------------

    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'
    message+="📌 서버 상태"
    message+=$'\n'
    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'

    message+="🟢 Proxmox 정상"
    message+=$'\n'
    message+="가동 시간: ${uptime}"
    message+=$'\n'
    message+=$'\n'

    message+="Proxmox VE: ${pve_version}"
    message+=$'\n'
    message+="Kernel: ${kernel}"
    message+=$'\n'
    message+=$'\n'


    # --------------------------------------------------------
    # VM
    # --------------------------------------------------------

    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'
    message+="🖥️ VM"
    message+=$'\n'
    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'

    local vm_list
    vm_list=$(qm list 2>/dev/null |
        awk 'NR > 1 {print $1}')

    if [[ -z "$vm_list" ]]; then

        message+="등록된 VM이 없습니다."
        message+=$'\n'

    else

        while read -r vmid; do

            [[ -z "$vmid" ]] && continue

            local vm_info
            vm_info=$(get_vm_info "$vmid")

            message+="${vm_info}"
            message+=$'\n'
            message+=$'\n'

        done <<< "$vm_list"

    fi


    # --------------------------------------------------------
    # LXC
    # --------------------------------------------------------

    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'
    message+="📦 LXC"
    message+=$'\n'
    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'

    local lxc_list
    lxc_list=$(pct list 2>/dev/null |
        awk 'NR > 1 {print $1}')

    if [[ -z "$lxc_list" ]]; then

        message+="등록된 LXC가 없습니다."
        message+=$'\n'

    else

        while read -r ctid; do

            [[ -z "$ctid" ]] && continue

            local lxc_info
            lxc_info=$(get_lxc_info "$ctid")

            message+="${lxc_info}"
            message+=$'\n'
            message+=$'\n'

        done <<< "$lxc_list"

    fi


    # --------------------------------------------------------
    # Physical disks
    # --------------------------------------------------------

    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'
    message+="💾 디스크"
    message+=$'\n'
    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'

    local disks
    disks=$(smartctl --scan-open 2>/dev/null || true)

    while read -r line; do

        [[ -z "$line" ]] && continue

        local device
        local type

        device=$(echo "$line" | awk '{print $1}')

        type=$(echo "$line" |
            sed -n 's/.*-d \([^ ]*\).*/\1/p')

        [[ -z "$type" ]] && type="sat"

        local disk_info
        disk_info=$(get_disk_info "$device" "$type")

        message+="${disk_info}"
        message+=$'\n'
        message+=$'\n'

    done <<< "$disks"


    # --------------------------------------------------------
    # Proxmox storage
    # --------------------------------------------------------

    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'
    message+="💾 Proxmox Storage"
    message+=$'\n'
    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'

    local storage_info
    storage_info=$(get_storage_info)

    message+="${storage_info}"
    message+=$'\n'


    # --------------------------------------------------------
    # Backup
    # --------------------------------------------------------

    message+=$'\n'
    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'
    message+="💾 최근 백업"
    message+=$'\n'
    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'

    local backup_info
    backup_info=$(get_backup_info)

    message+="${backup_info}"
    message+=$'\n'


    # --------------------------------------------------------
    # Hardware
    # --------------------------------------------------------

    message+=$'\n'
    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'
    message+="🖥️ 서버 사양"
    message+=$'\n'
    message+="━━━━━━━━━━━━━━━━━━"
    message+=$'\n'

    local hardware_info
    hardware_info=$(get_hardware_info)

    message+="${hardware_info}"
    message+=$'\n'


    telegram_send_long "$message"
}

# ============================================================
# Telegram test
# ============================================================

send_test() {

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    local hostname
    hostname=$(hostname)

    local pve_version
    pve_version=$(get_pve_version)

    local kernel
    kernel=$(get_kernel_version)

    local message=""

    message+="🟢 Proxmox Telegram Monitor 테스트"
    message+=$'\n'
    message+=$'\n'
    message+="서버: ${hostname}"
    message+=$'\n'
    message+="Proxmox VE: ${pve_version}"
    message+=$'\n'
    message+="Kernel: ${kernel}"
    message+=$'\n'
    message+="시간: ${now}"
    message+=$'\n'
    message+=$'\n'
    message+="Telegram 연결이 정상적으로 확인되었습니다."

    log "Sending Telegram test message..."

    telegram_send "$message"

    log "Test message sent successfully."
}


# ============================================================
# Help
# ============================================================

usage() {

    cat <<EOF

Proxmox Telegram Monitor ${VERSION}

Usage:

  ${0} --install
      Install Proxmox Telegram Monitor.

  ${0} --uninstall
      Uninstall the daily report timer and configuration.

  ${0} --report
      Generate and send the daily Proxmox report.

  ${0} --activity
      Generate and send the recent 24-hour activity report.

  ${0} --activity-test
      Generate the recent 24-hour activity report
      without sending Telegram messages.

  ${0} --smart
      Show SMART status, monitoring rules and
      detected disk problems.

  ${0} --test
      Send a Telegram connection test message.

  ${0} --version
      Show script version.

  ${0} --help
      Show this help.

Configuration:

  ${CONFIG_FILE}

EOF
}


# ============================================================
# Main
# ============================================================

main() {

    case "${1:-}" in

        --install)

            install_monitor

            ;;

        --uninstall)

            uninstall_monitor

            ;;

        --report)

            load_config
            generate_report

            ;;

        --activity)

            load_config
            generate_activity_reports send

            ;;

        --activity-test)

            generate_activity_reports test

            ;;

        --smart)

            generate_smart_report

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