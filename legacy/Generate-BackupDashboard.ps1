# =====================================================================
# Generate-BackupDashboard.ps1
# Creates a visual HTML dashboard of backup status. Pin it as a bookmark
# or set it as a desktop shortcut. Refresh anytime to see current state.
#
# Usage:
#   .\Generate-BackupDashboard.ps1               # creates dashboard.html on Desktop
#   .\Generate-BackupDashboard.ps1 -Open         # also opens it in browser
#   .\Generate-BackupDashboard.ps1 -Path "C:\path\dashboard.html"
# =====================================================================

param(
    [string]$Path = "$env:USERPROFILE\Desktop\Claude-Backup-Dashboard.html",
    [switch]$Open
)

# Get all status info using health-check logic
$configPath = "$env:LOCALAPPDATA\ClaudeAutoBackup\config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "No config found. Run Setup-AutoBackup.ps1 first." -ForegroundColor Red
    exit 1
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json

# Run health check to get JSON status
$healthScript = Join-Path $PSScriptRoot "Check-BackupHealth.ps1"
if (-not (Test-Path $healthScript)) {
    $healthScript = Join-Path "$env:LOCALAPPDATA\ClaudeAutoBackup" "Check-BackupHealth.ps1"
}

$health = $null
if (Test-Path $healthScript) {
    $json = & powershell.exe -ExecutionPolicy Bypass -File $healthScript -Json 2>$null | Out-String
    try { $health = $json | ConvertFrom-Json } catch {}
}

# Gather rich data for the dashboard
$primaryStatus = $null
$primaryStatusPath = Join-Path $config.PrimaryRoot "status.json"
if (Test-Path $primaryStatusPath) {
    $primaryStatus = Get-Content $primaryStatusPath -Raw | ConvertFrom-Json
}

# Drive info
function Get-DriveInfo($driveLetter) {
    if (-not (Test-Path "${driveLetter}:")) {
        return @{ Available = $false; Letter = $driveLetter }
    }
    $d = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    if (-not $d) { return @{ Available = $false; Letter = $driveLetter } }
    $totalGB = [math]::Round(($d.Free + $d.Used) / 1GB, 1)
    $freeGB = [math]::Round($d.Free / 1GB, 1)
    $usedGB = [math]::Round($d.Used / 1GB, 1)
    $pctUsed = if ($totalGB -gt 0) { [math]::Round(($d.Used / ($d.Free + $d.Used)) * 100, 1) } else { 0 }
    return @{
        Available = $true
        Letter = $driveLetter
        TotalGB = $totalGB
        FreeGB = $freeGB
        UsedGB = $usedGB
        PctUsed = $pctUsed
    }
}

$primaryLetter = ($config.PrimaryRoot -split ':')[0]
$archiveLetter = if ($config.ArchiveRoot) { ($config.ArchiveRoot -split ':')[0] } else { $null }
$primaryInfo = Get-DriveInfo $primaryLetter
$archiveInfo = if ($archiveLetter) { Get-DriveInfo $archiveLetter } else { $null }

