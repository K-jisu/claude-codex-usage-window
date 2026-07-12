#requires -Version 5.1
<#
  Claude & Codex Usage — Windows tray widget
  ------------------------------------------------------------------
  macOS 원본(claude-codex-battery, SwiftBar 플러그인)의 Windows 포팅.
  시스템 트레이에 Claude Code / Codex 남은 사용량을 배터리 아이콘으로 상시 표시.

  - 상주 프로세스: 2분마다 갱신, 트레이 아이콘을 제자리에서 교체.
  - 배터리 아이콘은 System.Drawing으로 픽셀 단위 렌더(멀티사이즈 ICO) — 외부 이미지 라이브러리 0.
  - 데이터는 전부 로컬 파일에서 읽음(네트워크 호출 없음):
      Codex : ~/.codex/sessions/**/*.jsonl → rate_limits (5시간/주간 실제 사용률)
      Claude: ~/.claude/MEMORY/STATE/usage-cache.json 있으면 실제 %,
              없으면 ~/.claude/projects/**/*.jsonl 로 활성 5시간 블록의 경과율 + 토큰

  Windows PowerShell 5.1 + .NET Framework(WinForms) 전제 — 추가 설치 불필요.
#>

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── 콘솔 창 숨김 (직접 실행 시. 보통은 run-hidden.vbs 로 띄움) ──────────
try {
  Add-Type -Namespace Native -Name Win -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
'@
  [Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0) | Out-Null  # 0 = SW_HIDE
} catch {}

# ── 설정 ───────────────────────────────────────────────────────────────
$script:VERSION       = '1.0.0'
$script:REFRESH_MS    = 120000        # 2분
$script:HOMEDIR       = $env:USERPROFILE
$script:EPOCH         = [datetime]'1970-01-01T00:00:00Z'

$MODEL_NAMES = @{
  'claude-fable-5' = 'Fable 5'; 'claude-opus-4-8' = 'Opus 4.8'; 'claude-opus-4-7' = 'Opus 4.7'
  'claude-sonnet-5' = 'Sonnet 5'; 'claude-haiku-4-5-20251001' = 'Haiku 4.5'
}
function Short-Model([string]$n) { if ($MODEL_NAMES.ContainsKey($n)) { $MODEL_NAMES[$n] } else { ($n -replace '^claude-', '') } }

