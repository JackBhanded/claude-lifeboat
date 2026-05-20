# lifeboat dashboard - generate and open visual dashboard

function Invoke-Dashboard {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed."
        exit 1
    }

    $dashboardPath = if ($Flags.path) {
        $Flags.path
    } else {
        "$env:USERPROFILE\Desktop\Claude-Lifeboat.html"
    }

    Write-Heading "Generating dashboard..."
    Generate-Dashboard -Config $config -Path $dashboardPath
    Write-Success "Dashboard: $dashboardPath"

    if (-not $Flags.noopen) {
        Start-Process $dashboardPath
    }
}

function Generate-Dashboard {
    param($Config, $Path)

    # Collect data
    $primaryStats = Get-DriveStats $Config.Primary.Root
    $archiveStats = if ($Config.Archive.Root) { Get-DriveStats $Config.Archive.Root } else { $null }

    $primaryStatus = $null
    $statusPath = Join-Path $Config.Primary.Root "status.json"
    if (Test-Path $statusPath) {
        try { $primaryStatus = Get-Content $statusPath -Raw | ConvertFrom-Json } catch {}
    }

    # Get JSON status by calling our own status command
    $statusJson = $null
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $runnerPath = Join-Path $script:LifeboatHome "lifeboat-runner.ps1"
        if (-not (Test-Path $runnerPath)) { $runnerPath = Join-Path $script:ScriptRoot "lifeboat.ps1" }
        & powershell.exe -ExecutionPolicy Bypass -File $runnerPath status --json > $tempFile 2>$null
        $statusJson = Get-Content $tempFile -Raw | ConvertFrom-Json
        Remove-Item $tempFile -Force
    } catch {}

    # Snapshots
    function Get-Snaps($root) {
        if (-not $root -or -not (Test-Path $root)) { return @() }
        $items = @()
        $latest = Join-Path $root "latest"
        if (Test-Path $latest) {
            $sz = (Get-ChildItem $latest -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $items += @{ Kind = "latest"; Date = "-"; Time = (Get-Item $latest).LastWriteTime; SizeMB = [math]::Round($sz / 1MB, 0) }
        }
        Get-ChildItem (Join-Path $root "daily") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $sz = (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $items += @{ Kind = "daily"; Date = $_.Name; Time = $_.LastWriteTime; SizeMB = [math]::Round($sz / 1MB, 0) }
        }
        Get-ChildItem (Join-Path $root "weekly") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $sz = (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $items += @{ Kind = "weekly"; Date = $_.Name; Time = $_.LastWriteTime; SizeMB = [math]::Round($sz / 1MB, 0) }
        }
        return $items
    }

    $primarySnaps = Get-Snaps $Config.Primary.Root
    $archiveSnaps = if ($Config.Archive.Root) { Get-Snaps $Config.Archive.Root } else { @() }

    # Tasks
    $tasks = Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue | ForEach-Object {
        $info = Get-ScheduledTaskInfo -TaskName $_.TaskName
        @{
            Name = $_.TaskName -replace 'ClaudeLifeboat-', ''
            State = $_.State.ToString()
            LastRun = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString("MM/dd HH:mm") } else { "Never" }
            Result = $info.LastTaskResult
            NextRun = if ($info.NextRunTime) { $info.NextRunTime.ToString("MM/dd HH:mm") } else { "-" }
        }
    }

    # Today's log
    $todayLog = Join-Path $script:LogDir "lifeboat-$(Get-Date -Format 'yyyy-MM-dd').log"
    $recentLog = if (Test-Path $todayLog) { Get-Content $todayLog -Tail 30 } else { @() }

    $statusColor = switch ($statusJson.OverallStatus) {
        'green' { '#16a34a' }
        'yellow' { '#ca8a04' }
        'red' { '#dc2626' }
        default { '#6b7280' }
    }
    $statusText = switch ($statusJson.OverallStatus) {
        'green' { 'All systems healthy' }
        'yellow' { 'Warnings present' }
        'red' { 'Attention needed' }
        default { 'Status unknown' }
    }

    # Build HTML
    Add-Type -AssemblyName System.Web

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="60">
<title>Claude Lifeboat</title>
<style>
*{box-sizing:border-box}
body{font-family:-apple-system,'Segoe UI',sans-serif;margin:0;padding:24px;background:#0b1220;color:#e2e8f0;min-height:100vh}
.container{max-width:1200px;margin:0 auto}
header{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px}
.logo{display:flex;align-items:center;gap:14px}
.logo-icon{font-size:34px;line-height:1}
h1{margin:0;font-size:24px;font-weight:700}
.subtitle{color:#94a3b8;font-size:13px}
.banner{background:linear-gradient(135deg,$statusColor,$statusColor`dd);padding:20px 24px;border-radius:14px;margin-bottom:24px;display:flex;align-items:center;gap:16px;box-shadow:0 4px 24px rgba(0,0,0,0.3)}
.banner-dot{width:14px;height:14px;border-radius:50%;background:white;box-shadow:0 0 12px rgba(255,255,255,0.7);animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:0.5}}
.banner-text{font-size:20px;font-weight:600}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:24px}
.card{background:#111827;border:1px solid #1f2937;border-radius:14px;padding:20px;transition:transform 0.2s}
.card h2{margin:0 0 16px;font-size:13px;color:#94a3b8;font-weight:600;text-transform:uppercase;letter-spacing:0.8px}
.row{display:flex;justify-content:space-between;padding:11px 0;border-bottom:1px solid #1f2937;align-items:center}
.row:last-child{border-bottom:none}
.row-name{font-weight:500}
.row-detail{color:#94a3b8;font-size:12px;margin-top:2px}
.badge{padding:4px 10px;border-radius:6px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:0.4px}
.badge-green{background:#0f5132;color:#a3e635}
.badge-yellow{background:#78350f;color:#fde047}
.badge-red{background:#7f1d1d;color:#fca5a5}
.badge-gray{background:#334155;color:#cbd5e1}
.drive-name{font-size:20px;font-weight:700;margin-bottom:2px}
.drive-sub{color:#94a3b8;font-size:12px;margin-bottom:14px}
.progress{background:#0b1220;border-radius:8px;height:28px;overflow:hidden;position:relative;border:1px solid #1f2937}
.progress-fill{height:100%;background:linear-gradient(90deg,#3b82f6,#06b6d4);transition:width 0.6s}
.progress-fill.warning{background:linear-gradient(90deg,#ca8a04,#eab308)}
.progress-fill.danger{background:linear-gradient(90deg,#dc2626,#ef4444)}
.progress-text{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:12px;font-weight:700}
.stats{display:flex;gap:24px;margin-top:14px}
.stat strong{display:block;color:#e2e8f0;font-size:16px}
.stat-label{color:#94a3b8;font-size:11px;text-transform:uppercase}
.snaps{max-height:260px;overflow-y:auto}
.snap-row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #1f2937;font-size:12px;align-items:center}
.snap-row:last-child{border-bottom:none}
.snap-meta{color:#94a3b8}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;padding:9px 8px;color:#94a3b8;font-weight:600;border-bottom:1px solid #1f2937;font-size:10px;text-transform:uppercase}
td{padding:10px 8px;border-bottom:1px solid #1f2937}
.log{background:#020617;border-radius:10px;padding:14px;max-height:240px;overflow-y:auto;font-family:'Consolas',monospace;font-size:11px;line-height:1.5;color:#94a3b8}
.log-err{color:#fca5a5}
.log-warn{color:#fde047}
.footer{text-align:center;color:#475569;font-size:11px;margin-top:24px}
.empty{color:#475569;text-align:center;padding:24px;font-style:italic;font-size:13px}
code{background:#1f2937;padding:2px 6px;border-radius:4px;font-size:11px}
@media(max-width:768px){.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="container">

<header>
  <div class="logo">
    <div class="logo-icon">$([char]0x1F6DF)</div>
    <div>
      <h1>Claude Lifeboat</h1>
      <div class="subtitle">$(Get-Date -Format 'dddd, MMMM dd yyyy &middot; HH:mm:ss')</div>
    </div>
  </div>
  <div class="subtitle">auto-refreshes every 60s</div>
</header>

<div class="banner">
  <div class="banner-dot"></div>
  <div class="banner-text">$statusText</div>
</div>

<div class="grid">
"@

    # Primary drive card
    $html += '<div class="card">'
    $html += "<div class=`"drive-name`">PRIMARY &middot; $($primaryStats.Letter):</div>"
    $html += "<div class=`"drive-sub`">$([System.Web.HttpUtility]::HtmlEncode($Config.Primary.Root))</div>"
    if ($primaryStats.Available) {
        $cls = if ($primaryStats.PercentUsed -gt 90) { 'danger' } elseif ($primaryStats.PercentUsed -gt 75) { 'warning' } else { '' }
        $freeGB = [math]::Round($primaryStats.FreeBytes / 1GB, 1)
        $usedGB = [math]::Round($primaryStats.UsedBytes / 1GB, 1)
        $totalGB = [math]::Round($primaryStats.TotalBytes / 1GB, 1)
        $html += "<div class=`"progress`"><div class=`"progress-fill $cls`" style=`"width:$($primaryStats.PercentUsed)%`"></div><div class=`"progress-text`">$($primaryStats.PercentUsed)% used</div></div>"
        $html += "<div class=`"stats`"><div class=`"stat`"><strong>$freeGB GB</strong><div class=`"stat-label`">free</div></div><div class=`"stat`"><strong>$usedGB GB</strong><div class=`"stat-label`">used</div></div><div class=`"stat`"><strong>$totalGB GB</strong><div class=`"stat-label`">total</div></div></div>"
    } else {
        $html += '<div class="empty">Drive not available</div>'
    }
    $html += '</div>'

    # Archive drive card
    $html += '<div class="card">'
    if ($archiveStats) {
        $html += "<div class=`"drive-name`">ARCHIVE &middot; $($archiveStats.Letter):</div>"
        $html += "<div class=`"drive-sub`">$([System.Web.HttpUtility]::HtmlEncode($Config.Archive.Root))</div>"
        if ($archiveStats.Available) {
            $cls = if ($archiveStats.PercentUsed -gt 90) { 'danger' } elseif ($archiveStats.PercentUsed -gt 75) { 'warning' } else { '' }
            $freeGB = [math]::Round($archiveStats.FreeBytes / 1GB, 1)
            $usedGB = [math]::Round($archiveStats.UsedBytes / 1GB, 1)
            $totalGB = [math]::Round($archiveStats.TotalBytes / 1GB, 1)
            $html += "<div class=`"progress`"><div class=`"progress-fill $cls`" style=`"width:$($archiveStats.PercentUsed)%`"></div><div class=`"progress-text`">$($archiveStats.PercentUsed)% used</div></div>"
            $html += "<div class=`"stats`"><div class=`"stat`"><strong>$freeGB GB</strong><div class=`"stat-label`">free</div></div><div class=`"stat`"><strong>$usedGB GB</strong><div class=`"stat-label`">used</div></div><div class=`"stat`"><strong>$totalGB GB</strong><div class=`"stat-label`">total</div></div></div>"
        } else {
            $html += '<div class="empty">Drive unplugged<br><span style="font-size:11px">Plug in to auto-sync from PRIMARY</span></div>'
        }
    } else {
        $html += '<div class="drive-name">ARCHIVE</div><div class="empty">Not configured<br><code>lifeboat install</code> to add one</div>'
    }
    $html += '</div></div>'

    # Health checks
    if ($statusJson -and $statusJson.Checks) {
        $html += '<div class="card"><h2>Health Checks</h2>'
        foreach ($c in $statusJson.Checks) {
            $badgeCls = "badge-$($c.Status)"
            $detail = if ($c.Detail) { "<div class=`"row-detail`">$([System.Web.HttpUtility]::HtmlEncode($c.Detail))</div>" } else { '' }
            $html += "<div class=`"row`"><div><div class=`"row-name`">$([System.Web.HttpUtility]::HtmlEncode($c.Name))</div>$detail</div><span class=`"badge $badgeCls`">$([System.Web.HttpUtility]::HtmlEncode($c.Message))</span></div>"
        }
        $html += '</div>'
    }

    # Tasks
    $html += '<div class="card"><h2>Scheduled Tasks</h2><table><tr><th>Task</th><th>State</th><th>Last Run</th><th>Result</th><th>Next Run</th></tr>'
    foreach ($t in $tasks) {
        $resultBadge = if ($t.Result -eq 0) { 'badge-green'; $resultText = 'OK' } elseif ($t.Result -eq 267011 -or $t.Result -eq 267009) { 'badge-gray'; $resultText = 'pending' } else { 'badge-red'; $resultText = "0x{0:X}" -f $t.Result }
        if ($t.Result -eq 0) { $resultText = 'OK' }
        elseif ($t.Result -eq 267011 -or $t.Result -eq 267009) { $resultText = 'pending' }
        else { $resultText = "0x{0:X}" -f $t.Result }
        $stateBadge = if ($t.State -in @('Ready','Running')) { 'badge-green' } else { 'badge-yellow' }
        $html += "<tr><td>$($t.Name)</td><td><span class=`"badge $stateBadge`">$($t.State)</span></td><td>$($t.LastRun)</td><td><span class=`"badge $resultBadge`">$resultText</span></td><td>$($t.NextRun)</td></tr>"
    }
    $html += '</table></div>'

    # Snapshot inventories
    $html += '<div class="grid"><div class="card"><h2>Primary Snapshots</h2><div class="snaps">'
    if ($primarySnaps.Count -eq 0) { $html += '<div class="empty">No snapshots yet</div>' }
    foreach ($s in $primarySnaps) {
        $kindBadge = switch ($s.Kind) { 'latest' { 'badge-green' } 'weekly' { 'badge-yellow' } default { 'badge-gray' } }
        $label = if ($s.Date -eq '-' -or -not $s.Date) { $s.Kind } else { "$($s.Kind) $($s.Date)" }
        $html += "<div class=`"snap-row`"><div><span class=`"badge $kindBadge`">$label</span></div><div class=`"snap-meta`">$($s.SizeMB) MB &middot; $($s.Time.ToString('MM/dd HH:mm'))</div></div>"
    }
    $html += '</div></div><div class="card"><h2>Archive Snapshots</h2><div class="snaps">'
    if ($archiveSnaps.Count -eq 0) {
        if ($archiveStats -and -not $archiveStats.Available) {
            $html += '<div class="empty">Archive drive unplugged</div>'
        } else {
            $html += '<div class="empty">No snapshots yet</div>'
        }
    }
    foreach ($s in $archiveSnaps) {
        $kindBadge = switch ($s.Kind) { 'latest' { 'badge-green' } 'weekly' { 'badge-yellow' } default { 'badge-gray' } }
        $label = if ($s.Date -eq '-' -or -not $s.Date) { $s.Kind } else { "$($s.Kind) $($s.Date)" }
        $html += "<div class=`"snap-row`"><div><span class=`"badge $kindBadge`">$label</span></div><div class=`"snap-meta`">$($s.SizeMB) MB &middot; $($s.Time.ToString('MM/dd HH:mm'))</div></div>"
    }
    $html += '</div></div></div>'

    # Log
    $html += '<div class="card"><h2>Today''s Log</h2><div class="log">'
    if ($recentLog.Count -eq 0) {
        $html += '<div class="empty">No log entries yet</div>'
    } else {
        foreach ($line in $recentLog) {
            $cls = if ($line -match "\[ERROR\]") { 'log-err' } elseif ($line -match "\[WARN\]") { 'log-warn' } else { '' }
            $html += "<div class=`"$cls`">$([System.Web.HttpUtility]::HtmlEncode($line))</div>"
        }
    }
    $html += '</div></div>'

    $html += @"
<div class="footer">
  Claude Lifeboat &middot; Open this file anytime to check status &middot; <code>lifeboat status</code> for CLI version
</div>
</div>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
}
