#!/usr/bin/env bash
#
# pve-telegram-monitor.sh
#
# Proxmox VE Telegram Monitor
#
# Functions:
#   --report    Send daily Proxmox status report to Telegram
#   --test      Send a test message to Telegram
#   --version   Show script version
#
# The following information is collected:
#   - Proxmox version / kernel / uptime
#   - VM status, CPU, RAM, IP, MAC, disks
#   - LXC status, CPU, RAM, IP, MAC, disks
#   - Physical disk SMART status
#   - CPU / motherboard / RAM / physical disk information
#   - Recent Proxmox backups
#
# Telegram credentials are NOT stored in this script.
# They are read from:
#   /etc/pve-telegram-monitor/config
#

set -u
set -o pipefail

###############################################################################
# Configuration
###############################################################################

SCRIPT_VERSION="1.0.0"

CONFIG_FILE="/etc/pve-telegram-monitor/config"

# Default values
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Number of recent backups shown in the daily report
BACKUP_COUNT=5

# Telegram message limit
TELEGRAM_MAX_LENGTH=4000

###############################################################################
# Colors / symbols
###############################################################################

GREEN="🟢"
ORANGE="🟠"
RED="🔴"
YELLOW="🟡"
GRAY="⚪"

###############################################################################
# Basic functions
###############################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root."
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

###############################################################################
# Load configuration
###############################################################################

load_config() {

    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Configuration file not found:
$CONFIG_FILE

Create it first.
Example:

TELEGRAM_BOT_TOKEN=\"123456789:ABCDEF...\"
TELEGRAM_CHAT_ID=\"-1001234567890\"
"
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

###############################################################################
# Telegram
###############################################################################

telegram_send() {

    local message="$1"

    if ! command_exists curl; then
        die "curl is required."
    fi

    curl -fsS \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --data-urlencode "disable_web_page_preview=true" \
        >/dev/null
}

###############################################################################
# Proxmox version
###############################################################################

get_pve_version() {

    local version

    version="$(pveversion --verbose 2>/dev/null | awk -F': ' '
        /^proxmox-ve:/ { print $2; exit }
    ')"

    [[ -n "$version" ]] && echo "$version" || echo "Unknown"
}

get_pve_manager_version() {

    local version

    version="$(pveversion --verbose 2>/dev/null | awk -F': ' '
        /^pve-manager:/ { print $2; exit }
    ')"

    [[ -n "$version" ]] && echo "$version" || echo "Unknown"
}

get_kernel_version() {
    uname -r
}

get_uptime() {
    uptime -p 2>/dev/null || echo "Unknown"
}

###############################################################################
# CPU
###############################################################################

get_cpu_model() {

    local model

    model="$(lscpu 2>/dev/null | awk -F': +' '
        /^Model name:/ {
            print $2
            exit
        }
    ')"

    [[ -n "$model" ]] && echo "$model" || echo "Unknown"
}

get_cpu_cores() {

    lscpu 2>/dev/null | awk -F': +' '
        /^Core\(s\) per socket:/ {
            cores=$2
        }
        /^Socket\(s\):/ {
            sockets=$2
        }
        END {
            if (cores != "" && sockets != "")
                print cores * sockets
            else
                print "Unknown"
        }
    '
}

###############################################################################
# Motherboard / BIOS
###############################################################################

get_mainboard_manufacturer() {

    dmidecode -s baseboard-manufacturer 2>/dev/null \
        | head -n1
}

get_mainboard_model() {

    dmidecode -s baseboard-product-name 2>/dev/null \
        | head -n1
}

get_bios_version() {

    dmidecode -s bios-version 2>/dev/null \
        | head -n1
}

get_bios_date() {

    dmidecode -s bios-release-date 2>/dev/null \
        | head -n1
}

###############################################################################
# Memory
###############################################################################

get_memory_total() {

    free -h 2>/dev/null \
        | awk '/^Mem:/ { print $2 }'
}

get_memory_modules() {

    local output=""
    local size
    local type
    local speed
    local manufacturer
    local part

    while IFS='|' read -r size type speed manufacturer part; do

        [[ -z "$size" ]] && continue
        [[ "$size" == "No Module Installed" ]] && continue

        if [[ -n "$output" ]]; then
            output="${output}
"
        fi

        output="${output}${size}"

        if [[ -n "$type" && "$type" != "Unknown" ]]; then
            output="${output} · ${type}"
        fi

        if [[ -n "$speed" && "$speed" != "Unknown" ]]; then
            output="${output} · ${speed}"
        fi

        if [[ -n "$manufacturer" && "$manufacturer" != "Unknown" ]]; then
            output="${output} · ${manufacturer}"
        fi

        if [[ -n "$part" && "$part" != "Unknown" ]]; then
            output="${output}
  ${part}"
        fi

    done < <(
        dmidecode --type memory 2>/dev/null |
        awk '
        /^Memory Device$/ {
            size=""
            type=""
            speed=""
            manufacturer=""
            part=""
            installed=0
            next
        }

        /^Size:/ {
            size=$0
            sub(/^Size:[[:space:]]*/, "", size)

            if (size != "No Module Installed")
                installed=1
        }

        /^Type:/ {
            type=$0
            sub(/^Type:[[:space:]]*/, "", type)
        }

        /^Configured Memory Speed:/ {
            speed=$0
            sub(/^Configured Memory Speed:[[:space:]]*/, "", speed)
        }

        /^Manufacturer:/ {
            manufacturer=$0
            sub(/^Manufacturer:[[:space:]]*/, "", manufacturer)
        }

        /^Part Number:/ {
            part=$0
            sub(/^Part Number:[[:space:]]*/, "", part)
        }

        /^$/ {
            if (installed)
                printf "%s|%s|%s|%s|%s\n",
                    size, type, speed, manufacturer, part
        }

        END {
            if (installed)
                printf "%s|%s|%s|%s|%s\n",
                    size, type, speed, manufacturer, part
        }
        '
    )

    [[ -n "$output" ]] && echo "$output" || echo "Unknown"
}

###############################################################################
# Physical disks
###############################################################################

get_physical_disks() {

    lsblk -dn -o NAME,MODEL,SIZE,ROTA,TRAN 2>/dev/null |
    while read -r name model size rota tran; do

        [[ -z "$name" ]] && continue

        case "$name" in
            loop*|sr*|fd*|dm-*|md*)
                continue
                ;;
        esac

        echo "${name}|${model}|${size}|${rota}|${tran}"

    done
}

