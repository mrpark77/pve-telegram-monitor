# Proxmox Telegram Monitor

Proxmox VE 서버의 상태와 VM/LXC 이벤트를 Telegram으로 알려주는 Bash 스크립트 모음입니다.

---

## 1. 구성

이 프로젝트는 다음 두 개의 스크립트로 구성됩니다.

### Event Monitor (pve-telegram-event.sh)

Proxmox의 실시간 이벤트를 감시합니다.

다음 이벤트가 발생하면 Telegram으로 알림을 보냅니다.

* Proxmox 호스트 시작
* Proxmox 호스트 종료
* VM 시작
* VM 종료
* LXC 시작
* LXC 종료

systemd 서비스로 등록되어 백그라운드에서 실행됩니다.

### Daily Report (pve-telegram-monitor.sh)

Proxmox 서버의 정기 상태 리포트를 생성하여 Telegram으로 전송합니다.

실행 시간은 설치 과정에서 직접 설정할 수 있습니다.

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

## 3. GitHub에서 Event Monitor 다운로드

Proxmox Shell에서 다음 명령을 실행합니다.

```bash
wget -O /usr/local/bin/pve-telegram-event.sh \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-event.sh

chmod +x /usr/local/bin/pve-telegram-event.sh
```

버전을 확인합니다.

```bash
/usr/local/bin/pve-telegram-event.sh --version
```

예:

```text
2.5.0
```

---

## 4. GitHub에서 Daily Report 다운로드

다음 명령을 실행합니다.

```bash
wget -O /usr/local/bin/pve-telegram-monitor.sh \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-monitor.sh

chmod +x /usr/local/bin/pve-telegram-monitor.sh
```

버전을 확인합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --version
```

예:

```text
1.4.0
```

---

## 5. Daily Report 설치

Daily Report는 systemd service와 timer를 이용하여 정기적으로 실행됩니다.

다음 명령으로 설치합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

설치 과정에서 텔레그램 봇/채팅방 설정과 실행 시간을 입력합니다.
설치 과정에서 다음 항목을 입력합니다.

* Telegram Bot Token (입력한 Token은 화면에 표시되지 않습니다.)
* Telegram Chat ID
* Daily Report 실행 시간

Bot Token과 Chat ID는 다음 설정 파일에 저장됩니다.
```
/etc/pve-telegram-monitor/config
```
Bot Token이 포함된 설정 파일은 600 권한으로 저장됩니다.

Daily Report 실행 일정은 설치 과정에서 입력한 시간으로 설정됩니다.

예:

```text
Enter report time (HH:MM) [09:00]:
```

기본값을 사용하려면 아무것도 입력하지 않고 Enter를 누릅니다.

```text
09:00
```

원하는 시간을 직접 입력할 수도 있습니다.

예:

```text
07:30
```

설치가 완료되면 다음 systemd unit이 생성됩니다.

```text
pve-telegram-report.service
pve-telegram-report.timer
```

Timer는 설정한 시간에 Daily Report를 실행합니다.

---

## 6. Telegram 연결 테스트

Daily Report가 설치되어 있다면 다음 명령으로 Telegram 연결을 테스트할 수 있습니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --test
```

Telegram으로 테스트 메시지가 도착하면 연결 설정이 완료된 것입니다.

---

## 7. Daily Report Timer 확인

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

## 8. Daily Report 수동 테스트

