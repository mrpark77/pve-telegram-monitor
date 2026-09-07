# Proxmox Telegram Monitor

Proxmox VE 서버의 상태와 VM/LXC 이벤트를 Telegram으로 알려주는 Bash 스크립트 모음입니다.

## ✨ 주요 기능

* 🟢 **Event Monitor**

  * Proxmox 호스트 시작/종료
  * VM 시작/종료
  * LXC 시작/종료
* 📊 **Daily Report**

  * Proxmox 서버 상태
  * VM/LXC 정보
  * CPU / RAM / Storage
  * 디스크 SMART 상태
  * 하드웨어 정보
  * 최근 백업 정보
* 📈 **Activity Report**

  * 최근 24시간 VM/LXC 사용량
  * CPU / RAM / Read / Write 사용량
  * 2시간 단위 사용량 그래프
  * CPU / Disk 사용량 급증 감지
* 💾 **SMART Monitor**

  * 물리 디스크 SMART 상태 확인
  * 상태별 경고 기준 제공
* ⚙️ **systemd 자동 실행**

  * Daily Report와 Activity Report를 각각 독립적인 시간으로 설정 가능

---

## 🚀 빠른 시작

### 1. 스크립트 다운로드

```bash
wget -O /usr/local/bin/pve-telegram-monitor.sh \
  "https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/refs/heads/main/pve-telegram-monitor.sh?$(date +%s)"

chmod +x /usr/local/bin/pve-telegram-monitor.sh
```

### 2. 버전 확인

```bash
/usr/local/bin/pve-telegram-monitor.sh --version
```

### 3. 설치

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

설치 과정에서 다음 항목을 입력합니다.

* Telegram Bot Token
* Telegram Chat ID
* Daily Report 실행 시간
* Activity Report 실행 시간

실행 시간은 `HH:MM` 형식이며, 입력하지 않으면 기본값은 `09:00`입니다.

### 4. Telegram 연결 테스트

```bash
/usr/local/bin/pve-telegram-monitor.sh --test
```

### 5. Event Monitor 설치

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

---

# 📋 명령어 요약

| 기능              | 명령                |
| --------------- | ----------------- |
| 버전 확인           | `--version`       |
| 도움말             | `--help`          |
| 설치              | `--install`       |
| 제거              | `--uninstall`     |
| Telegram 테스트    | `--test`          |
| Daily Report    | `--report`        |
| Activity Report | `--activity`      |
| Activity 테스트    | `--activity-test` |
| SMART 상태        | `--smart`         |

---

# 📊 Daily Report

Daily Report는 Proxmox 서버의 전체적인 상태를 정기적으로 Telegram으로 전송합니다.

포함되는 주요 정보:

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
  * Root Disk
* 💾 물리 디스크 SMART 상태
* 📦 Proxmox Storage 사용량
* 💿 최근 백업 5개
  * 백업 성공/실패 여부
* 시스템 SPEC 요약

  * CPU 정보
  * 메인보드 정보
  * 물리 RAM 정보
  * BIOS 정보

Daily Report는 설치 과정에서 설정한 시간에 systemd timer로 자동 실행됩니다.

---

# 📈 Activity Report

Activity Report는 **최근 24시간 동안의 VM/LXC 사용량을 분석하여 Telegram으로 전송**합니다.

각 VM/LXC마다 독립된 Telegram 메시지를 전송합니다.

예:

```text
📈 LXC 101 · docker (09/06 08:30 ~ 09/07 08:30)
-----------------------
📊 24시간 요약
CPU (평균 1.0% · 최대 5.0%)
▁▁▁▁▁▁▁▁▁▁▁▁
RAM (평균 76.4% · 최대 98.4%)
▆▆▆▆▆▆▆▆▆▇██
Read (평균 33.3 KB/s · 최대 32.3 MB/s)
▁▁▁▁▁▁▁▁▁▁▁▁
Write (평균 7.1 KB/s · 최대 398.7 KB/s)
▁▁▁▁▁▁▁▁▁▁▁▁

-----------------------
⚠️ 특이사항

🕐 11:44~11:45 Read, Write 급증
Read 평균 2.9 MB/s · 최대 2.9 MB/s
Write 평균 1.5 MB/s · 최대 1.5 MB/s
```

특이사항이 없는 경우:

```text
ℹ️ 특이사항

특이사항 없음
```

## 📊 Activity Report 그래프

최근 24시간을 **2시간 단위 12개 구간**으로 나누어 평균 사용량을 표시합니다.

수집 대상:

* CPU
* RAM
* Read
* Write

급격한 사용량 증가가 감지되면 특이사항으로 표시합니다.

