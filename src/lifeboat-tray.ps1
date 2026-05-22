<#
  Claude Lifeboat - system tray companion.

  A quiet always-on tray icon that's also a status light (green = healthy,
  amber = backups gone stale, red = last run had failures). Right-click for a
  control panel: open the dashboard, run an on-demand backup or restore, view
  logs, open the backup folder, pause/resume the schedule, and exit.

  IMPORTANT: the tray and the scheduled backups are independent. Backups run
  via Windows Task Scheduler whether or not this tray is open.
    - "Exit"                       closes the tray; backups keep running.
    - "Exit & stop auto backups"   closes the tray AND disables the schedule.

  Launch:  lifeboat tray   (install also registers it to start at logon)
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Win32 to release unmanaged icon handles created by Bitmap.GetHicon()
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class IconUtil {
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@ -ErrorAction SilentlyContinue

$script:LifeboatHome = "$env:LOCALAPPDATA\ClaudeLifeboat"
$script:ConfigPath   = Join-Path $LifeboatHome "config.json"
$script:LogDir       = Join-Path $LifeboatHome "logs"
$script:ScriptRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:CliPath      = Join-Path $ScriptRoot "lifeboat.ps1"
$script:LastColorKey = ""
$script:LastIconHandle = [IntPtr]::Zero

# ---------------------------------------------------------------------------
# Status helpers
# ---------------------------------------------------------------------------
function Get-LifeboatStatus {
    try {
        $cfg = Get-Content $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $statusFile = Join-Path $cfg.Primary.Root "status.json"
        if (Test-Path $statusFile) {
            $s = Get-Content $statusFile -Raw | ConvertFrom-Json
            return @{ Config = $cfg; Status = $s }
        }
        return @{ Config = $cfg; Status = $null }
    } catch {
        return @{ Config = $null; Status = $null }
    }
}

function Get-FailureCount($status) {
    # PowerShell serializes an empty failures list to JSON null, and @($null)
    # has Count 1 - so we must filter out empty/null entries before counting.
    if (-not $status) { return 0 }
    return (@($status.Failures) | Where-Object { $_ }).Count
}

function Get-HealthKey($status) {
    # Returns 'green' | 'amber' | 'red' | 'gray'
    if (-not $status) { return 'gray' }
    try {
        if ((Get-FailureCount $status) -gt 0) { return 'red' }
        $age = ((Get-Date) - [DateTime]::Parse($status.LastRun)).TotalHours
        if ($age -gt 6) { return 'amber' }
        return 'green'
    } catch { return 'gray' }
}

function Get-StatusText($status) {
    if (-not $status) { return "Claude Lifeboat - no backup yet" }
    try {
        $age = (Get-Date) - [DateTime]::Parse($status.LastRun)
        $rel =
            if ($age.TotalMinutes -lt 1) { "just now" }
            elseif ($age.TotalMinutes -lt 60) { "$([math]::Round($age.TotalMinutes))m ago" }
            elseif ($age.TotalHours -lt 24) { "$([math]::Round($age.TotalHours,1))h ago" }
            else { "$([math]::Round($age.TotalDays,1))d ago" }
        if ((Get-FailureCount $status) -gt 0) { return "Claude Lifeboat - last backup had issues ($rel)" }
        return "Claude Lifeboat - last backup $rel"
    } catch { return "Claude Lifeboat" }
}

function New-BuoyIcon([string]$key) {
    # A proper life-ring glyph, so Lifeboat is easy to tell apart from the other
    # fleet tools at a glance in the tray. It doubles as a status light: the outer
    # ring and the four lashings carry the health colour (green / amber / red /
    # gray), while the inner hub stays Claude coral so it always reads as ours.
    $ring = switch ($key) {
        'green' { [System.Drawing.Color]::FromArgb(0x2F,0x85,0x5A) }
        'amber' { [System.Drawing.Color]::FromArgb(0xC7,0x7F,0x2E) }
        'red'   { [System.Drawing.Color]::FromArgb(0xC5,0x30,0x30) }
        default { [System.Drawing.Color]::FromArgb(0x8A,0x85,0x7C) }
    }
    $coral = [System.Drawing.Color]::FromArgb(0xD9,0x77,0x57)
    $bmp = New-Object System.Drawing.Bitmap 32,32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # Outer ring (status colour) — the buoy body.
    $outer = New-Object System.Drawing.Pen $ring, 4.5
    $g.DrawEllipse($outer, 4, 4, 24, 24)

    # Inner ring (Claude coral) — the open hole / hub.
    $inner = New-Object System.Drawing.Pen $coral, 3
    $g.DrawEllipse($inner, 11, 11, 10, 10)

    # Four short lashings (N/S/E/W) bridging hub and ring, in the status colour —
    # short segments only, so the centre hole stays open like a real life ring.
    $spoke = New-Object System.Drawing.Pen $ring, 3.5
    $g.DrawLine($spoke, 16, 5.5, 16, 10.5)         # north
    $g.DrawLine($spoke, 16, 21.5, 16, 26.5)        # south
    $g.DrawLine($spoke, 5.5, 16, 10.5, 16)         # west
    $g.DrawLine($spoke, 21.5, 16, 26.5, 16)        # east

    $outer.Dispose(); $inner.Dispose(); $spoke.Dispose(); $g.Dispose()
    $hicon = $bmp.GetHicon()
    $bmp.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    return @{ Icon = $icon; Handle = $hicon }
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
function Start-Cli([string]$arguments, [switch]$Visible) {
    $full = "-NoExit -ExecutionPolicy Bypass -File `"$script:CliPath`" $arguments"
    if ($Visible) {
        Start-Process powershell.exe -ArgumentList $full
    } else {
        Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:CliPath`" $arguments" -WindowStyle Hidden
    }
}

function Get-ScheduleEnabled {
    try {
        $t = Get-ScheduledTask -TaskName "ClaudeLifeboat-Hourly" -ErrorAction SilentlyContinue
        return ($t -and $t.State -ne 'Disabled')
    } catch { return $true }
}

function Set-ScheduleEnabled([bool]$enabled) {
    try {
        Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.TaskName -eq 'ClaudeLifeboat-Tray') { return }   # never pause the tray itself
            if ($enabled) { Enable-ScheduledTask -TaskName $_.TaskName | Out-Null }
            else          { Disable-ScheduledTask -TaskName $_.TaskName | Out-Null }
        }
        return $true
    } catch { return $false }
}

