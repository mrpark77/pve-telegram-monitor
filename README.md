# Proxmox Telegram Monitor

Proxmox VE 서버의 상태와 VM/LXC 이벤트를 Telegram으로 알려주는 Bash 스크립트 모음입니다.

---

## 1. 구성

이 프로젝트는 다음 두 개의 스크립트로 구성됩니다.

### pve-telegram-event.sh

Proxmox의 실시간 이벤트를 감시합니다.

다음 이벤트가 발생하면 Telegram으로 알림을 보냅니다.

- Proxmox 호스트 시작
- Proxmox 호스트 종료
- VM 시작
- VM 종료
- LXC 시작
- LXC 종료

systemd 서비스로 등록되어 백그라운드에서 실행됩니다.

### pve-telegram-monitor.sh

Proxmox 서버의 정기 상태 리포트를 생성하여 Telegram으로 전송합니다.

매일 오전 9시에 자동 실행됩니다.

리포트에는 다음 정보가 포함됩니다.

- Proxmox 호스트 상태
- Proxmox VE 버전
- Kernel 버전
- 호스트 가동 시간
- VM 정보
  - VM 이름
  - CPU Core
  - RAM
  - IP
  - MAC
  - 가상 디스크
- LXC 정보
  - LXC 이름
  - CPU Core
  - RAM
  - IP
  - MAC
  - Root disk
- 물리 디스크 SMART 상태
- Proxmox Storage 사용량
- 최근 백업 5개
- 백업 성공/실패 여부
- CPU
- 메인보드
- 물리 RAM
- BIOS 정보

---

## 2. 요구 사항

Proxmox VE 환경에서 실행하는 것을 전제로 합니다.

필요한 주요 명령은 다음과 같습니다.

- curl
- jq
- smartctl
- dmidecode
- qm
- pct
- pvesm
- pveversion

Proxmox VE에는 대부분 기본적으로 포함되어 있습니다.

---

## 3. GitHub에서 스크립트 다운로드

Proxmox Shell에서 다음 명령을 실행합니다.

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

예:
```
2.5.0
```

---

## 4. Telegram 설정

두 스크립트에서 공통으로 사용하는 설정 파일을 생성합니다.

설정 파일 위치:
```
/etc/pve-telegram-monitor/config
```

디렉터리를 생성합니다.
```
mkdir -p /etc/pve-telegram-monitor
```

Telegram Bot Token을 입력합니다.
```
read -rsp "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
echo
```

Telegram Chat ID를 입력합니다.
```
read -rp "Telegram Chat ID: " TELEGRAM_CHAT_ID
```

설정 파일을 생성합니다.
```
cat > /etc/pve-telegram-monitor/config <<EOF
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
EOF
```

설정 파일 권한을 제한합니다.
```
chmod 600 /etc/pve-telegram-monitor/config
```

설정 파일 확인:
```
cat /etc/pve-telegram-monitor/config
```
**※ Bot Token은 외부에 공개하지 마십시오.**

---

## 5. Telegram 연결 테스트
pve-telegram-monitor.sh가 설치되어 있다면 다음 명령으로 테스트합니다.
```
/usr/local/bin/pve-telegram-monitor.sh --test
```
정상적으로 Telegram 메시지가 도착하면 설정이 완료된 것입니다.

---

## 6. pve-telegram-event.sh 설치

실시간 VM/LXC 및 호스트 이벤트 감시 서비스를 설치합니다.
```
/usr/local/bin/pve-telegram-event.sh --install
```

설치가 완료되면 다음 서비스를 사용합니다.
```
pve-telegram-event.service
pve-telegram-host-start.service
pve-telegram-host-stop.service
```

---

### 6-1. 이벤트 모니터 서비스 확인
```
systemctl status pve-telegram-event.service --no-pager -l
```

정상 상태:
```
Active: active (running)
```

서비스 활성화 여부:
```
systemctl is-enabled pve-telegram-event.service
```

정상 결과:
```
enabled
```

---

### 6-2. 호스트 시작 알림 서비스 확인
```
systemctl status pve-telegram-host-start.service --no-pager -l
```

이 서비스는 부팅 시 한 번 실행된 후 종료됩니다.

따라서 다음 상태가 정상입니다.
```
Active: inactive (dead)
```

서비스 자체는 다음과 같이 활성화되어 있어야 합니다.
```
systemctl is-enabled pve-telegram-host-start.service
```

결과:
```
enabled
```

---

### 6-3. 호스트 종료 알림

호스트 종료 시 다음 서비스가 실행됩니다.
```
pve-telegram-host-stop.service
```

종료 과정에서 VM/LXC 종료 이벤트가 먼저 Telegram으로 전송되고,

그 다음 Proxmox 호스트 종료 알림이 전송되도록 systemd 의존성을 구성합니다.

---

## 7. pve-telegram-monitor.sh 설치

정기 리포트용 스크립트를 다운로드합니다.
```
curl -fsSL \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-monitor.sh \
  -o /usr/local/bin/pve-telegram-monitor.sh

chmod +x /usr/local/bin/pve-telegram-monitor.sh
```

