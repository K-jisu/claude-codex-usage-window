# 🔋 Claude & Codex Usage — Windows

> **Claude Code**와 **Codex**의 남은 사용량 한도를 **Windows 시스템 트레이**에 배터리 아이콘으로 상시 표시합니다. `/usage`를 열지 않아도 한눈에 남은 양을 확인하세요.

macOS 전용 [claude-codex-battery](https://github.com/dennykim123/claude-codex-battery)(SwiftBar 플러그인)의 **Windows 포팅**입니다. SwiftBar 대신 **Windows 시스템 트레이**를 쓰고, PNG 인코더 대신 **.NET(System.Drawing)** 으로 배터리 아이콘을 픽셀 단위로 그립니다.

- **추가 설치 없음** — Windows에 기본 내장된 **PowerShell 5.1 + .NET(WinForms)** 만 사용. bun/Node/Python 불필요.
- **의존성 0** — 단일 스크립트 `claude-codex-usage.ps1`. 외부 이미지/차트 라이브러리 없음.
- **네트워크 호출 없음** — 사용량은 전부 로컬 파일에서 읽어 로컬에서 렌더링. 데이터가 PC를 벗어나지 않음.

---

## 표시 내용

트레이에 배터리 아이콘이 항목별로 하나씩 뜹니다 (각 아이콘 = 남은 %, 색으로 신호 표시). 마우스를 올리면 툴팁, 클릭/우클릭하면 상세 메뉴가 열립니다.

| 그룹 | 배터리 | 소스 |
|---|---|---|
| **`C` Claude** | 5시간 세션 · (주간 · 최상위모델*) | `~/.claude/MEMORY/STATE/usage-cache.json` 있으면 실제 %, 없으면 `~/.claude/projects/**/*.jsonl` 로 **5시간 창 경과율** |
| **`X` Codex** | 5시간 · 주간 (또는 크레딧) | `~/.codex/sessions/**/*.jsonl` → `rate_limits` |

\* 주간/최상위모델(Fable) 배터리는 `usage-cache.json`이 있을 때만 표시됩니다. Windows Claude Code에는 보통 이 파일이 없어, 기본적으로 Claude는 **5시간 창 경과율** 배터리 1개로 표시됩니다(아래 참고).

상세 메뉴 예시:

```
Claude Code
  5시간 창  ▕████████████████▊░▏ 93% 남음  ·  리셋 4h 39m
  └ 경과율 기준 (로컬에 공식 한도 % 없음)
  블록 토큰  6.4M
  오늘 모델별  ·  합 60.5M 토큰
  Fable 5   ▕██████████▏ 51.6M
  Opus 4.8  ▕█▊░░░░░░░░▏ 8.9M
──────────
Codex · plus
  5시간 남음 ▕███▊░░░░░░░░░░░░░░▏ 21% (사용 79%)  ·  리셋 4h 11m
  주간 남음  ▕█████████████▏░░░░▏ 73% (사용 27%)  ·  리셋 6d 18h
```

색상: 남은 % 기준 **초록 ≥ 50% · 노랑 < 50% · 빨강 ≤ 20%**.

---

## 요구 사항

| | 필요 여부 | 비고 |
|---|---|---|
| **Windows 10/11** | ✅ | PowerShell 5.1 + .NET Framework 내장 |
| **Claude Code** | `C` 배터리에 필요 | `~/.claude/projects/**/*.jsonl` 이 있어야 함 (Claude Code를 쓰면 자동 생성) |
| **Codex CLI** | 선택 | `X` 배터리용. 없으면 Claude만 표시 |

> 이 위젯은 **당신의 로컬 사용량 파일**만 읽습니다. Claude Code나 Codex를 쓰지 않으면 표시할 데이터가 없습니다.

---

## 설치

```powershell
# 폴더로 이동 후
powershell -ExecutionPolicy Bypass -File install.ps1
```

`install.ps1`이 하는 일:

1. 데이터 소스(`~/.codex/sessions`, `~/.claude/projects`) 존재 여부 점검(안내용)
2. **시작프로그램(Startup) 폴더**에 바로가기 등록 → 로그인 시 자동 실행
3. 지금 바로 트레이 위젯 실행 (콘솔 창 없이 `run-hidden.vbs`로 조용히)

트레이(작업표시줄 오른쪽, 숨겨진 아이콘 **▲**)에 배터리가 뜹니다. **2분마다** 자동 갱신됩니다.

> 💡 트레이 아이콘이 ▲ 안에 숨어 있으면, 아이콘을 작업표시줄로 끌어다 놓으면 항상 보입니다. (Windows 설정 → 개인 설정 → 작업 표시줄 → 다른 시스템 트레이 아이콘)

### 수동 실행 (설치 없이 한 번만)

```powershell
# 콘솔 없이:
wscript run-hidden.vbs
# 또는 디버그용(콘솔 표시):
powershell -ExecutionPolicy Bypass -Sta -File claude-codex-usage.ps1
```

### 제거

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

시작프로그램 바로가기를 지우고 실행 중인 위젯을 종료합니다.

---

## macOS 원본과 무엇이 다른가

| | macOS (원본) | Windows (이 포팅) |
|---|---|---|
| 표시 레이어 | SwiftBar 메뉴바 플러그인 | **시스템 트레이** (NotifyIcon 여러 개) |
| 실행 방식 | SwiftBar가 2분마다 스크립트 재실행 | **상주 프로세스** + 타이머로 제자리 갱신 |
| 아이콘 렌더 | 순수 JS로 PNG 인코딩(`node:zlib`) | **.NET System.Drawing** 픽셀 렌더 → 멀티사이즈 `.ico` |
| 런타임 | bun | **PowerShell 5.1 + .NET** (내장) |
| 다크모드 | `defaults read` | 레지스트리 `Personalize\SystemUsesLightTheme` |
| Codex 데이터 | `~/.codex/sessions` | **동일** (구조 같음, 로직 그대로) |
| Claude 데이터 | `usage-cache.json` 실시간 % | 있으면 동일, 없으면 **projects 로그로 경과율 폴백** |

### Claude 배터리에 대하여 (중요)

Windows의 Claude Code에는 보통 `usage-cache.json`(공식 한도 %)이 **없습니다**. 대신 대화 로그(`~/.claude/projects/**/*.jsonl`)에 토큰 사용량이 기록됩니다. 그래서 이 포팅은:

- **5시간 창의 경과율**을 배터리로 표시합니다 (창이 리셋되면 가득 참 → 시간이 지나며 감소). 실제 "사용량 %"가 아니라 **시간 경과율**입니다.
- 상세 메뉴에 **블록 토큰**과 **오늘 모델별 토큰**(실측치)을 함께 보여줍니다.
- 만약 `usage-cache.json`이 생기면(향후 Claude Code 업데이트 등) **자동으로 실제 %로 전환**됩니다 (5시간/주간/Fable 배터리).

---

## 개인정보 & 보안

- **사용량 데이터가 PC를 벗어나지 않습니다.** 로컬 파일에서 읽어 로컬에서 그림. 네트워크 호출 없음.
- **비밀정보 미접근.** `auth.json`, 자격증명 등은 건드리지 않음.
- **대화 내용 미접근.** Codex 세션 로그에서는 `rate_limits`(숫자)만, Claude 로그에서는 `usage`(토큰 수)와 타임스탬프·모델명만 파싱.

---

## 커스터마이징

| 바꾸고 싶은 것 | 위치 (`claude-codex-usage.ps1`) |
|---|---|
| 갱신 주기 | `$REFRESH_MS` (기본 120000 = 2분) |
| 색 임계값 | `Heat-Color` / `Heat-MenuColor` (20% / 50%) |
| 배터리 크기/모양 | `New-BatteryBitmap` 의 `$bw`/`$bh`/`$nub`/`$th` |
| 아이콘 해상도 세트 | `New-TrayIcon` 의 `$sizes` |
| 표시할 Claude 항목 | `Get-State` 의 `$items.Add(...)` 블록 |

---

## 문제 해결

- **아이콘이 안 보임** → 작업표시줄 ▲(숨겨진 아이콘) 안을 확인. 또는 `wscript run-hidden.vbs` 재실행.
- **아무 배터리도 없음** → Claude Code나 Codex를 한 번 실행하면 데이터가 생깁니다.
- **Codex가 "리셋됐을 수 있음" 경고** → Codex는 실행할 때만 로그에 한도를 남깁니다(스냅샷). Codex를 한 번 돌리면 즉시 갱신됩니다.
- **실행이 막힘(ExecutionPolicy)** → 제공된 명령은 `-ExecutionPolicy Bypass`로 정책과 무관하게 실행됩니다.

---

## 라이선스 & 크레딧

[MIT](LICENSE). 원본 아이디어와 로직: [dennykim123/claude-codex-battery](https://github.com/dennykim123/claude-codex-battery) (개발부스러기). Windows 포팅.