function Get-TargetDrives {
    # Drives we can offer for an on-demand backup: ready, not the system drive,
    # not a CD/DVD.
    $sys = $env:SystemDrive
    $out = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            try {
                if (-not $d.IsReady) { continue }
                $letter = $d.Name.TrimEnd('\')
                if ($letter -eq $sys) { continue }
                if ($d.DriveType -eq 'CDRom') { continue }
                $freeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
                $label = if ($d.VolumeLabel) { $d.VolumeLabel } else { "$($d.DriveType)" }
                $out += [PSCustomObject]@{ Letter = $letter; FreeGB = $freeGB; Label = $label }
            } catch {}
        }
    } catch {}
    return $out
}

# ---------------------------------------------------------------------------
# Build the tray
# ---------------------------------------------------------------------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$initial = New-BuoyIcon (Get-HealthKey (Get-LifeboatStatus).Status)
$notify.Icon = $initial.Icon
$script:LastIconHandle = $initial.Handle
$notify.Text = "Claude Lifeboat"
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miStatus  = New-Object System.Windows.Forms.ToolStripMenuItem("Claude Lifeboat"); $miStatus.Enabled = $false
$miDash    = New-Object System.Windows.Forms.ToolStripMenuItem("Open dashboard")
$miBackup  = New-Object System.Windows.Forms.ToolStripMenuItem("Back up now")
$miBackupTo= New-Object System.Windows.Forms.ToolStripMenuItem("Back up to a drive...")
$miRestore = New-Object System.Windows.Forms.ToolStripMenuItem("Restore...")
$miLogs    = New-Object System.Windows.Forms.ToolStripMenuItem("View today's log")
$miFolder  = New-Object System.Windows.Forms.ToolStripMenuItem("Open backup folder")
$miPause   = New-Object System.Windows.Forms.ToolStripMenuItem("Pause automatic backups")
$miExit    = New-Object System.Windows.Forms.ToolStripMenuItem("Exit  (backups keep running)")
$miExitStop= New-Object System.Windows.Forms.ToolStripMenuItem("Exit & stop automatic backups")