###############################################################################
# Disk SMART
###############################################################################

# SMART state:
#
# RED:
#   - SMART command failure
#   - SMART overall FAILED
#   - Reallocated sectors > 0
#   - Current pending sectors > 0
#   - Offline uncorrectable > 0
#
# ORANGE:
#   - SMART passed but ATA error log exists
#   - UDMA CRC errors > 0
#
# GREEN:
#   - SMART passed
#   - no important SMART error indicators
#
# This is intentionally conservative.
#

smart_status_sata() {

    local device="$1"
    local output

    output="$(smartctl -a -d sat "$device" 2>/dev/null || true)"

    if [[ -z "$output" ]]; then
        echo "${RED}|SMART unavailable"
        return
    fi

    if echo "$output" | grep -q \
        "SMART overall-health self-assessment test result: FAILED"; then

        echo "${RED}|SMART FAILED"
        return
    fi

    local reallocated
    local pending
    local offline
    local crc
    local ata_errors

    reallocated="$(echo "$output" |
        awk '$1=="5" {print $10; exit}')"

    pending="$(echo "$output" |
        awk '$1=="197" {print $10; exit}')"

    offline="$(echo "$output" |
        awk '$1=="198" {print $10; exit}')"

    crc="$(echo "$output" |
        awk '$1=="199" {print $10; exit}')"

    ata_errors="$(echo "$output" |
        awk -F': ' '/ATA Error Count:/ {print $2; exit}')"

    reallocated="${reallocated:-0}"
    pending="${pending:-0}"
    offline="${offline:-0}"
    crc="${crc:-0}"
    ata_errors="${ata_errors:-0}"

    if [[ "$reallocated" =~ ^[0-9]+$ ]] &&
       [[ "$reallocated" -gt 0 ]]; then

        echo "${RED}|Reallocated sectors: ${reallocated}"
        return
    fi

    if [[ "$pending" =~ ^[0-9]+$ ]] &&
       [[ "$pending" -gt 0 ]]; then

        echo "${RED}|Pending sectors: ${pending}"
        return
    fi

    if [[ "$offline" =~ ^[0-9]+$ ]] &&
       [[ "$offline" -gt 0 ]]; then

        echo "${RED}|Offline uncorrectable: ${offline}"
        return
    fi

    if [[ "$crc" =~ ^[0-9]+$ ]] &&
       [[ "$crc" -gt 0 ]]; then

        echo "${ORANGE}|UDMA CRC errors: ${crc}"
        return
    fi

    if [[ "$ata_errors" =~ ^[0-9]+$ ]] &&
       [[ "$ata_errors" -gt 0 ]]; then

        echo "${ORANGE}|ATA errors: ${ata_errors}"
        return
    fi

    echo "${GREEN}|SMART PASSED"
}