### Activity Report 수동 실행

```bash
/usr/local/bin/pve-telegram-monitor.sh --activity
```

### Activity Report Shell 테스트

Telegram으로 전송하지 않고 결과만 확인하려면:

```bash
/usr/local/bin/pve-telegram-monitor.sh --activity-test
```

---

# ⚙️ 설치

상세 설치 과정은 아래 내용을 참고하세요.

<details>
<summary>📥 Daily Report / Activity Report 설치</summary>

## 설치 명령

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

설치 과정에서 다음 항목을 입력합니다.

### Telegram Bot Token

Telegram Bot의 Token을 입력합니다.

### Telegram Chat ID

알림을 받을 Telegram Chat ID를 입력합니다.

### Daily Report 시간

예:

```text
매일 실행할 리포트 시간을 입력하세요.
예: 09:00
실행 시간 [09:00]:
```

아무것도 입력하지 않고 Enter를 누르면 `09:00`이 사용됩니다.

원하는 시간을 직접 입력할 수도 있습니다.

```text
08:30
```

### Activity Report 시간

예:

```text
매일 실행할 활동 리포트 시간을 입력하세요.
최근 24시간 VM/LXC 사용량 이력을 전송합니다.
예: 21:00
활동 리포트 시간 [09:00]:
```

아무것도 입력하지 않고 Enter를 누르면 `09:00`이 사용됩니다.

Daily Report와 Activity Report는 서로 다른 시간을 지정할 수 있습니다.

예:

```text
Daily Report    : 09:00
Activity Report : 21:00
```

두 시간을 동일하게 설정하는 것도 가능합니다.

설치가 완료되면 다음 systemd unit이 생성됩니다.

```text
pve-telegram-report.service
pve-telegram-report.timer

pve-telegram-activity.service
pve-telegram-activity.timer
```

설정 파일:

```text
/etc/pve-telegram-monitor/config
```

설정 파일에는 다음 정보가 저장됩니다.

```text
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
```

설정 파일 권한은 `600`으로 저장됩니다.

</details>

---

# 🔄 설치된 Timer 확인

현재 등록된 Telegram 관련 Timer를 확인합니다.

<details>
<summary>설치된 Timer 및 활성화 여부 확인</summary>

```bash
systemctl list-timers --all | grep -Ei 'pve-telegram'
```

예:

```text
pve-telegram-report.timer
pve-telegram-activity.timer
```

## Daily Report Timer 상태

```bash
systemctl status pve-telegram-report.timer --no-pager
```

## Activity Report Timer 상태

```bash
systemctl status pve-telegram-activity.timer --no-pager
```

## Timer 활성화 여부

```bash
systemctl is-enabled pve-telegram-report.timer
systemctl is-enabled pve-telegram-activity.timer
```

정상적인 경우:

```text
enabled
```
</details>

---

# 🧪 수동 테스트

텔레그램 메신저 연동, 리포트 즉시 전송 등을 수행할 수 있습니다. 

<details>
<summary>텔레그램 연동 및 리포트 테스트</summary>

## Telegram 연결 테스트

```bash
/usr/local/bin/pve-telegram-monitor.sh --test
```

## Daily Report 즉시 전송

```bash
/usr/local/bin/pve-telegram-monitor.sh --report
```

## Activity Report 즉시 전송

```bash
/usr/local/bin/pve-telegram-monitor.sh --activity
```

## Activity Report Shell 테스트

```bash
/usr/local/bin/pve-telegram-monitor.sh --activity-test
```
</details>

---

# ⏰ 실행 시간 변경

Daily Report와 Activity Report의 실행 시간을 변경하려면 다시 설치합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

설치 과정에서 새로운 시간을 입력합니다.

예:

```text
실행 시간 [09:00]: 08:30
활동 리포트 시간 [09:00]: 21:00
```

설치가 완료되면 기존 Timer 설정이 새로운 시간으로 변경됩니다.

> ⚠️ `--install`을 다시 실행하면 Telegram Bot Token과 Chat ID를 다시 입력해야 합니다.

---

# 🗑️ 제거

<details>
<summary>🗑️ Daily Report / Activity Report 제거</summary>

다음 명령으로 Daily Report와 Activity Report를 함께 제거합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --uninstall
```

다음 systemd unit이 제거됩니다.

```text
pve-telegram-report.service
pve-telegram-report.timer