예약된 실행 시간을 기다리지 않고 리포트를 즉시 전송할 수 있습니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --report
```

Telegram으로 Proxmox 서버 리포트가 도착하면 정상입니다.

---

## 9. Daily Report 실행 시간 변경

설정된 실행 시간을 변경하려면 Daily Report를 다시 설치합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

새로운 실행 시간을 입력하면 기존 timer 설정이 업데이트됩니다.

예:

```text
Enter report time (HH:MM) [09:00]: 08:30
```

설치가 완료된 후 다음 명령으로 변경된 시간을 확인할 수 있습니다.

```bash
systemctl list-timers --all | grep pve-telegram-report
```

---

## 10. Event Monitor 설치

실시간 VM/LXC 및 호스트 이벤트 감시 서비스를 설치합니다.

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

설치 과정에서 필요한 systemd 서비스가 자동으로 등록됩니다.

설치되는 서비스:

```text
pve-telegram-event.service
pve-telegram-host-start.service
pve-telegram-host-stop.service
```

### Event Monitor 설치 확인

```bash
systemctl status pve-telegram-event.service --no-pager -l
```

정상적인 경우 다음과 같이 표시됩니다.

```text
Active: active (running)
```

서비스 활성화 여부를 확인합니다.

```bash
systemctl is-enabled pve-telegram-event.service
```

결과:

```text
enabled
```

### 호스트 시작 알림 서비스 확인

```bash
systemctl status pve-telegram-host-start.service --no-pager -l
```

이 서비스는 부팅 시 한 번 실행된 후 종료됩니다.

따라서 다음 상태가 정상입니다.

```text
Active: inactive (dead)
```

서비스 활성화 여부:

```bash
systemctl is-enabled pve-telegram-host-start.service
```

결과:

```text
enabled
```

### 호스트 종료 알림

호스트 종료 과정에서는 다음 서비스가 실행됩니다.

```text
pve-telegram-host-stop.service
```

종료 과정에서 VM/LXC 종료 이벤트가 먼저 Telegram으로 전송됩니다.

그 다음 Proxmox 호스트 종료 알림이 전송되도록 systemd 의존성이 구성됩니다.

### Event Monitor Telegram 테스트

```bash
/usr/local/bin/pve-telegram-event.sh --test
```
Telegram으로 이벤트 모니터 테스트 메시지가 도착하면 정상입니다.

---

## 11. Event Monitor 제거

Event Monitor와 관련된 systemd 서비스를 제거하려면 다음 명령을 실행합니다.

```bash
/usr/local/bin/pve-telegram-event.sh --uninstall
```

Event Monitor에 의해 설치된 systemd 서비스가 제거됩니다.

Telegram 설정 파일은 삭제되지 않습니다.

---

## 12. Daily Report 제거

Daily Report service와 timer를 제거하려면 다음 명령을 실행합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --uninstall
```

다음 systemd unit이 제거됩니다.

```text
pve-telegram-report.service
pve-telegram-report.timer
```

Telegram 설정 파일도 함께 삭제됩니다.

설정 파일:

```text
/etc/pve-telegram-monitor/config
```

---

## 13. 설치된 서비스 확인

다음 명령으로 관련 systemd unit을 확인할 수 있습니다.

```bash
systemctl list-unit-files | grep pve-telegram
```

정상적으로 설치된 경우 다음과 같은 항목이 표시됩니다.

```text
pve-telegram-event.service
pve-telegram-host-start.service
pve-telegram-host-stop.service
pve-telegram-report.service
pve-telegram-report.timer
```

---

## 14. 이벤트 로그 확인

### 실시간 이벤트 모니터 로그

```bash
journalctl -u pve-telegram-event.service -f
```

### 최근 이벤트 로그

```bash
journalctl -u pve-telegram-event.service --no-pager
```

### 호스트 시작 로그

```bash
journalctl -u pve-telegram-host-start.service --no-pager
```

### 호스트 종료 로그

```bash
journalctl -u pve-telegram-host-stop.service --no-pager
```

### Daily Report 로그

```bash
journalctl -u pve-telegram-report.service --no-pager
```

## SMART 저장장치 상태 확인

Proxmox 호스트에서 `--smart` 옵션을 사용하면 현재 인식된 저장장치의
SMART 상태를 확인할 수 있습니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --smart
```

---

## 15. 시스템 재부팅 테스트

모든 설정이 완료되었다면 실제 재부팅 테스트를 할 수 있습니다.

```bash
reboot
```

정상적인 경우 Telegram 알림 순서는 다음과 같습니다.

```text
🔴 Proxmox VM/LXC 종료
🔴 Proxmox 호스트 종료

