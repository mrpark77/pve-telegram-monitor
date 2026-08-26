# Proxmox Telegram Monitor

Proxmox VE 서버의 상태와 VM/LXC 이벤트를 Telegram으로 알려주는 Bash 스크립트 모음입니다.

---

## 1. 구성

이 프로젝트는 다음 두 개의 스크립트로 구성됩니다.

### pve-telegram-event.sh

Proxmox의 실시간 이벤트를 감시합니다.

다음 이벤트가 발생하면 Telegram으로 알림을 보냅니다.

* Proxmox 호스트 시작
* Proxmox 호스트 종료
* VM 시작
* VM 종료
* LXC 시작
* LXC 종료

systemd 서비스로 등록되어 백그라운드에서 실행됩니다.

현재 버전:

```text
2.5.0
```

---

### pve-telegram-monitor.sh

Proxmox 서버의 정기 상태 리포트를 생성하여 Telegram으로 전송합니다.

systemd timer를 이용하여 사용자가 지정한 시간에 자동 실행됩니다.

설치 시 실행 시간을 입력할 수 있으며, 기본값은 오전 9시입니다.

현재 버전:

```text
1.4.0
```

리포트에는 다음 정보가 포함됩니다.

* Proxmox 호스트 상태
* Proxmox VE 버전
* Kernel 버전
* 호스트 가동 시간
* VM 정보

  * VM 이름
  * CPU Core
  * RAM
  * IP
  * MAC
  * 가상 디스크
* LXC 정보

  * LXC 이름
  * CPU Core
  * RAM
  * IP
  * MAC
  * Root disk
* 물리 디스크 SMART 상태
* Proxmox Storage 사용량
* 최근 백업 5개
* 백업 성공/실패 여부
* CPU
* 메인보드
* 물리 RAM
* BIOS 정보

---

## 2. 요구 사항

Proxmox VE 환경에서 실행하는 것을 전제로 합니다.

필요한 주요 명령은 다음과 같습니다.

* curl
* jq
* smartctl
* dmidecode
* qm
* pct
* pvesm
* pveversion
* systemd

Proxmox VE에는 대부분 기본적으로 포함되어 있습니다.

---

## 3. Telegram 설정

두 스크립트에서 공통으로 사용하는 설정 파일을 생성합니다.

설정 파일 위치:

```text
/etc/pve-telegram-monitor/config
```

디렉터리를 생성합니다.

```bash
mkdir -p /etc/pve-telegram-monitor
```

Telegram Bot Token을 입력합니다.

```bash
read -rsp "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
echo
```

Telegram Chat ID를 입력합니다.

```bash
read -rp "Telegram Chat ID: " TELEGRAM_CHAT_ID
```

설정 파일을 생성합니다.

```bash
cat > /etc/pve-telegram-monitor/config <<EOF
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
EOF
```

설정 파일 권한을 제한합니다.

```bash
chmod 600 /etc/pve-telegram-monitor/config
```

설정 파일 확인:

```bash
cat /etc/pve-telegram-monitor/config
```

**※ Bot Token은 외부에 공개하지 마십시오.**

---

# 4. pve-telegram-event.sh 설치

Proxmox Shell에서 최신 Event Monitor를 다운로드합니다.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-event.sh \
  -o /usr/local/bin/pve-telegram-event.sh