smart_status_nvme() {

    local device="$1"
    local output

    output="$(smartctl -a -d nvme "$device" 2>/dev/null || true)"

    if [[ -z "$output" ]]; then
        echo "${RED}|SMART unavailable"
        return
    fi

    if echo "$output" | grep -q \
        "SMART overall-health self-assessment test result: FAILED"; then

        echo "${RED}|SMART FAILED"
        return
    fi

    local critical
    local media_errors
    local error_entries
    local percentage_used

    critical="$(echo "$output" |
        awk -F': +' '/Critical Warning:/ {print $2; exit}')"

    media_errors="$(echo "$output" |
        awk -F': +' '/Media and Data Integrity Errors:/ {print $2; exit}')"

    error_entries="$(echo "$output" |
        awk -F': +' '/Error Information Log Entries:/ {print $2; exit}')"

    percentage_used="$(echo "$output" |
        awk -F': +' '/Percentage Used:/ {print $2; exit}')"

    critical="${critical:-0}"
    media_errors="${media_errors:-0}"
    error_entries="${error_entries:-0}"
    percentage_used="${percentage_used:-0}"

    if [[ "$critical" != "0x00" && "$critical" != "0" ]]; then
        echo "${RED}|Critical Warning: ${critical}"
        return
    fi

    if [[ "$media_errors" =~ ^[0-9]+$ ]] &&
       [[ "$media_errors" -gt 0 ]]; then

        echo "${RED}|Media errors: ${media_errors}"
        return
    fi

    if [[ "$error_entries" =~ ^[0-9]+$ ]] &&
       [[ "$error_entries" -gt 0 ]]; then

        echo "${ORANGE}|Error log entries: ${error_entries}"
        return
    fi

    echo "${GREEN}|SMART PASSED"
}

get_smart_status() {

    local device="$1"
    local tran="$2"

    case "$tran" in
        nvme)
            smart_status_nvme "$device"
            ;;
        sata|*)
            smart_status_sata "$device"
            ;;
    esac
}

###############################################################################
# Disk model / capacity information
###############################################################################

get_disk_serial() {

    local device="$1"

    smartctl -a "$device" 2>/dev/null |
        awk -F': +' '
            /^Serial Number:/ {
                print $2
                exit
            }
        '
}

get_disk_rpm() {

    local device="$1"

    smartctl -a -d sat "$device" 2>/dev/null |
        awk -F': +' '
            /^Rotation Rate:/ {
                print $2
                exit
            }
        '
}

get_disk_display_name() {

    local device="$1"
    local model="$2"
    local tran="$3"

    case "$tran" in

        nvme)
            echo "$model"
            ;;

        sata)
            case "$model" in

                ST*)
                    echo "Seagate ${model}"
                    ;;

                WDC*)
                    echo "Western Digital ${model#WDC }"
                    ;;

                *)
                    echo "$model"
                    ;;

            esac
            ;;

        *)
            echo "$model"
            ;;
    esac
}

###############################################################################
# VM information
###############################################################################

get_vm_ip() {

    local vmid="$1"
    local ip=""

    # First try Proxmox guest agent.
    ip="$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null |
        jq -r '
            .[]?
            | .["ip-addresses"][]?
            | select(."ip-address-type" == "ipv4")
            | ."ip-address"
            | select(startswith("127.") | not)
            | select(startswith("169.254.") | not)
        ' 2>/dev/null |
        head -n1 || true)"

    if [[ -n "$ip" ]]; then
        echo "$ip"
        return
    fi

    # Fall back to static Proxmox config.
    ip="$(qm config "$vmid" 2>/dev/null |
        awk -F'ip=' '/^ipconfig[0-9]+:/ {
            split($2,a,",")
            split(a[1],b,"/")
            print b[1]
            exit
        }')"

    [[ -n "$ip" ]] && echo "$ip" || echo "-"
}