pve-telegram-activity.service
pve-telegram-activity.timer
```

또한 Telegram 설정 파일과 설정 디렉터리도 삭제됩니다.

```text
/etc/pve-telegram-monitor/
```

</details>

---

# 📡 Event Monitor

Event Monitor는 Proxmox에서 발생하는 실시간 이벤트를 감시합니다.

감시 대상:

* 🟢 Proxmox 호스트 시작
* 🔴 Proxmox 호스트 종료
* 🟢 VM 시작
* 🔴 VM 종료
* 🟢 LXC 시작
* 🔴 LXC 종료

Event Monitor는 systemd 서비스로 실행됩니다.

---

# 📥 Event Monitor 설치

<details>
<summary>📡 Event Monitor 상세 설치</summary>

## 스크립트 다운로드

```bash
wget -O /usr/local/bin/pve-telegram-event.sh \
  "https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/refs/heads/main/pve-telegram-event.sh?$(date +%s)"

chmod +x /usr/local/bin/pve-telegram-event.sh
```

## 버전 확인

```bash
/usr/local/bin/pve-telegram-event.sh --version
```

## 설치

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

설치되는 서비스:

```text
pve-telegram-event.service
pve-telegram-host-start.service
pve-telegram-host-stop.service
```

## 상태 확인

```bash
systemctl status pve-telegram-event.service --no-pager -l
```

정상적인 경우:

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

### 호스트 시작 서비스

```bash
systemctl status pve-telegram-host-start.service --no-pager -l
```

이 서비스는 부팅 시 한 번 실행된 후 종료됩니다.

따라서 다음 상태가 정상입니다.

```text
Active: inactive (dead)
```

활성화 여부:

```bash
systemctl is-enabled pve-telegram-host-start.service
```

결과:

```text
enabled
```

### 호스트 종료 서비스

호스트 종료 과정에서는 다음 서비스가 실행됩니다.

```text
pve-telegram-host-stop.service
```

VM/LXC 종료 이벤트가 먼저 Telegram으로 전송되고, 이후 Proxmox 호스트 종료 알림이 전송되도록 systemd 의존성이 구성됩니다.

## Event Monitor 테스트

```bash
/usr/local/bin/pve-telegram-event.sh --test
```

</details>

---

# 🗑️ Event Monitor 제거

<details>
<summary>🗑️ Event Monitor 제거 방법</summary>

```bash
/usr/local/bin/pve-telegram-event.sh --uninstall
```

Event Monitor 관련 systemd 서비스를 제거합니다.

Telegram 설정 파일은 삭제하지 않습니다.

</details>

---

# 💾 SMART Monitor

Proxmox 호스트에서 `--smart` 옵션을 사용하면 현재 인식된 저장장치의 SMART 상태를 확인할 수 있습니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --smart
```

## SMART 상태 기준

### 🟢 Green — Normal

정상적인 상태입니다.

### 🟠 Orange — Warning

다음 항목이 하나라도 0보다 큰 경우 경고 상태입니다.

```text
Reallocated Sector Count > 0
UDMA CRC Error Count > 0
```

### 🔴 Red — Danger

다음 항목 중 하나라도 해당하면 위험 상태입니다.

```text
SMART 읽기 실패
Current Pending Sector > 0
Offline Uncorrectable > 0
Reported Uncorrectable > 0
NVMe Critical Warning != 0x00
NVMe Media and Data Integrity Errors > 0
```

---

# 🔍 SMART 규칙 확인

```bash
/usr/local/bin/pve-telegram-monitor.sh --smart
```

실행 결과에는 현재 감지된 저장장치와 SMART 상태가 표시됩니다.

---

# 📝 로그 확인

<details>
<summary>📜 systemd 로그 확인</summary>

## Event Monitor 실시간 로그

```bash
journalctl -u pve-telegram-event.service -f
```

## Event Monitor 최근 로그

```bash
journalctl -u pve-telegram-event.service --no-pager
```

## 호스트 시작 로그

```bash
journalctl -u pve-telegram-host-start.service --no-pager
```

## 호스트 종료 로그

```bash
journalctl -u pve-telegram-host-stop.service --no-pager
```

## Daily Report 로그

```bash
journalctl -u pve-telegram-report.service --no-pager
```

## Activity Report 로그

```bash
journalctl -u pve-telegram-activity.service --no-pager
```

</details>

---

# 🔄 스크립트 업데이트

<details>
<summary>🔄 최신 버전으로 업데이트</summary>

## Daily Report / Activity Report

GitHub의 최신 버전을 다운로드합니다.

```bash
wget -O /usr/local/bin/pve-telegram-monitor.sh \
  "https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/refs/heads/main/pve-telegram-monitor.sh?$(date +%s)"

chmod +x /usr/local/bin/pve-telegram-monitor.sh
```