chmod +x /usr/local/bin/pve-telegram-event.sh
```

버전 확인:

```bash
/usr/local/bin/pve-telegram-event.sh --version
```

정상 결과:

```text
2.5.0
```

---

## 4-1. Event Monitor 설치

다음 명령을 실행합니다.

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

스크립트가 필요한 systemd 서비스를 자동으로 설치하고 활성화합니다.

설치되는 서비스:

```text
pve-telegram-event.service
pve-telegram-host-start.service
pve-telegram-host-stop.service
```

---

## 4-2. 이벤트 모니터 서비스 확인

```bash
systemctl status pve-telegram-event.service --no-pager -l
```

정상 상태:

```text
Active: active (running)
```

서비스 활성화 여부:

```bash
systemctl is-enabled pve-telegram-event.service
```

정상 결과:

```text
enabled
```

---

## 4-3. 호스트 시작 알림 서비스 확인

```bash
systemctl status pve-telegram-host-start.service --no-pager -l
```

이 서비스는 Proxmox 호스트 부팅 시 한 번 실행된 후 종료됩니다.

따라서 다음 상태가 정상입니다.

```text
Active: inactive (dead)
```

서비스 자체는 활성화되어 있어야 합니다.

```bash
systemctl is-enabled pve-telegram-host-start.service
```

정상 결과:

```text
enabled
```

---

## 4-4. 호스트 종료 알림

호스트 종료 시 다음 서비스가 실행됩니다.

```text
pve-telegram-host-stop.service
```

종료 과정에서는 VM/LXC 종료 이벤트가 먼저 Telegram으로 전송됩니다.

그 다음 Proxmox 호스트 종료 알림이 전송되도록 systemd 의존성을 구성합니다.

---

## 4-5. Event Monitor 제거

Event Monitor 서비스를 제거하려면 다음 명령을 사용합니다.

```bash
/usr/local/bin/pve-telegram-event.sh --uninstall
```

스크립트 자체는 삭제되지 않습니다.

필요하면 다음 명령으로 스크립트를 직접 삭제할 수 있습니다.

```bash
rm -f /usr/local/bin/pve-telegram-event.sh
```

---

# 5. pve-telegram-monitor.sh 설치

최신 Daily Monitor를 다운로드합니다.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-monitor.sh \
  -o /usr/local/bin/pve-telegram-monitor.sh

chmod +x /usr/local/bin/pve-telegram-monitor.sh
```

버전 확인:

```bash
/usr/local/bin/pve-telegram-monitor.sh --version
```

정상 결과:

```text
1.4.0
```

---

# 6. Telegram 연결 테스트

Daily Monitor가 설치되어 있다면 다음 명령으로 Telegram 연결을 테스트합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --test
```

정상적으로 Telegram 메시지가 도착하면 설정이 완료된 것입니다.

---

# 7. Daily Report 설치

Daily Monitor의 자동 실행을 설치합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

실행하면 다음과 같이 실행 시간을 입력할 수 있습니다.

```text
==========================================
 Proxmox Telegram Monitor 1.4.0
 Daily Report Timer Installation
==========================================

Daily report time
Default: 09:00

Enter report time [09:00]:
```

### 기본 시간 사용

그냥 Enter를 누르면:

```text
09:00
```

으로 설정됩니다.

### 다른 시간 사용

예를 들어:

```text
Enter report time [09:00]: 08:30
```

이라고 입력하면 매일 오전 8시 30분에 실행됩니다.

시간은 다음 형식을 사용합니다.

```text
HH:MM
```

예:

```text
07:30
08:00
08:30
09:00
18:00
23:30
```

잘못된 시간 형식을 입력하면 다시 입력해야 합니다.

---

## 7-1. 설치 과정

`--install` 명령은 다음 작업을 자동으로 수행합니다.

```text
pve-telegram-report.service 생성
        ↓
pve-telegram-report.timer 생성
        ↓
systemd daemon-reload
        ↓
timer 활성화
        ↓
자동 실행 시작
```

생성되는 파일:

```text
/etc/systemd/system/pve-telegram-report.service
/etc/systemd/system/pve-telegram-report.timer
```

사용자가 service와 timer 파일을 직접 작성할 필요는 없습니다.

---

## 7-2. Daily Report 실행 구조

Daily Monitor 자체가 실행 시간을 가지고 있는 것은 아닙니다.

실행 시간은 systemd timer가 관리합니다.

```text
pve-telegram-report.timer
        │
        │ 지정된 시간
        ▼
pve-telegram-report.service
        │
        ▼
pve-telegram-monitor.sh --report
        │
        ▼
Proxmox 상태 수집
        │
        ▼
