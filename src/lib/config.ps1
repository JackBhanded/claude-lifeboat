# Configuration defaults and validation

function Get-DefaultConfig {
    return @{
        SchemaVersion = 1
        Primary = @{
            Root = ""
            RetentionDailies = 2
        }
        Archive = @{
            Root = ""           # empty means no archive configured
            RetentionDailies = 5
            RetentionWeeklies = 4
        }
        ExtraPaths = @()
        BackupMode = "lean"   # "lean" skips the regenerable VM OS image (rootfs/smol-bin); "full" keeps everything
        Schedule = @{
            HourlyEnabled = $true
            OnSleep = $true
            OnLogon = $true
            OnIdle = $true
            OnDriveConnect = $true
        }
        Notifications = @{
            Enabled = $true
            HealthCheckIntervalHours = 2
        }
        Advanced = @{
            ExcludePatterns = @("*.tmp", "*.lock", "*.dump")
            MaxBackupDurationMinutes = 30
            VerifyAfterBackup = $true   # quick integrity check
            VerifySampleSize = 5         # randomly verify 5 files per backup
        }
        Version = $script:LifeboatVersion
        CreatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

function Suggest-PrimaryDrive {
    # Recommend the best drive for primary: prefer D: if it has decent space,
    # else fall back to C: with a folder under user profile.
    $candidates = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Free -gt 10GB } |
        Sort-Object @{Expression={ if ($_.Name -eq 'D') {0} elseif ($_.Name -ne 'C') {1} else {2} }}, Free -Descending

    if ($candidates) { return $candidates[0].Name + ":" }
    return "C:"
}

function Suggest-ArchiveDrive {
    # Look for removable drives (USB/external)
    $removables = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=2 OR DriveType=3" |
        Where-Object { $_.DeviceID -ne 'C:' -and $_.DeviceID -ne $script:SuggestedPrimary -and $_.FreeSpace -gt 20GB }
    if ($removables) { return $removables[0].DeviceID }
    return $null
}