🟢 Proxmox 호스트 시작
🟢 Proxmox VM/LXC 시작
```

실제 알림 순서와 시점은 VM/LXC 종료 및 시작 상태에 따라 달라질 수 있습니다.

---

## 16. 스크립트 업데이트

GitHub의 최신 버전으로 스크립트를 업데이트하려면 해당 파일을 다시 다운로드합니다.
앞서 사용했던 최초 스크립트 다운로드 코드와 같은 코드를 입력하여 업데이트 스크립트를 다운로드 합니다.

### Event Monitor

```bash
wget -O /usr/local/bin/pve-telegram-event.sh \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-event.sh

chmod +x /usr/local/bin/pve-telegram-event.sh

/usr/local/bin/pve-telegram-event.sh --install
```

`--install`을 실행하면 Event Monitor 서비스가 최신 스크립트를 기준으로 다시 설치됩니다.

### Daily Report

```bash
wget -O /usr/local/bin/pve-telegram-monitor.sh \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-monitor.sh

chmod +x /usr/local/bin/pve-telegram-monitor.sh
```

Daily Report의 기존 실행 시간은 systemd timer에 저장되어 있으므로, 스크립트 업데이트만으로 실행 시간이 변경되지는 않습니다.

실행 시간을 변경하려면 다음 명령을 실행합니다.
--install을 다시 실행하면 Telegram Bot Token과 Chat ID를 다시 입력해야 합니다.

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

---

## 17. 주요 명령어 요약

### Event Monitor 버전 확인

```bash
/usr/local/bin/pve-telegram-event.sh --version
```

### Event Monitor 설치

```bash
/usr/local/bin/pve-telegram-event.sh --install
```

### Event Monitor 제거

```bash
/usr/local/bin/pve-telegram-event.sh --uninstall
```

### Telegram 연결 테스트

```bash
/usr/local/bin/pve-telegram-monitor.sh --test
```

### Daily Report 버전 확인

```bash
/usr/local/bin/pve-telegram-monitor.sh --version
```

### Daily Report 설치

```bash
/usr/local/bin/pve-telegram-monitor.sh --install
```

### Daily Report 제거

```bash
/usr/local/bin/pve-telegram-monitor.sh --uninstall
```

### Daily Report 즉시 실행

```bash
/usr/local/bin/pve-telegram-monitor.sh --report
```

### Event Monitor 상태

```bash
systemctl status pve-telegram-event.service --no-pager -l
```

### Daily Report Timer 상태

```bash
systemctl status pve-telegram-report.timer --no-pager
```

### SMART 저장장치 상태 확인

```bash
/usr/local/bin/pve-telegram-monitor.sh --smart\
```

### 이벤트 로그

```bash
journalctl -u pve-telegram-event.service -f
```


---

## 18. 현재 구성 요약

```text
Proxmox VE
│
├─ pve-telegram-event.sh
│  │
│  ├─ VM 시작/종료/재부팅 감시
│  ├─ LXC 시작/종료/재부팅 감시
│  ├─ 호스트 시작 알림
│  ├─ 호스트 종료 알림
│  ├─ 호스트 재부팅 알림
│  │
│  └─ 주요 명령
│     ├─ --install
│     ├─ --uninstall
│     ├─ --test
│     ├─ --version
│     └─ --help
│
├─ pve-telegram-monitor.sh
│  │
│  ├─ Daily Report
│  ├─ 호스트 상태
│  ├─ VM/LXC 정보
│  ├─ 디스크 SMART
│  ├─ Proxmox Storage
│  ├─ 최근 백업 5개
│  └─ 하드웨어 정보
│
│  주요 명령
│  ├─ --install
│  ├─ --uninstall
│  ├─ --report
│  ├─ --smart
│  ├─ --test
│  ├─ --version
│  └─ --help
│
├─ systemd
│  │
│  ├─ pve-telegram-event.service
│  ├─ pve-telegram-host-start.service
│  ├─ pve-telegram-host-stop.service
│  ├─ pve-telegram-report.service
│  └─ pve-telegram-report.timer
│
└─ /etc/pve-telegram-monitor/config
   │
   ├─ TELEGRAM_BOT_TOKEN
   └─ TELEGRAM_CHAT_ID
```

---

# License

개인적인 Proxmox 관리 및 모니터링 용도로 사용할 수 있습니다.