Telegram 전송
```

따라서 설치할 때 지정한 시간은 systemd timer에 저장됩니다.

systemd의 `OnCalendar=`는 실제 시각을 기준으로 timer를 실행합니다. `Persistent=true`를 사용하면 시스템이 꺼져 실행을 놓친 경우 재부팅 후 누락된 실행을 보완할 수 있습니다.

---

# 8. Daily Report 수동 테스트

예약 시간을 기다리지 않고 리포트를 바로 전송할 수 있습니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --report
```

Telegram으로 다음과 같은 Proxmox 서버 리포트가 도착하면 정상입니다.

```text
🖥️ Proxmox 서버 리포트
```

---

# 9. Daily Report Timer 확인

Timer 상태를 확인합니다.

```bash
systemctl status pve-telegram-report.timer --no-pager
```

활성화 여부를 확인합니다.

```bash
systemctl is-enabled pve-telegram-report.timer
```

정상 결과:

```text
enabled
```

다음 실행 시간을 확인합니다.

```bash
systemctl list-timers --all | grep pve-telegram-report
```

---

# 10. Daily Report 실행 시간 변경

이미 설치한 Daily Report의 실행 시간을 변경하려면 다시 설치 명령을 실행합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

새로운 실행 시간을 입력합니다.

예:

```text
Enter report time [09:00]: 08:30
```

기존 timer 설정은 새로운 시간으로 변경됩니다.

Telegram 설정 파일은 변경되지 않습니다.

---

# 11. Daily Report 제거

Daily Report의 자동 실행을 제거하려면:

```bash
/usr/local/bin/pve-telegram-monitor.sh --uninstall
```

다음 systemd 파일이 제거됩니다.

```text
pve-telegram-report.service
pve-telegram-report.timer
```

Telegram 설정 파일은 삭제하지 않습니다.

따라서 다음 파일은 그대로 유지됩니다.

```text
/etc/pve-telegram-monitor/config
```

Daily Report를 다시 설치할 경우 기존 Telegram 설정을 그대로 사용할 수 있습니다.

---

# 12. 설치된 서비스 확인

다음 명령으로 관련 systemd 서비스를 확인할 수 있습니다.

```bash
systemctl list-unit-files | grep pve-telegram
```

정상적으로 설치되면 다음과 같은 서비스가 표시됩니다.

```text
pve-telegram-event.service
pve-telegram-host-start.service
pve-telegram-host-stop.service
pve-telegram-report.service
pve-telegram-report.timer
```

---

# 13. 이벤트 로그 확인

실시간 이벤트 모니터 로그:

```bash
journalctl -u pve-telegram-event.service -f
```

최근 이벤트 로그:

```bash
journalctl -u pve-telegram-event.service --no-pager
```

호스트 시작 로그:

```bash
journalctl -u pve-telegram-host-start.service --no-pager
```

호스트 종료 로그:

```bash
journalctl -u pve-telegram-host-stop.service --no-pager
```

Daily Report 로그:

```bash
journalctl -u pve-telegram-report.service --no-pager
```

---

# 14. 시스템 재부팅 테스트

모든 설정이 완료되었다면 실제 재부팅 테스트를 할 수 있습니다.

```bash
reboot
```

정상적인 경우 Telegram 알림 순서는 다음과 같습니다.

```text
🔴 Proxmox VM 종료
🔴 Proxmox LXC 종료
🔴 Proxmox 호스트 종료

🟢 Proxmox 호스트 시작
🟢 Proxmox VM 시작
🟢 Proxmox LXC 시작
```

VM/LXC의 종료 및 시작 시간은 실제 게스트 상태에 따라 달라질 수 있습니다.

---

# 15. 스크립트 업데이트

GitHub의 최신 버전으로 업데이트하려면 해당 스크립트를 다시 다운로드합니다.

## Event Monitor

```bash
curl -fsSL \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-event.sh \
  -o /usr/local/bin/pve-telegram-event.sh

chmod +x /usr/local/bin/pve-telegram-event.sh

/usr/local/bin/pve-telegram-event.sh --version
```

Event Monitor의 systemd 설정까지 변경된 버전이라면:

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

을 실행하여 서비스를 다시 설치합니다.

---

## Daily Monitor