버전 확인:
```
/usr/local/bin/pve-telegram-monitor.sh --version
```

---

## 8. Daily Report 서비스 설치

매일 오전 9시에 Proxmox 상태 리포트를 Telegram으로 전송하도록 systemd timer를 등록합니다.

서비스 파일:
```
pve-telegram-report.service
```

타이머 파일:
```
pve-telegram-report.timer
```

타이머 활성화:
```
systemctl daemon-reload
systemctl enable --now pve-telegram-report.timer
```

상태 확인:
```
systemctl status pve-telegram-report.timer --no-pager
```

활성화 여부 확인:
```
systemctl is-enabled pve-telegram-report.timer
```

결과:
```
enabled
```

---

## 9. Daily Report 수동 테스트

예약 시간을 기다리지 않고 리포트를 바로 전송할 수 있습니다.
```
/usr/local/bin/pve-telegram-monitor.sh --report
```

Telegram으로 Proxmox 서버 리포트가 도착하면 정상입니다.

---

## 10. Daily Report 타이머 확인

다음 명령으로 다음 실행 시간을 확인할 수 있습니다.
```
systemctl list-timers --all | grep pve-telegram-report
```

또는:
```
systemctl status pve-telegram-report.timer --no-pager
```

---

## 11. 설치된 서비스 확인
```
systemctl list-unit-files | grep pve-telegram
```

정상적으로 설치되면 다음과 같은 서비스가 표시됩니다.
```
pve-telegram-event.service
pve-telegram-host-start.service
pve-telegram-host-stop.service
pve-telegram-report.service
pve-telegram-report.timer
```

---

## 12. 이벤트 로그 확인

실시간 이벤트 모니터 로그:
```
journalctl -u pve-telegram-event.service -f
```

최근 이벤트 로그:
```
journalctl -u pve-telegram-event.service --no-pager
```

호스트 시작 로그:
```
journalctl -u pve-telegram-host-start.service --no-pager
```

호스트 종료 로그:
```
journalctl -u pve-telegram-host-stop.service --no-pager
```

Daily Report 로그:
```
journalctl -u pve-telegram-report.service --no-pager
```

---

## 13. 시스템 재부팅 테스트

모든 설정이 완료되었다면 다음 명령으로 실제 재부팅 테스트를 할 수 있습니다.
```
reboot
```

정상적인 경우 Telegram 알림 순서는 다음과 같습니다.
```
🔴 Proxmox VM 종료
🔴 Proxmox LXC 종료
🔴 Proxmox 호스트 종료

🟢 Proxmox 호스트 시작
🟢 Proxmox VM 시작
🟢 Proxmox LXC 시작
```

VM/LXC의 종료 및 시작 시간은 실제 게스트 상태에 따라 달라질 수 있습니다.

---

## 14. 스크립트 업데이트

GitHub의 최신 버전으로 스크립트를 업데이트하려면 해당 파일을 다시 다운로드합니다.

**Event Monitor**
```
curl -fsSL \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-event.sh \
  -o /usr/local/bin/pve-telegram-event.sh

chmod +x /usr/local/bin/pve-telegram-event.sh

/usr/local/bin/pve-telegram-event.sh --install
```

**Daily Monitor**
```
curl -fsSL \
  https://raw.githubusercontent.com/mrpark77/pve-telegram-monitor/main/pve-telegram-monitor.sh \
  -o /usr/local/bin/pve-telegram-monitor.sh

chmod +x /usr/local/bin/pve-telegram-monitor.sh
```

---

## 15. 현재 구성 요약
```
Proxmox VE
│
├─ pve-telegram-event.sh
│  │
│  ├─ VM 시작/종료 감시
│  ├─ LXC 시작/종료 감시
│  └─ 호스트 시작/종료 알림
│
├─ pve-telegram-monitor.sh
│  │
│  ├─ 매일 09:00 실행
│  ├─ 호스트 상태
│  ├─ VM/LXC 정보
│  ├─ 디스크 SMART
│  ├─ Proxmox Storage
│  ├─ 최근 백업 5개
│  └─ 하드웨어 정보
│
└─ /etc/pve-telegram-monitor/config
   │
   ├─ TELEGRAM_BOT_TOKEN
   └─ TELEGRAM_CHAT_ID
```

---

## 16. 주요 명령어 요약

Event Monitor 버전 확인
```
/usr/local/bin/pve-telegram-event.sh --version
```

Event Monitor 설치
```
/usr/local/bin/pve-telegram-event.sh --install
```

Telegram 테스트
```
/usr/local/bin/pve-telegram-monitor.sh --test
```

Daily Report 즉시 실행
```
/usr/local/bin/pve-telegram-monitor.sh --report
```

Event Monitor 상태
```
systemctl status pve-telegram-event.service --no-pager -l
```

Daily Report Timer 상태
```
systemctl status pve-telegram-report.timer --no-pager
```

이벤트 로그
```
journalctl -u pve-telegram-event.service -f
```

재부팅 테스트
```
reboot
```

---

# License

개인적인 Proxmox 관리 및 모니터링 용도로 사용할 수 있습니다.

