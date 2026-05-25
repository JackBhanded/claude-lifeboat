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
        # Keep it OFF the Desktop - lives at a stable path you can bookmark.
        Join-Path $script:LifeboatHome "dashboard.html"
    }

    # Make sure the folder exists before we write the HTML into it.
    $dashboardDir = Split-Path $dashboardPath -Parent
    if ($dashboardDir -and -not (Test-Path $dashboardDir)) {
        New-Item -ItemType Directory -Path $dashboardDir -Force | Out-Null
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
        'green' { '#2F855A' }
        'yellow' { '#C77F2E' }
        'red' { '#C53030' }
        default { '#8A857C' }
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
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Instrument+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
:root{
  --bg1:#F7F2E8;--bg2:#EDE3D1;--ink:#1C1712;--muted:#5F564B;--faint:#8C8174;
  --orange:#C8632F;--orange2:#E0875C;--line:rgba(43,39,34,.12);
  --glass:rgba(255,253,249,.45);--glass-strong:rgba(255,253,249,.68);
  --glass-blur:blur(30px) saturate(1.7);
  --sheen:inset 0 1px 0 rgba(255,255,255,.75);
  --shadow:var(--sheen),0 1px 2px rgba(43,39,34,.05),0 12px 30px -14px rgba(43,39,34,.22);
  --radius:16px;--grad:linear-gradient(135deg,var(--orange2),var(--orange));
  --aur1:rgba(217,119,87,.38);--aur2:rgba(217,167,87,.30);--aur3:rgba(63,143,119,.26);
  --bgcss:radial-gradient(1100px 680px at 10% -8%,var(--aur1),transparent 60%),radial-gradient(900px 620px at 92% 4%,var(--aur2),transparent 58%),radial-gradient(1200px 800px at 70% 110%,var(--aur3),transparent 60%),linear-gradient(170deg,var(--bg1),var(--bg2));
}
@media (prefers-color-scheme: dark){:root{
  --bg1:#150F0B;--bg2:#1E1712;--ink:#F7F1E7;--muted:#B7AEA2;--faint:#7A7064;
  --orange:#E0875C;--orange2:#EE9E75;--line:rgba(255,255,255,.10);
  --glass:rgba(38,31,25,.42);--glass-strong:rgba(46,38,30,.64);--glass-blur:blur(32px) saturate(1.6);
  --sheen:inset 0 1px 0 rgba(255,255,255,.12);
  --shadow:var(--sheen),0 1px 2px rgba(0,0,0,.45),0 16px 36px -16px rgba(0,0,0,.7);
  --aur1:rgba(232,145,111,.40);--aur2:rgba(217,167,87,.24);--aur3:rgba(63,143,119,.32);
}}
*{box-sizing:border-box}
body{font-family:"Instrument Sans",-apple-system,'Segoe UI',system-ui,sans-serif;margin:0;padding:34px 24px;color:var(--ink);min-height:100vh;background:var(--bgcss);background-attachment:fixed}
.container{max-width:1080px;margin:0 auto}
header{display:flex;justify-content:space-between;align-items:center;margin-bottom:26px}
.logo{display:flex;align-items:center;gap:14px}
.logo-icon{line-height:1;display:inline-flex;width:46px;height:46px;align-items:center;justify-content:center;border-radius:14px;background:var(--glass-strong);box-shadow:var(--shadow);backdrop-filter:var(--glass-blur);-webkit-backdrop-filter:var(--glass-blur)}
h1{margin:0;font-size:25px;font-weight:700;letter-spacing:-.3px;background:var(--grad);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
.subtitle{color:var(--muted);font-size:13px}
.banner{background:var(--glass-strong);border:1px solid var(--line);border-left:4px solid $statusColor;padding:16px 22px;border-radius:var(--radius);margin-bottom:24px;display:flex;align-items:center;gap:14px;box-shadow:var(--shadow);backdrop-filter:var(--glass-blur);-webkit-backdrop-filter:var(--glass-blur)}
.banner-dot{width:12px;height:12px;border-radius:50%;background:$statusColor;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:0.35}}
.banner-text{font-size:18px;font-weight:700;color:var(--ink)}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin-bottom:22px}
.card{background:var(--glass);border:1px solid var(--line);border-radius:var(--radius);padding:22px;box-shadow:var(--shadow);backdrop-filter:var(--glass-blur);-webkit-backdrop-filter:var(--glass-blur)}
.card h2{margin:0 0 16px;font-size:11px;color:var(--orange);font-weight:700;text-transform:uppercase;letter-spacing:1px}
.row{display:flex;justify-content:space-between;padding:11px 0;border-bottom:1px solid var(--line);align-items:center}
.row:last-child{border-bottom:none}
.row-name{font-weight:600;color:var(--ink)}
.row-detail{color:var(--muted);font-size:12px;margin-top:2px}
.badge{padding:4px 11px;border-radius:8px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:0.4px}
.badge-green{background:rgba(46,125,99,.16);color:#2F7D52}
.badge-yellow{background:rgba(185,126,30,.18);color:#9A6B1C}
.badge-red{background:rgba(182,73,47,.16);color:#B23A30}
.badge-gray{background:rgba(140,131,120,.18);color:var(--muted)}
.drive-name{font-size:18px;font-weight:700;margin-bottom:2px;color:var(--ink)}
.drive-sub{color:var(--muted);font-size:12px;margin-bottom:14px;font-family:"JetBrains Mono",ui-monospace,Consolas,monospace}
.progress{background:rgba(43,39,34,.08);border-radius:8px;height:26px;overflow:hidden;position:relative}
.progress-fill{height:100%;background:var(--grad);transition:width 0.6s}
.progress-fill.warning{background:linear-gradient(135deg,#E7B45E,#B97E1E)}
.progress-fill.danger{background:linear-gradient(135deg,#E2785C,#B6492F)}
.progress-text{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:12px;font-weight:700;color:var(--ink)}
.stats{display:flex;gap:28px;margin-top:14px}
.stat strong{display:block;color:var(--orange);font-size:17px;font-weight:700}
.stat-label{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.4px}
.snaps{max-height:260px;overflow-y:auto}
.snap-row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid var(--line);font-size:12px;align-items:center}
.snap-row:last-child{border-bottom:none}
.snap-meta{color:var(--muted);font-family:"JetBrains Mono",ui-monospace,Consolas,monospace}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;padding:9px 8px;color:var(--orange);font-weight:700;border-bottom:1px solid var(--line);font-size:10px;text-transform:uppercase;letter-spacing:.5px}
td{padding:10px 8px;border-bottom:1px solid var(--line);color:var(--ink)}
.log{background:var(--glass-strong);border:1px solid var(--line);border-radius:12px;padding:14px;max-height:240px;overflow-y:auto;font-family:"JetBrains Mono",'Consolas',monospace;font-size:11px;line-height:1.6;color:var(--muted)}
.log-err{color:#C0392B}
.log-warn{color:#9A6B1C}
.footer{text-align:center;color:var(--faint);font-size:11px;margin-top:28px}
.empty{color:var(--faint);text-align:center;padding:24px;font-style:italic;font-size:13px}
code{background:rgba(200,99,47,.12);padding:2px 7px;border-radius:6px;font-size:11px;color:var(--orange);font-family:"JetBrains Mono",ui-monospace,Consolas,monospace}
@media(max-width:768px){.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="container">

<header>
  <div class="logo">
    <div class="logo-icon"><svg width="36" height="36" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z" fill="#D97757"/></svg></div>
    <div>
      <h1>Claude Lifeboat &#x1F6DF;</h1>
      <div class="subtitle">$(Get-Date -Format 'dddd, MMMM dd yyyy') &middot; $(Get-Date -Format 'HH:mm:ss')</div>
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