get_vm_mac() {

    local vmid="$1"

    qm config "$vmid" 2>/dev/null |
        awk -F'[=,]' '
            /^net[0-9]+:/ {
                print $2
                exit
            }
        '
}

get_vm_disks() {

    local vmid="$1"

    qm config "$vmid" 2>/dev/null |
    awk '
        /^(scsi|sata|virtio|ide)[0-9]+:/ {
            line=$0

            if (line ~ /local-lvm:/) {
                match(line, /local-lvm:vm-[0-9]+-disk-[0-9]+/)
                disk=substr(line, RSTART, RLENGTH)

                match(line, /size=[^,]+/)
                size=substr(line, RSTART+5, RLENGTH-5)

                if (disk != "")
                    printf "local-lvm · %s", size

                print ""
            }
            else if (line ~ /\/dev\/disk\//) {
                match(line, /size=[^,]+/)
                size=substr(line, RSTART+5, RLENGTH-5)

                match(line, /\/dev\/disk\/by-id\/[^,]+/)
                path=substr(line, RSTART, RLENGTH)

                printf "%s · %s", path, size
                print ""
            }
        }
    '
}

###############################################################################
# LXC information
###############################################################################

get_lxc_ip() {

    local id="$1"
    local ip

    ip="$(pct exec "$id" -- sh -c '
        hostname -I 2>/dev/null
    ' 2>/dev/null |
        awk '{print $1}' || true)"

    [[ -n "$ip" ]] && echo "$ip" || echo "-"
}

get_lxc_mac() {

    local id="$1"

    pct config "$id" 2>/dev/null |
        awk -F',' '
            /^net[0-9]+:/ {
                for (i=1;i<=NF;i++) {
                    if ($i ~ /^hwaddr=/) {
                        sub(/^hwaddr=/,"",$i)
                        print $i
                        exit
                    }
                }
            }
        '
}

get_lxc_disks() {

    local id="$1"

    pct config "$id" 2>/dev/null |
    awk '
        /^rootfs:/ {
            line=$0

            if (line ~ /local-lvm:/) {

                match(line, /local-lvm:vm-[0-9]+-disk-[0-9]+/)
                disk=substr(line, RSTART, RLENGTH)

                match(line, /size=[^,]+/)
                size=substr(line, RSTART+5, RLENGTH-5)

                printf "local-lvm · %s", size
                print ""
            }
        }

        /^mp[0-9]+:/ {
            line=$0

            if (line ~ /local-lvm:/) {
                match(line, /local-lvm:[^,]+/)
                disk=substr(line, RSTART, RLENGTH)

                match(line, /size=[^,]+/)
                size=substr(line, RSTART+5, RLENGTH-5)

                printf "%s", disk
                print ""
            }
        }
    '
}

###############################################################################
# Backup information
###############################################################################

# Proxmox vzdump backups are normally stored under the configured
# Proxmox backup directory.
#
# We inspect common backup locations:
#
#   /var/lib/vz/dump
#   /mnt/pve/*/dump
#
# The newest backup files are returned.
#

get_backup_files() {

    local search_paths=()
    local path

    [[ -d "/var/lib/vz/dump" ]] &&
        search_paths+=("/var/lib/vz/dump")

    while IFS= read -r path; do
        [[ -n "$path" ]] &&
            search_paths+=("$path")
    done < <(
        find /mnt/pve -maxdepth 3 -type d -name dump \
            2>/dev/null
    )

    if [[ "${#search_paths[@]}" -eq 0 ]]; then
        return
    fi

    find "${search_paths[@]}" \
        -maxdepth 1 \
        -type f \
        \( \
            -name "vzdump-qemu-*" \
            -o \
            -name "vzdump-lxc-*" \
            \) \
        -printf '%T@|%TY-%Tm-%Td %TH:%TM|%s|%p\n' \
        2>/dev/null |
    sort -t'|' -k1,1nr |
    head -n "$BACKUP_COUNT"
}