# ── 유틸 ───────────────────────────────────────────────────────────────
function Now-Unix { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function To-UnixSeconds([string]$iso) {
  if (-not $iso) { return $null }
  try { return [DateTimeOffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUnixTimeSeconds() }
  catch { return $null }
}
function File-Unix($fileInfo) { [int64][math]::Floor($fileInfo.LastWriteTimeUtc.Subtract($script:EPOCH).TotalSeconds) }
function Fmt-Dur([int64]$secs) {
  if ($secs -le 0) { return '0m' }
  $h = [math]::Floor($secs / 3600); $m = [math]::Floor(($secs % 3600) / 60)
  if ($h -ge 24) { return ('{0}d {1}h' -f [math]::Floor($h / 24), ($h % 24)) }
  if ($h -gt 0) { return ('{0}h {1}m' -f $h, $m) }
  return ('{0}m' -f $m)
}
function Fmt-Tok([double]$n) {
  if ($n -ge 1e9) { return ('{0:0.0}B' -f ($n / 1e9)) }
  if ($n -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
  if ($n -ge 1e3) { return ('{0:0}K' -f ($n / 1e3)) }
  return ('{0:0}' -f $n)
}

# ── 테마 감지 (레지스트리) ─────────────────────────────────────────────
function Get-RegDword($name) {
  try { return (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name $name -ErrorAction Stop).$name } catch { return 1 }
}
function Is-TrayDark { (Get-RegDword 'SystemUsesLightTheme') -eq 0 }   # 작업표시줄/트레이 테마
function Is-AppsDark { (Get-RegDword 'AppsUseLightTheme') -eq 0 }      # 앱(메뉴) 테마

# ── 색 (남은 % → 신호색) ───────────────────────────────────────────────
function Heat-Color([double]$r) {
  if ($r -le 20) { return [Drawing.Color]::FromArgb(255, 69, 58) }    # 빨강
  if ($r -lt 50) { return [Drawing.Color]::FromArgb(255, 204, 10) }   # 노랑(진하게)
  return [Drawing.Color]::FromArgb(48, 209, 88)                       # 초록
}
function Heat-MenuColor([double]$r) {
  if ($r -le 20) { return [Drawing.Color]::FromArgb(248, 81, 73) }
  if ($r -lt 50) { return [Drawing.Color]::FromArgb(210, 153, 34) }
  return [Drawing.Color]::FromArgb(63, 185, 80)
}

# ══ 배터리 아이콘 렌더 (픽셀 폰트, 2톤 숫자) ═══════════════════════════
$NUM = @{
  '0'=@('0110','1001','1001','1001','1001','0110'); '1'=@('0010','0110','0010','0010','0010','0111')
  '2'=@('0110','1001','0010','0100','1000','1111'); '3'=@('1110','0001','0110','0001','1001','0110')
  '4'=@('0010','0110','1010','1111','0010','0010'); '5'=@('1111','1000','1110','0001','1001','0110')
  '6'=@('0110','1000','1110','1001','1001','0110'); '7'=@('1111','0001','0010','0100','0100','0100')
  '8'=@('0110','1001','0110','1001','1001','0110'); '9'=@('0110','1001','1001','0111','0001','0110')
}
function New-BatteryBitmap([double]$remain, [bool]$dark, [int]$N) {
  $bmp = New-Object Drawing.Bitmap($N, $N, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $ink = if ($dark) { [Drawing.Color]::FromArgb(240, 240, 240) } else { [Drawing.Color]::FromArgb(35, 35, 35) }
  $dig = [Drawing.Color]::FromArgb(15, 15, 15)     # 밝은 채움 위 대비용 어두운 숫자
  $heat = Heat-Color $remain
  $SetP = { param($x, $y, $c) if ($x -ge 0 -and $y -ge 0 -and $x -lt $N -and $y -lt $N) { $bmp.SetPixel($x, $y, $c) } }

  $ds  = [math]::Max(1, [int][math]::Floor($N / 16.0))
  $th  = [math]::Max(1, [int][math]::Round($N / 18.0))
  $nub = [math]::Max(1, [int]($N * 0.07))
  $bw  = [int]($N * 0.80) - $nub
  $bh  = [int]($N * 0.56)
  $bx  = [int](($N - ($bw + $nub)) / 2)
  $by  = [int](($N - $bh) / 2)

  for ($t = 0; $t -lt $th; $t++) {
    for ($x = $bx; $x -lt $bx + $bw; $x++) { & $SetP $x ($by + $t) $ink; & $SetP $x ($by + $bh - 1 - $t) $ink }
    for ($y = $by; $y -lt $by + $bh; $y++) { & $SetP ($bx + $t) $y $ink; & $SetP ($bx + $bw - 1 - $t) $y $ink }
  }
  $ny = $by + [int]($bh * 0.30)
  for ($x = 0; $x -lt $nub; $x++) { for ($y = $ny; $y -lt $ny + [int]($bh * 0.4); $y++) { & $SetP ($bx + $bw - 1 + $x) $y $ink } }

  $pad = $th
  $innerX = $bx + $pad; $innerY = $by + $pad
  $innerW = $bw - 2 * $pad; $innerH = $bh - 2 * $pad
  $fw = [int]([math]::Round(([math]::Max(0, [math]::Min(100, $remain)) / 100.0) * $innerW))
  $fillBoundary = $innerX + $fw
  for ($x = 0; $x -lt $fw; $x++) { for ($y = 0; $y -lt $innerH; $y++) { & $SetP ($innerX + $x) ($innerY + $y) $heat } }

  $txt = if ($remain -ge 99.5) { '' } else { [string][int][math]::Round($remain) }
  if ($txt) {
    $glyphW = 4 * $ds; $glyphH = 6 * $ds; $gap = $ds
    $totalW = $txt.Length * $glyphW + ($txt.Length - 1) * $gap
    $sx = $bx + [int](($bw - $totalW) / 2)
    $sy = $by + [int](($bh - $glyphH) / 2)
    $cx = $sx
    foreach ($ch in $txt.ToCharArray()) {
      $g = $NUM["$ch"]
      if ($g) {
        for ($r = 0; $r -lt 6; $r++) { for ($c = 0; $c -lt 4; $c++) {
          if ($g[$r][$c] -eq '1') {
            for ($yy = 0; $yy -lt $ds; $yy++) { for ($xx = 0; $xx -lt $ds; $xx++) {
              $Px = $cx + $c * $ds + $xx; $Py = $sy + $r * $ds + $yy
              $col = if ($Px -lt $fillBoundary) { $dig } else { $ink }
              & $SetP $Px $Py $col
            }}
          }
        }}
      }
      $cx += $glyphW + $gap
    }
  }
  return $bmp
}
# 전체(요약) 아이콘: 색 타일 + 목록 3줄 (전체 잔량 최솟값으로 색). 배터리 캡슐과 구분됨.
function New-AllBitmap([double]$worst, [bool]$dark, [int]$N) {
  $bmp = New-Object Drawing.Bitmap($N, $N, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $heat = Heat-Color $worst
  $line = [Drawing.Color]::FromArgb(25, 25, 25)     # 밝은 타일 위 목록선(어두움)
  $SetP = { param($x, $y, $c) if ($x -ge 0 -and $y -ge 0 -and $x -lt $N -and $y -lt $N) { $bmp.SetPixel($x, $y, $c) } }
  $m = [int]($N * 0.13)
  $x0 = $m; $y0 = $m; $x1 = $N - 1 - $m; $y1 = $N - 1 - $m
  for ($y = $y0; $y -le $y1; $y++) { for ($x = $x0; $x -le $x1; $x++) {
    $corner = (($x -eq $x0) -or ($x -eq $x1)) -and (($y -eq $y0) -or ($y -eq $y1))  # 모서리 1px 깎아 라운드 느낌
    if (-not $corner) { & $SetP $x $y $heat }
  }}
  $lw = [int](($x1 - $x0) * 0.58); $lx = $x0 + [int]((($x1 - $x0) - $lw) / 2)
  $lh = [math]::Max(1, [int]($N / 13))
  foreach ($fr in @(0.28, 0.50, 0.72)) {
    $ly = $y0 + [int]((($y1 - $y0)) * $fr)
    for ($t = 0; $t -lt $lh; $t++) { for ($x = 0; $x -lt $lw; $x++) { & $SetP ($lx + $x) ($ly + $t) $line } }
  }
  return $bmp
}
# 여러 크기 비트맵 → 멀티사이즈 .ico (각 프레임 PNG). 어떤 DPI에서도 선명.
$script:ICON_SIZES = @(16, 20, 24, 32, 40, 48)
function Pack-Icon($bitmaps) {
  $frames = @(); $sizes = @()
  foreach ($b in $bitmaps) {
    $ms = New-Object IO.MemoryStream
    $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $frames += , ($ms.ToArray()); $sizes += $b.Width
    $ms.Dispose(); $b.Dispose()
  }
  $out = New-Object IO.MemoryStream
  $bw = New-Object IO.BinaryWriter($out)
  $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
  $offset = 6 + 16 * $sizes.Count
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $frames[$i].Length
    $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
    $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
  }
  foreach ($f in $frames) { $bw.Write($f) }
  $bw.Flush(); $out.Position = 0
  $icon = New-Object Drawing.Icon($out)
  $bw.Dispose(); $out.Dispose()
  return $icon
}
function New-TrayIcon([double]$remain, [bool]$dark) {
  Pack-Icon @(foreach ($s in $script:ICON_SIZES) { New-BatteryBitmap $remain $dark $s })
}
function New-AllIcon([double]$worst, [bool]$dark) {
  Pack-Icon @(foreach ($s in $script:ICON_SIZES) { New-AllBitmap $worst $dark $s })
}

# ── 유니코드 게이지(부분 블록) ─────────────────────────────────────────
$FULL = [char]0x2588; $EMPTY = [char]0x2591
$PART = @('', [char]0x258F, [char]0x258E, [char]0x258D, [char]0x258C, [char]0x258B, [char]0x258A, [char]0x2589)
function Bar([double]$pct, [int]$w) {
  $pct = [math]::Max(0, [math]::Min(100, $pct))
  $filled = ($pct / 100.0) * $w
  $fb = [math]::Floor($filled)
  $idx = [int][math]::Round(($filled - $fb) * 8)
  if ($idx -eq 8) { $fb++; $idx = 0 }
  $fb = [math]::Min($fb, $w)
  $s = ([string]$FULL) * $fb; $used = $fb
  if ($idx -gt 0 -and $fb -lt $w) { $s += $PART[$idx]; $used++ }
  $s += ([string]$EMPTY) * [math]::Max(0, $w - $used)
  return $s
}

# ══ 데이터 수집 ════════════════════════════════════════════════════════
function Read-CodexUsage {
  $dir = Join-Path $script:HOMEDIR '.codex\sessions'
  if (-not (Test-Path $dir)) { return $null }
  $files = Get-ChildItem -Path $dir -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 8
  foreach ($f in $files) {
    $lines = Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      if ($lines[$i] -notlike '*rate_limits*') { continue }
      try { $obj = $lines[$i] | ConvertFrom-Json } catch { continue }
      $rl = if ($obj.payload -and $obj.payload.rate_limits) { $obj.payload.rate_limits } elseif ($obj.rate_limits) { $obj.rate_limits } else { $null }
      if ($rl -and ($rl.primary -or $rl.secondary -or $rl.credits)) {
        return [pscustomobject]@{
          measuredAt = (File-Unix $f); limitId = $rl.limit_id; plan = $rl.plan_type
          primary = $rl.primary; secondary = $rl.secondary; credits = $rl.credits
        }
      }
    }
  }
  return $null
}
# Codex 창 상태: resets_at 지났으면 리셋된 것으로 간주(0%)
function Codex-Window($w) {
  if (-not $w) { return $null }
  $now = Now-Unix
  $stale = $w.resets_at -and ($w.resets_at -lt $now)
  [pscustomobject]@{
    pct = if ($stale) { 0.0 } else { [double]$w.used_percent }
    resetsIn = if ($w.resets_at) { [int64]$w.resets_at - $now } else { $null }
    stale = [bool]$stale
  }
}

function Read-ClaudeUsageCache {
  $f = Join-Path $script:HOMEDIR '.claude\MEMORY\STATE\usage-cache.json'
  if (-not (Test-Path $f)) { return $null }
  try { $d = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { return $null }
  $win = { param($o) if ($o) { [pscustomobject]@{ pct = [double]$o.utilization; resetsAt = (To-UnixSeconds $o.resets_at) } } else { $null } }
  $fable = $null
  foreach ($l in $d.limits) {
    $mdl = $l.scope.model.display_name
    if ($l.group -eq 'weekly' -and $mdl) { $fable = [pscustomobject]@{ pct = [double]$l.percent; resetsAt = (To-UnixSeconds $l.resets_at); model = $mdl }; break }
  }
  [pscustomobject]@{
    measuredAt = (File-Unix (Get-Item $f)); fiveHour = (& $win $d.five_hour); weekly = (& $win $d.seven_day); fable = $fable
  }
}

# projects/**/*.jsonl 에서 assistant usage 항목 수집(ts >= sinceEpoch, mtime 필터로 최소 I/O)
function Read-ClaudeEntries([int64]$sinceEpoch) {
  $dir = Join-Path $script:HOMEDIR '.claude\projects'
  if (-not (Test-Path $dir)) { return @() }
  $cutUtc = [DateTimeOffset]::FromUnixTimeSeconds($sinceEpoch).UtcDateTime
  $files = Get-ChildItem -Path $dir -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTimeUtc -ge $cutUtc }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($f in $files) {
    foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
      if ($line.Length -lt 40) { continue }
      if ($line.IndexOf('"usage"') -lt 0 -or $line.IndexOf('"assistant"') -lt 0) { continue }
      try { $o = $line | ConvertFrom-Json } catch { continue }
      $m = $o.message
      if (-not $m -or $m.role -ne 'assistant' -or -not $m.usage) { continue }
      $ts = To-UnixSeconds $o.timestamp
      if ($null -eq $ts -or $ts -lt $sinceEpoch) { continue }
      $u = $m.usage
      $tok = [int64]$u.input_tokens + [int64]$u.output_tokens + [int64]$u.cache_creation_input_tokens + [int64]$u.cache_read_input_tokens
      $out.Add([pscustomobject]@{ ts = [int64]$ts; model = [string]$m.model; tokens = $tok })
    }
  }
  return $out
}
# ccusage 스타일 5시간 블록 → 활성 블록의 경과율/토큰 (최근 12h 창에서 근사)
function Get-ClaudeBlock {
  $FIVE = 5 * 3600; $now = Now-Unix
  $entries = @(Read-ClaudeEntries ($now - 12 * 3600) | Sort-Object ts)
  if ($entries.Count -eq 0) { return $null }
  $blocks = New-Object System.Collections.Generic.List[object]
  $start = $null; $last = $null; $tok = 0
  foreach ($e in $entries) {
    if ($null -eq $start) { $start = ($e.ts - ($e.ts % 3600)); $last = $e.ts; $tok = $e.tokens }
    elseif ($e.ts -le $start + $FIVE -and $e.ts -le $last + $FIVE) { $last = $e.ts; $tok += $e.tokens }
    else { $blocks.Add([pscustomobject]@{ start = $start; last = $last; tokens = $tok }); $start = ($e.ts - ($e.ts % 3600)); $last = $e.ts; $tok = $e.tokens }
  }
  $blocks.Add([pscustomobject]@{ start = $start; last = $last; tokens = $tok })
  $b = $blocks[$blocks.Count - 1]
  $elapsedPct = [math]::Max(0, [math]::Min(100, (($now - $b.start) / $FIVE) * 100))
  [pscustomobject]@{
    start = $b.start; last = $b.last; tokens = $b.tokens
    active = ($now -lt $b.start + $FIVE)
    elapsedPct = $elapsedPct
    resetsIn = [math]::Max(0, [int64]($b.start + $FIVE - $now))
  }
}
function Get-ClaudeModelsToday {
  $midnight = (Get-Date).Date
  $since = [DateTimeOffset]::new($midnight, [DateTimeOffset]::Now.Offset).ToUnixTimeSeconds()
  $entries = @(Read-ClaudeEntries $since)
  if ($entries.Count -eq 0) { return $null }
  $entries | Group-Object model | ForEach-Object {
    [pscustomobject]@{ name = $_.Name; tokens = [int64]($_.Group | Measure-Object tokens -Sum).Sum }
  } | Sort-Object tokens -Descending
}

# ── 상태 조립: 배터리 항목 + 상세용 원자료 ─────────────────────────────
function Get-State {
  $now = Now-Unix
  $usage  = Read-ClaudeUsageCache
  $block  = Get-ClaudeBlock
  $models = Get-ClaudeModelsToday
  $codex  = Read-CodexUsage

  $items = New-Object System.Collections.Generic.List[object]
  $hasClaude = $false; $hasCodex = $false

  if ($usage) {
    $hasClaude = $true
    if ($usage.fiveHour) { $r = [math]::Max(0, 100 - $usage.fiveHour.pct); $items.Add([pscustomobject]@{ label = 'C5'; remain = $r; tip = "Claude 5시간 · $([int]$r)% 남음$(if($usage.fiveHour.resetsAt){' · 리셋 ' + (Fmt-Dur ($usage.fiveHour.resetsAt-$now))})" }) }
    if ($usage.weekly)   { $r = [math]::Max(0, 100 - $usage.weekly.pct);   $items.Add([pscustomobject]@{ label = 'CW'; remain = $r; tip = "Claude 주간 · $([int]$r)% 남음$(if($usage.weekly.resetsAt){' · 리셋 ' + (Fmt-Dur ($usage.weekly.resetsAt-$now))})" }) }
    if ($usage.fable)    { $r = [math]::Max(0, 100 - $usage.fable.pct);    $items.Add([pscustomobject]@{ label = 'CF'; remain = $r; tip = "$($usage.fable.model) 주간 · $([int]$r)% 남음" }) }
  } elseif ($block) {
    $hasClaude = $true
    $r = [math]::Max(0, 100 - $block.elapsedPct)
    $items.Add([pscustomobject]@{ label = 'C5'; remain = $r; tip = "Claude 5시간 창(경과율) · $([int]$r)% 남음 · 리셋 $(Fmt-Dur $block.resetsIn)" })
  }

  if ($codex -and ($codex.primary -or $codex.secondary)) {
    $hasCodex = $true
    $p = Codex-Window $codex.primary; $s = Codex-Window $codex.secondary
    if ($p) { $r = [math]::Max(0, 100 - $p.pct); $items.Add([pscustomobject]@{ label = 'X5'; remain = $r; tip = "Codex 5시간 · $([int]$r)% 남음$(if($p.resetsIn){' · 리셋 ' + (Fmt-Dur $p.resetsIn)})" }) }
    if ($s) { $r = [math]::Max(0, 100 - $s.pct); $items.Add([pscustomobject]@{ label = 'XW'; remain = $r; tip = "Codex 주간 · $([int]$r)% 남음$(if($s.resetsIn){' · 리셋 ' + (Fmt-Dur $s.resetsIn)})" }) }
  } elseif ($codex -and $codex.credits) {
    $hasCodex = $true
    $cr = $codex.credits
    $r = if ($cr.unlimited) { 100 } elseif ($cr.has_credits -and [double]$cr.balance -gt 0) { 100 } else { 0 }
    $items.Add([pscustomobject]@{ label = 'X'; remain = $r; tip = "Codex 크레딧 · $(if($r -eq 0){'소진'}else{'있음'})" })
  }

  [pscustomobject]@{
    items = $items; usage = $usage; block = $block; models = $models; codex = $codex
    hasClaude = $hasClaude; hasCodex = $hasCodex; measuredNow = $now
  }
}

# ══ 트레이 UI ══════════════════════════════════════════════════════════
$script:icons = New-Object System.Collections.Generic.List[System.Windows.Forms.NotifyIcon]
$script:menu  = New-Object System.Windows.Forms.ContextMenuStrip
$script:menu.ShowImageMargin = $false
$script:menu.ShowCheckMargin = $false
$script:menu.Font = New-Object Drawing.Font('Consolas', 9)
$script:lastState = $null                    # 마지막 수집 상태 (메뉴 열 때 재구성용)
$script:lastScope = 'all'                    # 마지막 클릭 아이콘의 스코프
$script:lastIcon  = $null                    # 마지막 클릭된 NotifyIcon (새로고침 후 재오픈용)

# NotifyIcon의 private ShowContextMenu 를 좌클릭에서도 호출(네이티브 포커스/자동닫힘)
$script:ShowCtxMethod = [System.Windows.Forms.NotifyIcon].GetMethod(
  'ShowContextMenu', [System.Reflection.BindingFlags]([System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic))
function Show-ScopedMenu($ni) {
  if (-not $ni) { return }
  $script:lastScope = [string]$ni.Tag
  $script:lastIcon = $ni
  try { $script:ShowCtxMethod.Invoke($ni, $null) | Out-Null } catch { $script:menu.Show([System.Windows.Forms.Cursor]::Position) }
}
# 메뉴가 열릴 때마다 마지막 클릭 스코프로 최신 상태 재구성 → 항상 신선 + 스코프별 표시
$script:menu.Add_Opening({ param($s, $e) if ($script:lastState) { Build-Menu $script:lastState $script:lastScope } })

function New-TrayNotifyIcon {
  $ni = New-Object System.Windows.Forms.NotifyIcon
  $ni.ContextMenuStrip = $script:menu   # 우클릭: 네이티브로 열림 → Opening에서 스코프별 재구성
  $ni.Add_MouseDown({ param($s, $e) $script:lastScope = [string]$s.Tag; $script:lastIcon = $s })
  $ni.Add_MouseUp({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-ScopedMenu $s } })
  return $ni
}
function Sync-Icons($state) {
  $dark = Is-TrayDark
  # 아이콘 스펙: [전체 요약] 먼저, 그 뒤 각 배터리(스코프 태그: claude/codex)
  $specs = New-Object System.Collections.Generic.List[object]
  if ($state.items.Count -gt 0) {
    $worst = ($state.items | ForEach-Object { $_.remain } | Measure-Object -Minimum).Minimum
    $summary = (($state.items | ForEach-Object { "$($_.label) $([int]$_.remain)%" }) -join ' · ')
    $specs.Add([pscustomobject]@{ all = $true; remain = [double]$worst; scope = 'all'; tip = "전체 · $summary" })
  }
  foreach ($it in $state.items) {
    $scope = if ("$($it.label)"[0] -eq 'C') { 'claude' } else { 'codex' }
    $specs.Add([pscustomobject]@{ all = $false; remain = [double]$it.remain; scope = $scope; tip = $it.tip })
  }
  if ($specs.Count -eq 0) {
    $specs.Add([pscustomobject]@{ all = $true; remain = 0.0; scope = 'all'; tip = 'Claude/Codex 사용량 대기 중' })
  }

  $n = $specs.Count
  while ($script:icons.Count -lt $n) { $script:icons.Add((New-TrayNotifyIcon)) }
  while ($script:icons.Count -gt $n) {
    $ni = $script:icons[$script:icons.Count - 1]
    $ni.Visible = $false; if ($ni.Icon) { $ni.Icon.Dispose() }; $ni.Dispose()
    $script:icons.RemoveAt($script:icons.Count - 1)
  }
  for ($i = 0; $i -lt $n; $i++) {
    $sp = $specs[$i]; $ni = $script:icons[$i]; $old = $ni.Icon
    $ni.Icon = if ($sp.all) { New-AllIcon $sp.remain $dark } else { New-TrayIcon $sp.remain $dark }
    $ni.Tag = $sp.scope
    $tip = $sp.tip; if ($tip.Length -gt 62) { $tip = $tip.Substring(0, 62) }
    $ni.Text = $tip
    $ni.Visible = $true
    if ($old) { $old.Dispose() }
  }
}

function Add-Label($text, $color) {
  $lbl = New-Object System.Windows.Forms.ToolStripMenuItem($text)
  $lbl.Enabled = $true; $lbl.Add_Click({}) | Out-Null
  if ($color) { $lbl.ForeColor = $color }
  $script:menu.Items.Add($lbl) | Out-Null
}
function Add-Sep { $script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null }

function Build-Menu($state, $scope = 'all') {
  $now = $state.measuredNow
  $gray = [Drawing.Color]::FromArgb(139, 148, 158)
  $showClaude = ($scope -ne 'codex') -and $state.hasClaude   # 'all'/'claude'
  $showCodex  = ($scope -ne 'claude') -and $state.hasCodex   # 'all'/'codex'
  $script:menu.Items.Clear()

  if ($showClaude) {
    Add-Label 'Claude Code' $gray
    if ($state.usage) {
      $rows = @(
        @{ n = '5시간 남음'; w = $state.usage.fiveHour },
        @{ n = '주간 남음 '; w = $state.usage.weekly }
      )
      if ($state.usage.fable) { $rows += @{ n = ("{0} 남음" -f $state.usage.fable.model); w = $state.usage.fable } }
      foreach ($row in $rows) {
        $w = $row.w; if (-not $w) { continue }
        $r = [math]::Max(0, 100 - $w.pct)
        $reset = if ($w.resetsAt) { if ($w.resetsAt -lt $now) { '리셋됨' } else { '리셋 ' + (Fmt-Dur ($w.resetsAt - $now)) } } else { '' }
        Add-Label ("  {0}  ▕{1}▏ {2}% (사용 {3}%){4}" -f $row.n, (Bar $r 18), [int]$r, [int]$w.pct, $(if ($reset) { '  ·  ' + $reset } else { '' })) (Heat-MenuColor $r)
      }
      Add-Label ("  측정 {0} 전 (Claude 실시간)" -f (Fmt-Dur ($now - $state.usage.measuredAt))) $gray
    } elseif ($state.block) {
      $r = [math]::Max(0, 100 - $state.block.elapsedPct)
      Add-Label ("  5시간 창  ▕{0}▏ {1}% 남음  ·  리셋 {2}" -f (Bar $r 18), [int]$r, (Fmt-Dur $state.block.resetsIn)) (Heat-MenuColor $r)
      Add-Label "  └ 경과율 기준 (로컬에 공식 한도 % 없음)" $gray
      Add-Label ("  블록 토큰  {0}" -f (Fmt-Tok $state.block.tokens)) $gray
    }
    if ($state.models) {
      $total = ($state.models | Measure-Object tokens -Sum).Sum
      Add-Label ("  오늘 모델별  ·  합 {0} 토큰" -f (Fmt-Tok $total)) $gray
      $max = [double]($state.models[0].tokens); if ($max -le 0) { $max = 1 }
      foreach ($m in ($state.models | Select-Object -First 5)) {
        $g = Bar (($m.tokens / $max) * 100) 10
        Add-Label ("  {0,-9}▕{1}▏ {2}" -f (Short-Model $m.name), $g, (Fmt-Tok $m.tokens)) $null
      }
    }
    Add-Sep
  }

  if ($showCodex) {
    $cx = $state.codex
    $planTxt = if ($cx.plan) { ' · ' + $cx.plan } elseif ($cx.limitId) { ' · ' + $cx.limitId } else { '' }
    Add-Label ("Codex{0}" -f $planTxt) $gray
    $p = Codex-Window $cx.primary; $s = Codex-Window $cx.secondary
    if (-not $p -and -not $s -and $cx.credits) {
      $cr = $cx.credits
      if ($cr.unlimited) { Add-Label '  크레딧  무제한' (Heat-MenuColor 100) }
      elseif (-not $cr.has_credits -or [double]$cr.balance -le 0) { Add-Label '  크레딧  소진 · 한도 초과' (Heat-MenuColor 0) }
      else { Add-Label ("  크레딧  잔액 {0}" -f $cr.balance) (Heat-MenuColor 100) }
    }
    if ($p) {
      $r = [math]::Max(0, 100 - $p.pct)
      $reset = if ($p.stale) { '리셋됨' } elseif ($p.resetsIn) { '리셋 ' + (Fmt-Dur $p.resetsIn) } else { '' }
      Add-Label ("  5시간 남음 ▕{0}▏ {1}% (사용 {2}%){3}" -f (Bar $r 18), [int]$r, [int]$p.pct, $(if ($reset) { '  ·  ' + $reset } else { '' })) (Heat-MenuColor $r)
    }
    if ($s) {
      $r = [math]::Max(0, 100 - $s.pct)
      $reset = if ($s.stale) { '리셋됨' } elseif ($s.resetsIn) { '리셋 ' + (Fmt-Dur $s.resetsIn) } else { '' }
      Add-Label ("  주간 남음  ▕{0}▏ {1}% (사용 {2}%){3}" -f (Bar $r 18), [int]$r, [int]$s.pct, $(if ($reset) { '  ·  ' + $reset } else { '' })) (Heat-MenuColor $r)
    }
    $age = $now - $cx.measuredAt
    $staleWarn = $age -gt 3 * 3600
    Add-Label ("  측정 {0} 전{1}" -f (Fmt-Dur $age), $(if ($staleWarn) { '  ·  ⚠ 리셋됐을 수 있음 (Codex 실행 시 갱신)' } else { ' (Codex 세션 기준)' })) $(if ($staleWarn) { [Drawing.Color]::FromArgb(210, 153, 34) } else { $gray })
    Add-Sep
  }

  if (-not $showClaude -and -not $showCodex) {
    Add-Label 'Claude Code나 Codex를 실행하면 사용량이 표시됩니다' $gray
    Add-Sep
  }

  $refresh = New-Object System.Windows.Forms.ToolStripMenuItem('🔄 지금 새로고침')
  $refresh.Add_Click({ Manual-Refresh }) | Out-Null
  $script:menu.Items.Add($refresh) | Out-Null

  $quit = New-Object System.Windows.Forms.ToolStripMenuItem('❌ 종료')
  $quit.Add_Click({ Quit-App }) | Out-Null
  $script:menu.Items.Add($quit) | Out-Null

  Add-Label ("v{0}  ·  Claude & Codex Usage (Windows)" -f $script:VERSION) $gray
}

function Refresh-All {
  try {
    $state = Get-State
    $script:lastState = $state     # 메뉴는 Opening에서 이 상태로 재구성됨
    Sync-Icons $state
  } catch {}
}
# 수동 새로고침: 재조회 후 완료 알림(풍선)으로 확실한 피드백
function Manual-Refresh {
  Refresh-All
  try {
    $ni = if ($script:lastIcon) { $script:lastIcon } elseif ($script:icons.Count) { $script:icons[0] } else { $null }
    if ($ni -and $ni.Visible) {
      $ni.ShowBalloonTip(1200, 'Claude & Codex Usage', ("새로고침 완료 · {0}" -f (Get-Date).ToString('HH:mm:ss')), [System.Windows.Forms.ToolTipIcon]::Info)
    }
  } catch {}
}

function Quit-App {
  try {
    if ($script:timer) { $script:timer.Stop() }
    foreach ($ni in $script:icons) { $ni.Visible = $false; if ($ni.Icon) { $ni.Icon.Dispose() }; $ni.Dispose() }
    $script:icons.Clear()
  } catch {}
  [System.Windows.Forms.Application]::ExitThread()
}

# ── 메인 루프 ──────────────────────────────────────────────────────────
if ($env:CCU_NO_RUN -eq '1') { return }   # 테스트 모드: 함수만 로드, 루프 미실행

# 중복 실행 방지 (이미 떠 있으면 조용히 종료). WaitOne(0)로 확실하게 점유 판정.
$script:mutex = New-Object System.Threading.Mutex($false, 'ClaudeCodexUsageWindowsTray')
$acquired = $false
try { $acquired = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { exit }

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $script:REFRESH_MS
$script:timer.Add_Tick({ Refresh-All })

Refresh-All
$script:timer.Start()

$script:ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($script:ctx)
