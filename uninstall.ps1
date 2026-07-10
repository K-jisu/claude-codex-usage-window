#requires -Version 5.1
<#
  Claude & Codex Usage (Windows) — 제거 스크립트
  - 시작프로그램 바로가기 삭제
  - 실행 중인 트레이 위젯 종료
#>
$ErrorActionPreference = 'SilentlyContinue'
Write-Host '🔋 Claude & Codex Usage (Windows) — 제거'

# 1) 시작프로그램 바로가기 삭제
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeCodexUsage.lnk'
if (Test-Path $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Host "✅ 시작프로그램 바로가기 삭제: $lnk" }
else { Write-Host 'ⓘ  시작프로그램 바로가기 없음 (이미 제거됨)' }

# 2) 실행 중인 인스턴스 종료 (claude-codex-usage.ps1 을 실행 중인 powershell 프로세스)
$killed = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*claude-codex-usage.ps1*' } | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force
  $killed++
}
if ($killed -gt 0) { Write-Host "✅ 실행 중인 위젯 종료 ($killed 개)" } else { Write-Host 'ⓘ  실행 중인 위젯 없음' }
Write-Host '완료. (트레이 아이콘이 남아 보이면 마우스를 올리면 사라집니다.)'