$miDash.add_Click({ Start-Cli "dashboard" })
$miBackup.add_Click({ Start-Cli "backup" -Visible })
$miRestore.add_Click({ Start-Cli "restore --preview" -Visible })
$miLogs.add_Click({
    $log = Join-Path $script:LogDir ("lifeboat-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    if (Test-Path $log) { Start-Process notepad.exe $log } else { Start-Process explorer.exe $script:LogDir }
})
$miFolder.add_Click({
    $r = (Get-LifeboatStatus).Config.Primary.Root
    if ($r -and (Test-Path $r)) { Start-Process explorer.exe $r }
})
$miPause.add_Click({
    if (Get-ScheduleEnabled) {
        if (Set-ScheduleEnabled $false) {
            $notify.ShowBalloonTip(3000, "Claude Lifeboat", "Automatic backups paused. Your existing backups are untouched - resume anytime.", [System.Windows.Forms.ToolTipIcon]::Info)
        }
    } else {
        if (Set-ScheduleEnabled $true) {
            $notify.ShowBalloonTip(3000, "Claude Lifeboat", "Automatic backups resumed. Welcome back aboard.", [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
})
$miExit.add_Click({
    $notify.Visible = $false; $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$miExitStop.add_Click({
    # Confirm first - this is the one action that turns OFF protection, so we
    # don't want it triggered by a stray click.
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "This stops your AUTOMATIC backups and closes the tray." + [Environment]::NewLine +
        "Your existing backups stay safe, and you can turn automatic backups back on anytime." + [Environment]::NewLine + [Environment]::NewLine +
        "Are you sure?",
        "Stop automatic backups?",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Set-ScheduleEnabled $false | Out-Null
    $notify.ShowBalloonTip(5000, "Claude Lifeboat", "Automatic backups stopped. To turn them back on, open Claude Lifeboat again and click 'Resume automatic backups'.", [System.Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep -Milliseconds 1500
    $notify.Visible = $false; $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$sep = { New-Object System.Windows.Forms.ToolStripSeparator }
[void]$menu.Items.Add($miStatus)
[void]$menu.Items.Add((& $sep))
[void]$menu.Items.Add($miDash)
[void]$menu.Items.Add($miBackup)
[void]$menu.Items.Add($miBackupTo)
[void]$menu.Items.Add($miRestore)
[void]$menu.Items.Add((& $sep))
[void]$menu.Items.Add($miLogs)
[void]$menu.Items.Add($miFolder)
[void]$menu.Items.Add((& $sep))
[void]$menu.Items.Add($miPause)
[void]$menu.Items.Add((& $sep))
[void]$menu.Items.Add($miExit)
[void]$menu.Items.Add($miExitStop)

# Refresh the dynamic labels every time the menu opens
$menu.add_Opening({
    $st = (Get-LifeboatStatus).Status
    $miStatus.Text = (Get-StatusText $st)
    $miPause.Text = if (Get-ScheduleEnabled) { "Pause automatic backups" } else { "Resume automatic backups" }

    # Rebuild the "Back up to a drive..." list from whatever's plugged in now.
    $miBackupTo.DropDownItems.Clear()
    $drives = Get-TargetDrives
    if (-not $drives -or $drives.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem("(plug in a drive first)")
        $none.Enabled = $false
        [void]$miBackupTo.DropDownItems.Add($none)
    } else {
        foreach ($drv in $drives) {
            $text = "{0}   {1} - {2} GB free" -f $drv.Letter, $drv.Label, $drv.FreeGB
            $item = New-Object System.Windows.Forms.ToolStripMenuItem($text)
            $lt = $drv.Letter
            $item.add_Click({ Start-Cli "backup --to=$lt" -Visible }.GetNewClosure())
            [void]$miBackupTo.DropDownItems.Add($item)
        }
    }
})

$notify.ContextMenuStrip = $menu
$notify.add_MouseDoubleClick({ Start-Cli "dashboard" })

# Status-light refresh: only rebuild the icon when the health color changes,
# to avoid churning unmanaged icon handles.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.add_Tick({
    try {
        $st = (Get-LifeboatStatus).Status
        $key = Get-HealthKey $st
        $notify.Text = (Get-StatusText $st)
        if ($key -ne $script:LastColorKey) {
            $new = New-BuoyIcon $key
            $notify.Icon = $new.Icon
            if ($script:LastIconHandle -ne [IntPtr]::Zero) { [IconUtil]::DestroyIcon($script:LastIconHandle) | Out-Null }
            $script:LastIconHandle = $new.Handle
            $script:LastColorKey = $key
        }
    } catch {}
})
$timer.Start()

# Run the message loop until an Exit handler calls Application.Exit()
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