```bash
curl -fsSL \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-monitor.sh \
  -o /usr/local/bin/pve-telegram-monitor.sh

chmod +x /usr/local/bin/pve-telegram-monitor.sh

/usr/local/bin/pve-telegram-monitor.sh --version
```

Daily Monitor의 설치 기능은 기존 timer 설정을 다시 생성합니다.

따라서 설치 시간을 변경하거나 timer 설정을 갱신하려면:

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

을 실행합니다.

---

# 16. 주요 명령어 요약

## Event Monitor

버전 확인:

```bash
/usr/local/bin/pve-telegram-event.sh --version
```

설치:

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

제거:

```bash
/usr/local/bin/pve-telegram-event.sh --uninstall
```

상태 확인:

```bash
systemctl status pve-telegram-event.service --no-pager -l
```

이벤트 로그:

```bash
journalctl -u pve-telegram-event.service -f
```

---

## Daily Monitor

버전 확인:

```bash
/usr/local/bin/pve-telegram-monitor.sh --version
```

Telegram 연결 테스트:

```bash
/usr/local/bin/pve-telegram-monitor.sh --test
```

Daily Report 즉시 실행:

```bash
/usr/local/bin/pve-telegram-monitor.sh --report
```

Daily Report 설치:

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

Daily Report 제거:

```bash
/usr/local/bin/pve-telegram-monitor.sh --uninstall
```

Timer 상태:

```bash
systemctl status pve-telegram-report.timer --no-pager
```

다음 실행 시간:

```bash
systemctl list-timers --all | grep pve-telegram-report
```

Daily Report 로그:

```bash
journalctl -u pve-telegram-report.service --no-pager
```

---

# 17. 현재 구성 요약

```text
Proxmox VE
│
├─ pve-telegram-event.sh
│  │
│  ├─ VM 시작/종료 감시
│  ├─ LXC 시작/종료 감시
│  ├─ 호스트 시작 알림
│  └─ 호스트 종료 알림
│
│  ├─ pve-telegram-event.service
│  ├─ pve-telegram-host-start.service
│  └─ pve-telegram-host-stop.service
│
├─ pve-telegram-monitor.sh
│  │
│  ├─ 지정된 시간에 자동 실행
│  ├─ 호스트 상태
│  ├─ VM/LXC 정보
│  ├─ 디스크 SMART
│  ├─ Proxmox Storage
│  ├─ 최근 백업 5개
│  └─ 하드웨어 정보
│
│  ├─ pve-telegram-report.service
│  └─ pve-telegram-report.timer
│
└─ /etc/pve-telegram-monitor/config
   │
   ├─ TELEGRAM_BOT_TOKEN
   └─ TELEGRAM_CHAT_ID
```

---

# 18. 설치 순서 요약

처음 설치하는 경우 다음 순서로 진행합니다.

### 1. Telegram 설정

```bash
mkdir -p /etc/pve-telegram-monitor

read -rsp "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
echo

read -rp "Telegram Chat ID: " TELEGRAM_CHAT_ID

cat > /etc/pve-telegram-monitor/config <<EOF
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
EOF

chmod 600 /etc/pve-telegram-monitor/config
```

### 2. Event Monitor 다운로드

```bash
curl -fsSL \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-event.sh \
  -o /usr/local/bin/pve-telegram-event.sh

chmod +x /usr/local/bin/pve-telegram-event.sh
```

### 3. Event Monitor 설치

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

### 4. Daily Monitor 다운로드

```bash
curl -fsSL \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-monitor.sh \
  -o /usr/local/bin/pve-telegram-monitor.sh

chmod +x /usr/local/bin/pve-telegram-monitor.sh
```

### 5. Telegram 연결 테스트

```bash
/usr/local/bin/pve-telegram-monitor.sh --test
```

### 6. Daily Monitor 설치

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

설치 과정에서 원하는 Daily Report 실행 시간을 입력합니다.

그냥 Enter를 누르면 오전 9시로 설정됩니다.

### 7. Daily Report 즉시 테스트

```bash
/usr/local/bin/pve-telegram-monitor.sh --report
```

---

# 19. License

개인적인 Proxmox 관리 및 모니터링 용도로 사용할 수 있습니다.