버전을 확인합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --version
```

현재 설치된 systemd Timer는 기존 설정을 유지합니다.

실행 시간을 변경하려는 경우에는 다시 `--install`을 실행합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

> ⚠️ `--install`을 다시 실행하면 Telegram Bot Token과 Chat ID를 다시 입력해야 합니다.

## Event Monitor

```bash
wget -O /usr/local/bin/pve-telegram-event.sh \
  "https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/refs/heads/main/pve-telegram-event.sh?$(date +%s)"

chmod +x /usr/local/bin/pve-telegram-event.sh
```

버전 확인:

```bash
/usr/local/bin/pve-telegram-event.sh --version
```

서비스를 최신 스크립트 기준으로 다시 설치하려면:

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

</details>

---

# 🔎 설치된 서비스 확인

현재 Proxmox Telegram Monitor 관련 systemd unit을 확인합니다.

```bash
systemctl list-unit-files | grep -Ei 'pve-telegram'
```

정상적으로 설치된 경우 다음과 같은 항목이 표시됩니다.

```text
pve-telegram-activity.service
pve-telegram-activity.timer
pve-telegram-event.service
pve-telegram-host-start.service
pve-telegram-host-stop.service
pve-telegram-report.service
pve-telegram-report.timer
```

---

# 🔁 시스템 재부팅 테스트

모든 설정이 완료되었다면 실제 재부팅 테스트를 할 수 있습니다.

```bash
reboot
```

정상적인 경우 Telegram 알림은 대략 다음과 같은 흐름으로 발생합니다.

```text
🔴 Proxmox VM/LXC 종료
🔴 Proxmox 호스트 종료

🟢 Proxmox 호스트 시작
🟢 Proxmox VM/LXC 시작
```

실제 알림 순서와 시점은 VM/LXC의 종료 및 시작 상태에 따라 달라질 수 있습니다.

---

# 🧰 주요 명령어

<details>
<summary>🧰 전체 명령어 보기</summary>

## pve-telegram-monitor.sh

### 도움말

```bash
/usr/local/bin/pve-telegram-monitor.sh --help
```

### 버전

```bash
/usr/local/bin/pve-telegram-monitor.sh --version
```

### 설치

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

### 제거

```bash
/usr/local/bin/pve-telegram-monitor.sh --uninstall
```

### Telegram 연결 테스트

```bash
/usr/local/bin/pve-telegram-monitor.sh --test
```

### Daily Report

```bash
/usr/local/bin/pve-telegram-monitor.sh --report
```

### Activity Report

```bash
/usr/local/bin/pve-telegram-monitor.sh --activity
```

### Activity Report Shell 테스트

```bash
/usr/local/bin/pve-telegram-monitor.sh --activity-test
```

### SMART 상태

```bash
/usr/local/bin/pve-telegram-monitor.sh --smart
```

---

## pve-telegram-event.sh

### 도움말

```bash
/usr/local/bin/pve-telegram-event.sh --help
```

### 버전

```bash
/usr/local/bin/pve-telegram-event.sh --version
```

### 설치

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

### 제거

```bash
/usr/local/bin/pve-telegram-event.sh --uninstall
```

### Telegram 테스트

```bash
/usr/local/bin/pve-telegram-event.sh --test
```

</details>

---

# 🗂️ 파일 및 서비스 구성

```text
Proxmox VE
│
├─ pve-telegram-event.sh
│  │
│  ├─ VM 시작/종료 감시
│  ├─ LXC 시작/종료 감시
│  ├─ 호스트 시작 알림
│  ├─ 호스트 종료 알림
│  │
│  └─ systemd
│     ├─ pve-telegram-event.service
│     ├─ pve-telegram-host-start.service
│     └─ pve-telegram-host-stop.service
│
├─ pve-telegram-monitor.sh
│  │
│  ├─ Daily Report
│  ├─ Activity Report
│  ├─ Telegram 연결 테스트
│  ├─ SMART Monitor
│  │
│  └─ systemd
│     ├─ pve-telegram-report.service
│     ├─ pve-telegram-report.timer
│     ├─ pve-telegram-activity.service
│     └─ pve-telegram-activity.timer
│
└─ /etc/pve-telegram-monitor/
   └─ config
      ├─ TELEGRAM_BOT_TOKEN
      └─ TELEGRAM_CHAT_ID
```

---

# 📌 현재 버전

```text
Proxmox Telegram Monitor : 1.6.4
```

주요 구성:

```text
Event Monitor
Daily Report
Activity Report
SMART Monitor
Telegram Test
systemd Timer
```

---

# 📄 License

개인적인 Proxmox 관리 및 모니터링 용도로 사용할 수 있습니다.