format_bytes() {

    local bytes="$1"

    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "-"
        return
    fi

    if (( bytes >= 1099511627776 )); then
        awk -v b="$bytes" 'BEGIN {printf "%.1f TB", b/1099511627776}'
    elif (( bytes >= 1073741824 )); then
        awk -v b="$bytes" 'BEGIN {printf "%.1f GB", b/1073741824}'
    elif (( bytes >= 1048576 )); then
        awk -v b="$bytes" 'BEGIN {printf "%.1f MB", b/1048576}'
    elif (( bytes >= 1024 )); then
        awk -v b="$bytes" 'BEGIN {printf "%.1f KB", b/1024}'
    else
        echo "${bytes} B"
    fi
}

get_backup_status() {

    local file="$1"

    # A backup archive that exists and has a non-zero size is considered
    # present. Actual backup integrity can be checked later using
    # Proxmox's verification facilities.
    #
    # This function deliberately does not claim cryptographic integrity.

    if [[ ! -f "$file" ]]; then
        echo "${RED}|MISSING"
        return
    fi

    local size

    size="$(stat -c '%s' "$file" 2>/dev/null || echo 0)"

    if [[ "$size" -le 0 ]]; then
        echo "${RED}|EMPTY"
        return
    fi

    echo "${GREEN}|FILE OK"
}

###############################################################################
# Storage usage
###############################################################################

get_storage_summary() {

    pvesm status 2>/dev/null |
    awk '
        NR == 1 { next }

        NF >= 7 {
            name=$1
            type=$2
            status=$3
            total=$4
            used=$5
            avail=$6
            percent=$7

            printf "%s|%s|%s|%s|%s|%s|%s\n",
                name,type,status,total,used,avail,percent
        }
    '
}

format_kib() {

    local kib="$1"

    if ! [[ "$kib" =~ ^[0-9]+$ ]]; then
        echo "-"
        return
    fi

    awk -v k="$kib" '
        BEGIN {
            if (k >= 1073741824)
                printf "%.1f TB", k/1073741824
            else if (k >= 1048576)
                printf "%.1f GB", k/1048576
            else if (k >= 1024)
                printf "%.1f MB", k/1024
            else
                printf "%.0f KB", k
        }
    '
}

###############################################################################
# Physical disk report
###############################################################################

build_disk_report() {

    local output=""

    while IFS='|' read -r name model size rota tran; do

        [[ -z "$name" ]] && continue

        local status
        local status_icon
        local display_name
        local rpm=""
        local connection=""

        status="$(get_smart_status "/dev/${name}" "$tran")"

        status_icon="${status%%|*}"
        status="${status#*|}"

        display_name="$(get_disk_display_name \
            "/dev/${name}" "$model" "$tran")"

        if [[ "$tran" != "nvme" ]]; then
            rpm="$(get_disk_rpm "/dev/${name}")"
        fi

        if [[ "$tran" == "nvme" ]]; then
            connection="NVMe"
        elif [[ "$tran" == "sata" ]]; then
            connection="SATA"
        else
            connection="$tran"
        fi

        if [[ -n "$rpm" ]]; then
            output="${output}${status_icon} ${display_name}
${size} · ${rpm}
"
        else
            output="${output}${status_icon} ${display_name}
${size} · ${connection}
"
        fi

        # Intentionally do not show SMART diagnostic details in the report.
        # Only the traffic-light symbol is displayed as requested.

        output="${output}
"

    done < <(get_physical_disks)

    [[ -n "$output" ]] && echo "$output" || echo "확인할 디스크가 없습니다."
}

###############################################################################
# VM report
###############################################################################

build_vm_report() {

    local output=""
    local found=0

    while read -r vmid name status memory cores; do

        [[ -z "$vmid" ]] && continue

        found=1

        local icon="$GREEN"

        [[ "$status" != "running" ]] && icon="$RED"

        local ip
        local mac
        local disks

        ip="$(get_vm_ip "$vmid")"
        mac="$(get_vm_mac "$vmid")"
        disks="$(get_vm_disks "$vmid")"

        output="${output}${icon} VM ${vmid} · ${name}
CPU ${cores} Core · RAM $(awk -v m="$memory" 'BEGIN {printf "%.0f GB",m/1024}')
IP ${ip}
MAC ${mac:-"-"}
"

        if [[ -n "$disks" ]]; then
            while IFS= read -r disk; do
                [[ -z "$disk" ]] && continue
                output="${output}Disk: ${disk}
"
            done <<< "$disks"
        else
            output="${output}Disk: -
"
        fi

        output="${output}
"

    done < <(
        qm list 2>/dev/null |
        awk '
            NR > 1 {
                print $1, $2, $3, $4, $5
            }
        '
    )

    if [[ "$found" -eq 0 ]]; then
        echo "실행 중인 VM이 없습니다."
    else
        echo "$output"
    fi
}

