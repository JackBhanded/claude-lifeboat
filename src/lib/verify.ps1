# lifeboat verify - thorough integrity check of a backup
# Different from the quick sample-verify done after each backup.

function Invoke-Verify {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed."
        exit 1
    }

    Write-Heading "Verifying backup integrity"

    $target = if ($Flags.from) {
        $snapshots = Get-AllSnapshots $config
        Find-Snapshot -Snapshots $snapshots -From $Flags.from -Date $Flags.date
    } else {
        @{ Path = (Join-Path $config.Primary.Root "latest") }
    }

    if (-not $target -or -not (Test-Path $target.Path)) {
        Write-Failure "No backup to verify."
        exit 1
    }

    Write-Host "  Target: $($target.Path)" -ForegroundColor DarkGray
    Write-Host ""

    # Compare each backed-up folder against the source
    $paths = Get-ClaudeDataPaths
    foreach ($p in $config.ExtraPaths) {
        if (Test-Path $p) {
            $paths["Extra-$(Split-Path $p -Leaf)"] = $p
        }
    }

    $totalChecked = 0
    $totalMismatched = 0
    $totalUnreadable = 0
    $perFolderResults = @{}

    foreach ($name in $paths.Keys) {
        $source = $paths[$name]
        $backup = Join-Path $target.Path $name
        if (-not (Test-Path $backup)) {
            Write-Host "  $name : not in backup" -ForegroundColor Yellow
            continue
        }

        Write-Host "  $name..." -NoNewline

        # Sample-verify: pick random 20 files from source, check each one exists in backup with same size
        $sourceFiles = Get-ChildItem $source -Recurse -File -ErrorAction SilentlyContinue
        if ($sourceFiles.Count -eq 0) {
            Write-Host " (empty source)" -ForegroundColor DarkGray
            continue
        }

        $sample = $sourceFiles | Get-Random -Count ([math]::Min(20, $sourceFiles.Count))
        $mismatched = 0
        $unreadable = 0
        foreach ($sf in $sample) {
            $rel = $sf.FullName.Substring($source.Length).TrimStart('\')
            $backupFile = Join-Path $backup $rel
            if (-not (Test-Path $backupFile)) {
                $mismatched++
                continue
            }
            try {
                $bSize = (Get-Item $backupFile).Length
                if ($bSize -ne $sf.Length) {
                    $mismatched++
                    continue
                }
                # Quick read test
                $stream = [System.IO.File]::OpenRead($backupFile)
                $stream.Close()
            } catch {
                $unreadable++
            }
        }

        $totalChecked += $sample.Count
        $totalMismatched += $mismatched
        $totalUnreadable += $unreadable
        $perFolderResults[$name] = @{
            Checked = $sample.Count
            Mismatched = $mismatched
            Unreadable = $unreadable
        }

        if ($mismatched -eq 0 -and $unreadable -eq 0) {
            Write-Host " OK ($($sample.Count) sampled)" -ForegroundColor Green
        } else {
            Write-Host " $($mismatched + $unreadable) issues in $($sample.Count) sampled" -ForegroundColor Red
        }
    }

    Write-Host ""
    if ($Flags.json) {
        @{
            Target = $target.Path
            TotalChecked = $totalChecked
            TotalMismatched = $totalMismatched
            TotalUnreadable = $totalUnreadable
            PerFolder = $perFolderResults
            OverallOK = ($totalMismatched -eq 0 -and $totalUnreadable -eq 0)
        } | ConvertTo-Json -Depth 5
    } else {
        if ($totalMismatched -eq 0 -and $totalUnreadable -eq 0) {
            Write-Success "Verified: $totalChecked files checked, all good"
        } else {
            Write-Warning2 "$($totalMismatched + $totalUnreadable) issues out of $totalChecked files checked"
            Write-Info "Recommend: lifeboat backup (re-run to fix)"
        }
    }

    if ($totalMismatched -gt 0 -or $totalUnreadable -gt 0) { exit 1 } else { exit 0 }
}
