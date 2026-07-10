#requires -Version 5.1
<#
  Claude & Codex Usage (Windows) — 설치 스크립트
  - 로그인 시 자동 시작하도록 시작프로그램(Startup) 폴더에 바로가기 등록
  - 지금 바로 트레이 위젯 실행
  실행:  powershell -ExecutionPolicy Bypass -File install.ps1
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs  = Join-Path $here 'run-hidden.vbs'
$main = Join-Path $here 'claude-codex-usage.ps1'

Write-Host '🔋 Claude & Codex Usage (Windows) — 설치'
Write-Host '────────────────────────────────────────'

if (-not (Test-Path $main)) { Write-Host "❌ claude-codex-usage.ps1 을 찾을 수 없습니다: $main"; exit 1 }
if (-not (Test-Path $vbs))  { Write-Host "❌ run-hidden.vbs 을 찾을 수 없습니다: $vbs"; exit 1 }

# 1) 데이터 소스 점검 (안내용 — 없어도 설치는 진행)
$codex = Join-Path $env:USERPROFILE '.codex\sessions'
$claudeProj = Join-Path $env:USERPROFILE '.claude\projects'
Write-Host ("• Codex 세션:  {0}" -f $(if (Test-Path $codex) { '있음 ✅ (5시간/주간 사용률 표시)' } else { '없음 — Codex 실행 시 표시됨' }))
Write-Host ("• Claude 로그: {0}" -f $(if (Test-Path $claudeProj) { '있음 ✅ (5시간 경과율 + 토큰 표시)' } else { '없음 — Claude Code 실행 시 표시됨' }))

# 2) 시작프로그램 바로가기 등록 (wscript → run-hidden.vbs)
$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup 'ClaudeCodexUsage.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$sc.Arguments = ('"{0}"' -f $vbs)
$sc.WorkingDirectory = $here
$sc.WindowStyle = 7
$sc.Description = 'Claude & Codex Usage tray widget'
$sc.Save()
Write-Host "✅ 시작프로그램 등록: $lnk  (로그인 시 자동 실행)"

# 3) 지금 실행 (이미 떠 있으면 중복 실행 방지 mutex가 막음)
Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"{0}"' -f $vbs) -WorkingDirectory $here
Write-Host '✅ 트레이 위젯 실행됨 — 작업표시줄 오른쪽(숨겨진 아이콘 ▲)에서 배터리를 확인하세요.'
Write-Host '────────────────────────────────────────'
Write-Host '   갱신 주기: 2분  ·  아이콘 클릭/우클릭 → 상세'
Write-Host '   제거:  powershell -ExecutionPolicy Bypass -File uninstall.ps1'