###############################################################################
# LXC report
###############################################################################

build_lxc_report() {

    local output=""
    local found=0

    while read -r id status name; do

        [[ -z "$id" ]] && continue

        found=1

        local icon="$GREEN"

        [[ "$status" != "running" ]] && icon="$RED"

        local cores
        local memory
        local ip
        local mac
        local disks

        cores="$(pct config "$id" 2>/dev/null |
            awk '/^cores:/ {print $2; exit}')"

        memory="$(pct config "$id" 2>/dev/null |
            awk '/^memory:/ {print $2; exit}')"

        ip="$(get_lxc_ip "$id")"
        mac="$(get_lxc_mac "$id")"
        disks="$(get_lxc_disks "$id")"

        cores="${cores:-0}"
        memory="${memory:-0}"

        output="${output}${icon} LXC ${id} · ${name}
CPU ${cores} Core · RAM ${memory} MB
IP ${ip}
MAC ${mac:-"-"}
"

        if [[ -n "$disks" ]]; then
            while IFS= read -r disk; do
                [[ -z "$disk" ]] && continue
                output="${output}Disk: ${disk}
"
            done <<< "$disks"
        else
            output="${output}Disk: -
"
        fi

        output="${output}
"

    done < <(
        pct list 2>/dev/null |
        awk '
            NR > 1 {
                print $1, $2, $4
            }
        '
    )

    if [[ "$found" -eq 0 ]]; then
        echo "실행 중인 LXC가 없습니다."
    else
        echo "$output"
    fi
}

###############################################################################
# Backup report
###############################################################################

build_backup_report() {

    local output=""
    local found=0

    while IFS='|' read -r timestamp date size file; do

        [[ -z "$file" ]] && continue

        found=1

        local status
        local icon
        local formatted_size
        local filename

        status="$(get_backup_status "$file")"

        icon="${status%%|*}"
        status="${status#*|}"

        formatted_size="$(format_bytes "$size")"

        filename="$(basename "$file")"

        output="${output}${icon} ${date} · ${formatted_size}
${filename}
"

    done < <(get_backup_files)

    if [[ "$found" -eq 0 ]]; then
        echo "최근 Proxmox 백업을 찾지 못했습니다."
    else
        echo "$output"
    fi
}

###############################################################################
# Hardware report
###############################################################################

build_hardware_report() {

    local cpu
    local board_manufacturer
    local board_model
    local ram
    local bios
    local bios_date

    cpu="$(get_cpu_model)"
    board_manufacturer="$(get_mainboard_manufacturer)"
    board_model="$(get_mainboard_model)"
    ram="$(get_memory_total)"
    bios="$(get_bios_version)"
    bios_date="$(get_bios_date)"

    cat <<EOF
CPU: ${cpu}
Mainboard: ${board_manufacturer} ${board_model}
RAM: ${ram}
BIOS: ${bios} · ${bios_date}
EOF
}

###############################################################################
# Storage report
###############################################################################

build_storage_report() {

    local output=""

    while IFS='|' read -r name type status total used avail percent; do

        [[ -z "$name" ]] && continue

        local icon="$GREEN"

        if [[ "$status" != "active" ]]; then
            icon="$RED"
        fi

        output="${output}${icon} ${name}
$(format_kib "$used") used / $(format_kib "$total") · ${percent}
"

    done < <(get_storage_summary)

    [[ -n "$output" ]] &&
        echo "$output" ||
        echo "Proxmox storage 정보를 가져오지 못했습니다."
}

###############################################################################
# Full daily report
###############################################################################