# Snapshot inventory
function Get-SnapshotList($root) {
    if (-not (Test-Path $root)) { return @() }
    $items = @()

    $latest = Join-Path $root "latest"
    if (Test-Path $latest) {
        $sizeMB = [math]::Round((Get-ChildItem $latest -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 0)
        $items += @{ Kind = "latest"; Date = ""; Time = (Get-Item $latest).LastWriteTime; SizeMB = $sizeMB }
    }

    $dailies = Get-ChildItem (Join-Path $root "daily") -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    foreach ($d in $dailies) {
        $sizeMB = [math]::Round((Get-ChildItem $d.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 0)
        $items += @{ Kind = "daily"; Date = $d.Name; Time = $d.LastWriteTime; SizeMB = $sizeMB }
    }

    $weeklies = Get-ChildItem (Join-Path $root "weekly") -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    foreach ($w in $weeklies) {
        $sizeMB = [math]::Round((Get-ChildItem $w.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 0)
        $items += @{ Kind = "weekly"; Date = $w.Name; Time = $w.LastWriteTime; SizeMB = $sizeMB }
    }

    return $items
}

$primarySnaps = if ($primaryInfo.Available) { Get-SnapshotList $config.PrimaryRoot } else { @() }
$archiveSnaps = if ($archiveInfo -and $archiveInfo.Available) { Get-SnapshotList $config.ArchiveRoot } else { @() }

# Recent log entries
$todayLogPath = "$env:LOCALAPPDATA\ClaudeAutoBackup\logs\backup-$(Get-Date -Format 'yyyy-MM-dd').log"
$recentLog = @()
if (Test-Path $todayLogPath) {
    $recentLog = Get-Content $todayLogPath -Tail 30
}

# Scheduled tasks
$tasks = Get-ScheduledTask -TaskName "ClaudeAutoBackup-*" -ErrorAction SilentlyContinue | ForEach-Object {
    $info = Get-ScheduledTaskInfo -TaskName $_.TaskName
    @{
        Name = $_.TaskName -replace 'ClaudeAutoBackup-', ''
        State = $_.State.ToString()
        LastRun = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString("yyyy-MM-dd HH:mm") } else { "Never" }
        Result = $info.LastTaskResult
        NextRun = if ($info.NextRunTime) { $info.NextRunTime.ToString("yyyy-MM-dd HH:mm") } else { "—" }
    }
}

# Overall status
$overallStatus = if ($health) { $health.OverallStatus } else { "unknown" }
$statusColor = switch ($overallStatus) {
    "green" { "#16a34a" }
    "yellow" { "#ca8a04" }
    "red" { "#dc2626" }
    default { "#6b7280" }
}
$statusText = switch ($overallStatus) {
    "green" { "All systems operational" }
    "yellow" { "Warnings present" }
    "red" { "Attention needed" }
    default { "Status unknown" }
}

# =====================================================================
# Build the HTML
# =====================================================================
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="60">
<title>Claude Backup Dashboard</title>
<style>
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, 'Segoe UI', system-ui, sans-serif;
    margin: 0; padding: 24px;
    background: #0f172a;
    color: #e2e8f0;
    min-height: 100vh;
  }
  .container { max-width: 1200px; margin: 0 auto; }
  header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; }
  h1 { margin: 0; font-size: 28px; font-weight: 700; }
  .timestamp { color: #94a3b8; font-size: 13px; }
  .status-banner {
    background: linear-gradient(135deg, $statusColor, $statusColor`dd);
    padding: 20px 24px;
    border-radius: 12px;
    margin-bottom: 24px;
    display: flex; align-items: center; gap: 16px;
  }
  .status-dot { width: 16px; height: 16px; border-radius: 50%; background: white; box-shadow: 0 0 12px rgba(255,255,255,0.6); }
  .status-text { font-size: 20px; font-weight: 600; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 24px; }
  .card {
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 12px;
    padding: 20px;
  }
  .card h2 { margin: 0 0 16px 0; font-size: 16px; color: #94a3b8; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
  .check-row { display: flex; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid #334155; }
  .check-row:last-child { border-bottom: none; }
  .check-name { font-weight: 500; }
  .check-detail { color: #94a3b8; font-size: 13px; }
  .badge { padding: 3px 10px; border-radius: 6px; font-size: 12px; font-weight: 600; }
  .badge-green { background: #166534; color: #bbf7d0; }
  .badge-yellow { background: #854d0e; color: #fef3c7; }
  .badge-red { background: #991b1b; color: #fecaca; }
  .badge-gray { background: #374151; color: #d1d5db; }
  .drive-card { background: #1e293b; border-radius: 12px; padding: 20px; border: 1px solid #334155; }
  .drive-name { font-size: 22px; font-weight: 700; margin-bottom: 4px; }
  .drive-subtitle { color: #94a3b8; font-size: 13px; margin-bottom: 16px; }
  .progress { background: #0f172a; border-radius: 6px; height: 24px; overflow: hidden; position: relative; }
  .progress-fill { height: 100%; background: linear-gradient(90deg, #3b82f6, #06b6d4); transition: width 0.5s; }
  .progress-fill.warning { background: linear-gradient(90deg, #ca8a04, #eab308); }
  .progress-fill.danger { background: linear-gradient(90deg, #dc2626, #ef4444); }
  .progress-text { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); font-size: 13px; font-weight: 600; }
  .drive-stats { display: flex; gap: 16px; margin-top: 12px; font-size: 13px; }
  .drive-stat { color: #94a3b8; }
  .drive-stat strong { color: #e2e8f0; font-size: 16px; display: block; }
  .snapshot-list { max-height: 280px; overflow-y: auto; }
  .snapshot-row { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #334155; font-size: 13px; }
  .snapshot-row:last-child { border-bottom: none; }
  .snapshot-meta { color: #94a3b8; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; padding: 8px; color: #94a3b8; font-weight: 600; border-bottom: 1px solid #334155; font-size: 11px; text-transform: uppercase; }
  td { padding: 10px 8px; border-bottom: 1px solid #334155; }
  .log-box { background: #0f172a; border-radius: 8px; padding: 12px; max-height: 240px; overflow-y: auto; font-family: 'Consolas', 'Monaco', monospace; font-size: 11px; line-height: 1.5; color: #94a3b8; }
  .log-error { color: #fca5a5; }
  .log-warn { color: #fde047; }
  .footer { text-align: center; color: #64748b; font-size: 12px; margin-top: 24px; }
  .empty { color: #64748b; text-align: center; padding: 20px; font-style: italic; }
  @media (max-width: 768px) { .grid { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<div class="container">

<header>
  <div>
    <h1>Claude Backup Dashboard</h1>
    <div class="timestamp">$(Get-Date -Format 'dddd, MMMM dd yyyy &middot; HH:mm:ss')</div>
  </div>
  <div class="timestamp">auto-refreshes every 60s</div>
</header>

<div class="status-banner">
  <div class="status-dot"></div>
  <div class="status-text">$statusText</div>
</div>

<div class="grid">
  <div class="drive-card">
    <div class="drive-name">PRIMARY &middot; $($primaryInfo.Letter):</div>
    <div class="drive-subtitle">$($config.PrimaryRoot)</div>
"@

if ($primaryInfo.Available) {
    $progClass = if ($primaryInfo.PctUsed -gt 90) { "danger" } elseif ($primaryInfo.PctUsed -gt 75) { "warning" } else { "" }
    $html += @"
    <div class="progress">
      <div class="progress-fill $progClass" style="width: $($primaryInfo.PctUsed)%"></div>
      <div class="progress-text">$($primaryInfo.PctUsed)% used</div>
    </div>
    <div class="drive-stats">
      <div class="drive-stat"><strong>$($primaryInfo.FreeGB) GB</strong>free</div>
      <div class="drive-stat"><strong>$($primaryInfo.UsedGB) GB</strong>used</div>
      <div class="drive-stat"><strong>$($primaryInfo.TotalGB) GB</strong>total</div>
    </div>
"@
} else {
    $html += '<div class="empty">Drive not available</div>'
}

$html += '</div><div class="drive-card">'

if ($archiveInfo) {
    $html += "<div class=`"drive-name`">ARCHIVE &middot; $($archiveInfo.Letter):</div>"
    $html += "<div class=`"drive-subtitle`">$($config.ArchiveRoot)</div>"
    if ($archiveInfo.Available) {
        $progClass = if ($archiveInfo.PctUsed -gt 90) { "danger" } elseif ($archiveInfo.PctUsed -gt 75) { "warning" } else { "" }
        $html += @"
        <div class="progress">
          <div class="progress-fill $progClass" style="width: $($archiveInfo.PctUsed)%"></div>
          <div class="progress-text">$($archiveInfo.PctUsed)% used</div>
        </div>
        <div class="drive-stats">
          <div class="drive-stat"><strong>$($archiveInfo.FreeGB) GB</strong>free</div>
          <div class="drive-stat"><strong>$($archiveInfo.UsedGB) GB</strong>used</div>
          <div class="drive-stat"><strong>$($archiveInfo.TotalGB) GB</strong>total</div>
        </div>
"@
    } else {
        $html += @"
        <div class="empty">Drive unplugged
        <br><span style="font-size: 12px;">Plug in to auto-sync from PRIMARY</span></div>
"@
    }
} else {
    $html += '<div class="drive-name">ARCHIVE</div><div class="empty">Not configured</div>'
}
$html += '</div></div>'

# Health checks card
if ($health -and $health.Checks) {
    $html += '<div class="card"><h2>Health Checks</h2>'
    foreach ($c in $health.Checks) {
        $badge = "badge-$($c.Status)"
        $html += @"
        <div class="check-row">
          <div>
            <div class="check-name">$($c.Name)</div>
            <div class="check-detail">$($c.Detail)</div>
          </div>
          <span class="badge $badge">$($c.Message)</span>
        </div>
"@
    }
    $html += '</div>'
}

# Scheduled tasks
$html += '<div class="card"><h2>Scheduled Tasks</h2><table>'
$html += '<tr><th>Task</th><th>State</th><th>Last Run</th><th>Result</th><th>Next Run</th></tr>'
foreach ($t in $tasks) {
    $resultBadge = if ($t.Result -eq 0) { "badge-green" } elseif ($t.Result -eq 267011 -or $t.Result -eq 0x41303) { "badge-gray" } else { "badge-red" }
    $resultText = if ($t.Result -eq 0) { "Success" } elseif ($t.Result -eq 267011 -or $t.Result -eq 0x41303) { "Not yet run" } else { "0x{0:X}" -f $t.Result }
    $stateBadge = if ($t.State -eq "Ready" -or $t.State -eq "Running") { "badge-green" } else { "badge-yellow" }
    $html += @"
    <tr>
      <td>$($t.Name)</td>
      <td><span class="badge $stateBadge">$($t.State)</span></td>
      <td>$($t.LastRun)</td>
      <td><span class="badge $resultBadge">$resultText</span></td>
      <td>$($t.NextRun)</td>
    </tr>
"@
}
$html += '</table></div>'

# Snapshot inventory
$html += '<div class="grid"><div class="card"><h2>PRIMARY Snapshots</h2><div class="snapshot-list">'
if ($primarySnaps.Count -eq 0) {
    $html += '<div class="empty">No snapshots yet</div>'
} else {
    foreach ($s in $primarySnaps) {
        $kindBadge = if ($s.Kind -eq "latest") { "badge-green" } else { "badge-gray" }
        $name = if ($s.Date) { "$($s.Kind) &middot; $($s.Date)" } else { $s.Kind }
        $html += "<div class=`"snapshot-row`"><div><span class=`"badge $kindBadge`">$name</span></div><div class=`"snapshot-meta`">$($s.SizeMB) MB &middot; $($s.Time.ToString('MM/dd HH:mm'))</div></div>"
    }
}
$html += '</div></div><div class="card"><h2>ARCHIVE Snapshots</h2><div class="snapshot-list">'
if ($archiveSnaps.Count -eq 0) {
    if ($archiveInfo -and -not $archiveInfo.Available) {
        $html += '<div class="empty">Archive drive unplugged</div>'
    } else {
        $html += '<div class="empty">No snapshots yet</div>'
    }
} else {
    foreach ($s in $archiveSnaps) {
        $kindBadge = switch ($s.Kind) { "latest" { "badge-green" } "daily" { "badge-gray" } "weekly" { "badge-yellow" } }
        $name = if ($s.Date) { "$($s.Kind) &middot; $($s.Date)" } else { $s.Kind }
        $html += "<div class=`"snapshot-row`"><div><span class=`"badge $kindBadge`">$name</span></div><div class=`"snapshot-meta`">$($s.SizeMB) MB &middot; $($s.Time.ToString('MM/dd HH:mm'))</div></div>"
    }
}
$html += '</div></div></div>'

# Recent log
$html += '<div class="card"><h2>Today''s Log (last 30 lines)</h2><div class="log-box">'
if ($recentLog.Count -eq 0) {
    $html += '<div class="empty">No log entries today yet</div>'
} else {
    foreach ($line in $recentLog) {
        $cls = ""
        if ($line -match "ERROR") { $cls = "log-error" }
        elseif ($line -match "WARNING|WARN") { $cls = "log-warn" }
        $escaped = [System.Web.HttpUtility]::HtmlEncode($line)
        $html += "<div class=`"$cls`">$escaped</div>"
    }
}
$html += '</div></div>'

$html += @"

<div class="footer">
  Refresh this page to update &middot; Auto-refreshes every 60 seconds
  <br>To regenerate: <code>Generate-BackupDashboard.ps1</code>
</div>

</div>
</body>
</html>
"@

# Need System.Web for HtmlEncode
Add-Type -AssemblyName System.Web

$html | Set-Content -Path $Path -Encoding UTF8
Write-Host "Dashboard created: $Path" -ForegroundColor Green

if ($Open) {
    Start-Process $Path
}
