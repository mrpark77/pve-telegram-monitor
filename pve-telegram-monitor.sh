#!/usr/bin/env bash
#
# pve-telegram-monitor.sh
#
# Proxmox VE Telegram Monitor
# Version: 1.3.0
#

set -u
set -o pipefail

VERSION="1.3.0"

CONFIG_FILE="/etc/pve-telegram-monitor/config"

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
            .[]?
            | .["ip-addresses"][]?
            | select(.["ip-address-type"] == "ipv4")
            | .["ip-address"]
        ' 2>/dev/null |
        grep -v '^127\.' |
        grep -v '^169\.254\.' |
        head -n 1
}


get_vm_mac() {

    local vmid="$1"

    qm config "$vmid" 2>/dev/null |
        awk '
            /^net[0-9]+:/ {
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
                        print toupper($i)
                        exit
                    }
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

    mac=$(get_vm_mac "$vmid")

    ip=$(get_vm_ip "$vmid")

    [[ -z "$name" ]] && name="Unknown"
    [[ -z "$cores" ]] && cores="-"
    [[ -z "$memory" ]] && memory="-"
    [[ -z "$mac" ]] && mac="-"
    [[ -z "$ip" ]] && ip="-"

    local ram_display

    if [[ "$memory" =~ ^[0-9]+$ ]]; then

        if (( memory >= 1024 )); then
            ram_display="$(awk -v m="$memory" 'BEGIN {
                printf "%.0f GB", m/1024
            }')"
        else
            ram_display="${memory} MB"
        fi

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


    local status="🟢"

    if ! qm status "$vmid" 2>/dev/null |
        grep -q 'status: running'; then
        status="🔴"
    fi


    echo "${status} VM ${vmid} · ${name}"
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
                    print toupper(value)
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

                    if (value != "dhcp" && value != "manual") {
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


    local status="🟢"

    if ! pct status "$ctid" 2>/dev/null |
        grep -q 'status: running'; then
        status="🔴"
    fi


    echo "${status} LXC ${ctid} · ${hostname}"
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

    if [[ -z "$output" ]]; then
        echo "🔴"
        return
    fi


    local reallocated
    local pending
    local offline_uncorrectable
    local reported_uncorrect
    local media_errors
    local critical_warning

    reallocated=$(echo "$output" |
        awk '$1 == 5 {print $10; exit}')

    pending=$(echo "$output" |
        awk '$1 == 197 {print $10; exit}')

    offline_uncorrectable=$(echo "$output" |
        awk '$1 == 198 {print $10; exit}')

    reported_uncorrect=$(echo "$output" |
        awk '$1 == 187 {print $10; exit}')

    media_errors=$(echo "$output" |
        awk -F: '/Media and Data Integrity Errors:/ {
            gsub(/^[ \t]+/, "", $2)
            print $2
            exit
        }')

    critical_warning=$(echo "$output" |
        awk -F: '/Critical Warning:/ {
            gsub(/^[ \t]+/, "", $2)
            print $2
            exit
        }')


    if [[ "$critical_warning" =~ ^0x ]] &&
       [[ "$critical_warning" != "0x00" ]]; then
        echo "🔴"
        return
    fi

    if [[ "$media_errors" =~ ^[0-9]+$ ]] &&
       (( media_errors > 0 )); then
        echo "🔴"
        return
    fi

    if [[ "$pending" =~ ^[0-9]+$ ]] &&
       (( pending > 0 )); then
        echo "🔴"
        return
    fi

    if [[ "$offline_uncorrectable" =~ ^[0-9]+$ ]] &&
       (( offline_uncorrectable > 0 )); then
        echo "🔴"
        return
    fi

    if [[ "$reported_uncorrect" =~ ^[0-9]+$ ]] &&
       (( reported_uncorrect > 0 )); then
        echo "🔴"
        return
    fi

    if [[ "$reallocated" =~ ^[0-9]+$ ]] &&
       (( reallocated > 0 )); then
        echo "🟠"
        return
    fi


    local crc

    crc=$(echo "$output" |
        awk '$1 == 199 {print $10; exit}')

    if [[ "$crc" =~ ^[0-9]+$ ]] &&
       (( crc > 0 )); then
        echo "🟠"
        return
    fi

    echo "🟢"
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

    status=$(smart_status "$device" "$type")
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

get_backup_info() {

    local backup_dir="/mnt/pve/backup-hdd"


    if [[ ! -d "$backup_dir" ]]; then
        echo "백업 디렉터리를 찾을 수 없습니다."
        return
    fi


    if ! mountpoint -q "$backup_dir" 2>/dev/null; then
        echo "백업 디스크가 마운트되지 않았습니다."
        return
    fi


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


    while IFS='|' read -r timestamp file; do

        [[ -z "$file" ]] && continue


        local filename
        filename=$(basename "$file")


        local date_text
        date_text=$(date -d "@${timestamp%.*}" '+%Y-%m-%d %H:%M')


        local size
        size=$(du -h "$file" 2>/dev/null |
            awk '{print $1}')


        local status="🟢"


        local log_file="${file%.vma.zst}.log"

        [[ "$file" == *.tar.zst ]] &&
            log_file="${file%.tar.zst}.log"


        if [[ -f "$log_file" ]]; then

            if grep -qiE \
                'error|failed|failure|vzdump.*error' \
                "$log_file"; then

                status="🔴"

            fi

        fi


        echo "${status} ${date_text} · ${size}"
        echo "${filename}"


    done <<< "$files"
}


# ============================================================
# Hardware information
# ============================================================

get_physical_ram() {

    local total_mb

    total_mb=$(dmidecode --type memory 2>/dev/null |
        awk '
            /^Memory Device$/ {
                in_device=1
                size_mb=0
                unit=""
                next
            }

            in_device && /^[[:space:]]*Size:/ {

                value=$0
                sub(/^[^:]*:[[:space:]]*/, "", value)

                if (value ~ /^No Module Installed/)
                    size_mb=0

                else if (value ~ /GB$/) {
                    sub(/[[:space:]]*GB$/, "", value)
                    size_mb=value*1024
                }

                else if (value ~ /MB$/) {
                    sub(/[[:space:]]*MB$/, "", value)
                    size_mb=value
                }

                next
            }

            in_device && /^$/ {
                if (size_mb > 0)
                    total += size_mb

                in_device=0
                size_mb=0
            }

            END {
                if (in_device && size_mb > 0)
                    total += size_mb

                if (total > 0)
                    printf "%.0f\n", total
            }
        ')


    if [[ "$total_mb" =~ ^[0-9]+$ ]] &&
       (( total_mb > 0 )); then

        awk -v mb="$total_mb" 'BEGIN {
            if (mb >= 1024)
                printf "%.0f GB", mb/1024
            else
                printf "%.0f MB", mb
        }'

    else

        # DMI 정보를 읽을 수 없는 경우 Linux 기준으로 fallback
        free -m 2>/dev/null |
            awk '/^Mem:/ {
                if ($2 >= 1024)
                    printf "%.0f GB", $2/1024
                else
                    printf "%d MB", $2
            }'

    fi
}


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


    ram=$(get_physical_ram)


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

  ${0} --report
      Generate and send the daily Proxmox report.

  ${0} --test
      Send a Telegram connection test message.

  ${0} --version
      Show script version.

  ${0} --help
      Show this help.

Configuration:

  ${CONFIG_FILE}

Example:

  TELEGRAM_BOT_TOKEN="123456789:ABCDEF..."
  TELEGRAM_CHAT_ID="-1001234567890"

EOF
}


# ============================================================
# Main
# ============================================================

main() {

    case "${1:-}" in

        --report)

            load_config
            generate_report

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