build_daily_report() {

    local pve_version
    local manager_version
    local kernel
    local uptime

    pve_version="$(get_pve_version)"
    manager_version="$(get_pve_manager_version)"
    kernel="$(get_kernel_version)"
    uptime="$(get_uptime)"

    local cpu_cores
    cpu_cores="$(get_cpu_cores)"

    cat <<EOF
🖥️ Proxmox 서버 리포트
$(date '+%Y-%m-%d %H:%M')

━━━━━━━━━━━━━━━━━━
📌 서버 상태
━━━━━━━━━━━━━━━━━━
${GREEN} Proxmox 정상
가동 시간: ${uptime}

Proxmox VE: ${pve_version}
Manager: ${manager_version}
Kernel: ${kernel}

━━━━━━━━━━━━━━━━━━
🖥️ VM
━━━━━━━━━━━━━━━━━━
$(build_vm_report)

━━━━━━━━━━━━━━━━━━
📦 LXC
━━━━━━━━━━━━━━━━━━
$(build_lxc_report)

━━━━━━━━━━━━━━━━━━
💾 디스크
━━━━━━━━━━━━━━━━━━
$(build_disk_report)

━━━━━━━━━━━━━━━━━━
💾 Proxmox Storage
━━━━━━━━━━━━━━━━━━
$(build_storage_report)

━━━━━━━━━━━━━━━━━━
💾 최근 백업
━━━━━━━━━━━━━━━━━━
$(build_backup_report)

━━━━━━━━━━━━━━━━━━
🖥️ 서버 사양
━━━━━━━━━━━━━━━━━━
$(build_hardware_report)
EOF
}

###############################################################################
# Message splitting
###############################################################################

send_long_message() {

    local message="$1"

    # Telegram supports approximately 4096 characters per message.
    # Keep a little safety margin.

    if [[ "${#message}" -le "$TELEGRAM_MAX_LENGTH" ]]; then
        telegram_send "$message"
        return
    fi

    local remaining="$message"

    while [[ "${#remaining}" -gt "$TELEGRAM_MAX_LENGTH" ]]; do

        local chunk="${remaining:0:$TELEGRAM_MAX_LENGTH}"
        local split_position

        split_position="$(echo "$chunk" |
            awk '{
                pos=0
                for(i=1;i<=length($0);i++) {
                    if(substr($0,i,1)=="\n")
                        pos=i
                }
                print pos
            }')"

        if [[ "$split_position" -gt 0 ]]; then
            chunk="${remaining:0:$split_position}"
            remaining="${remaining:$split_position}"
        else
            remaining="${remaining:$TELEGRAM_MAX_LENGTH}"
        fi

        telegram_send "$chunk"
    done

    [[ -n "$remaining" ]] &&
        telegram_send "$remaining"
}

###############################################################################
# Test message
###############################################################################

send_test_message() {

    local hostname
    hostname="$(hostname)"

    local pve_version
    pve_version="$(get_pve_version)"

    local message

    message="🟢 Proxmox Telegram Monitor 테스트

서버: ${hostname}
Proxmox VE: ${pve_version}
시간: $(date '+%Y-%m-%d %H:%M:%S')

Telegram 연결이 정상적으로 확인되었습니다."

    send_long_message "$message"
}

###############################################################################
# Main
###############################################################################

usage() {

    cat <<EOF
Proxmox Telegram Monitor ${SCRIPT_VERSION}

Usage:

  $0 --report
      Generate and send the daily Proxmox report.

  $0 --test
      Send a Telegram connection test message.

  $0 --version
      Show script version.

  $0 --help
      Show this help.

Configuration:

  ${CONFIG_FILE}

Example:

  TELEGRAM_BOT_TOKEN="123456789:ABCDEF..."
  TELEGRAM_CHAT_ID="-1001234567890"

EOF
}

main() {

    require_root

    if ! command_exists pveversion; then
        die "This script must run on a Proxmox VE host."
    fi

    local action="${1:---help}"

    case "$action" in

        --report)

            load_config

            log "Generating Proxmox report..."

            local report
            report="$(build_daily_report)"

            send_long_message "$report"

            log "Report sent successfully."

            ;;

        --test)

            load_config

            log "Sending Telegram test message..."

            send_test_message

            log "Test message sent successfully."

            ;;

        --version)

            echo "Proxmox Telegram Monitor ${SCRIPT_VERSION}"

            ;;

        --help|-h)

            usage

            ;;

        *)

            echo "Unknown option: $action"
            echo
            usage
            exit 1

            ;;

    esac
}

main "$@"