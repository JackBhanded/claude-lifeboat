# lifeboat doctor - diagnose and auto-fix common issues

function Invoke-Doctor {
    param($Flags)

    Write-Heading "Lifeboat Doctor"
    Write-Host "  Running diagnostics and auto-fixing what I can..."
    Write-Host ""

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed. Run: lifeboat install"
        return
    }

    $fixed = 0
    $cantfix = 0

    # ---- Check 1: Are scheduled tasks present? ----
    Write-Host "  [1] Scheduled tasks..." -NoNewline
    $tasks = Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue
    $expectedCount = 4 + ($(if ($config.Archive.Root) { 1 } else { 0 })) + ($(if ($config.Notifications.Enabled) { 1 } else { 0 }))
    if (-not $tasks -or $tasks.Count -lt $expectedCount) {
        Write-Host " MISSING" -ForegroundColor Red
        Write-Host "      Re-registering tasks..." -NoNewline
        if (-not (Test-IsAdmin)) {
            Write-Host " can't (need admin)" -ForegroundColor Red
            Write-Info "Re-run as Administrator to fix this."
            $cantfix++
        } else {
            try {
                Register-LifeboatTasks
                Write-Host " fixed" -ForegroundColor Green
                $fixed++
            } catch {
                Write-Host " failed: $_" -ForegroundColor Red
                $cantfix++
            }
        }
    } else {
        Write-Host " OK ($($tasks.Count) tasks)" -ForegroundColor Green
    }

    # ---- Check 2: Are any tasks disabled? ----
    Write-Host "  [2] Task states..." -NoNewline
    $disabled = $tasks | Where-Object { $_.State -eq 'Disabled' }
    if ($disabled) {
        Write-Host " $($disabled.Count) disabled" -ForegroundColor Yellow
        foreach ($d in $disabled) {
            Write-Host "      Re-enabling $($d.TaskName)..." -NoNewline
            try {
                Enable-ScheduledTask -TaskName $d.TaskName | Out-Null
                Write-Host " fixed" -ForegroundColor Green
                $fixed++
            } catch {
                Write-Host " failed" -ForegroundColor Red
                $cantfix++
            }
        }
    } else {
        Write-Host " OK" -ForegroundColor Green
    }

    # ---- Check 3: Backup root exists? ----
    Write-Host "  [3] Primary backup root..." -NoNewline
    if (-not (Test-DrivePath $config.Primary.Root)) {
        Write-Host " drive missing" -ForegroundColor Red
        Write-Info "Primary drive $($config.Primary.Root) not available."
        Write-Info "Check drive letter, then re-run: lifeboat install"
        $cantfix++
    } elseif (-not (Test-Path $config.Primary.Root)) {
        Write-Host " folder missing, creating..." -NoNewline
        try {
            New-Item -ItemType Directory -Path $config.Primary.Root -Force | Out-Null
            Write-Host " fixed" -ForegroundColor Green
            $fixed++
        } catch {
            Write-Host " failed" -ForegroundColor Red
            $cantfix++
        }
    } else {
        Write-Host " OK" -ForegroundColor Green
    }

    # ---- Check 4: lifeboat-runner exists at install location ----
    Write-Host "  [4] Runner script..." -NoNewline
    $runner = Join-Path $script:LifeboatHome "lifeboat-runner.ps1"
    if (-not (Test-Path $runner)) {
        Write-Host " missing" -ForegroundColor Red
        Write-Info "Re-run: lifeboat install"
        $cantfix++
    } else {
        Write-Host " OK" -ForegroundColor Green
    }

    # ---- Check 5: Most recent backup actually has files? ----
    Write-Host "  [5] Latest backup contents..." -NoNewline
    $latest = Join-Path $config.Primary.Root "latest"
    if (-not (Test-Path $latest)) {
        Write-Host " no backup yet" -ForegroundColor Yellow
        Write-Info "Run: lifeboat backup"
    } else {
        $folders = Get-ChildItem $latest -Directory
        if ($folders.Count -eq 0) {
            Write-Host " empty" -ForegroundColor Red
            Write-Info "Try: lifeboat backup"
            $cantfix++
        } else {
            $totalFiles = (Get-ChildItem $latest -Recurse -File -ErrorAction SilentlyContinue).Count
            Write-Host " OK ($($folders.Count) folders, $totalFiles files)" -ForegroundColor Green
        }
    }

    # ---- Check 6: Is CoworkVMService present? (informational) ----
    Write-Host "  [6] Cowork service..." -NoNewline
    $svc = Get-Service CoworkVMService -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host " present ($($svc.Status))" -ForegroundColor Green
    } else {
        Write-Host " not installed" -ForegroundColor Yellow
        Write-Info "Claude Desktop may not be installed - lifeboat will still backup what's there"
    }

    # ---- Check 7: PowerShell execution policy ----
    Write-Host "  [7] Execution policy..." -NoNewline
    $policy = Get-ExecutionPolicy -Scope LocalMachine
    if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
        Write-Host " too strict ($policy)" -ForegroundColor Yellow
        if (Test-IsAdmin) {
            Write-Host "      Setting RemoteSigned..." -NoNewline
            try {
                Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force
                Write-Host " fixed" -ForegroundColor Green
                $fixed++
            } catch {
                Write-Host " failed: $_" -ForegroundColor Red
                $cantfix++
            }
        } else {
            Write-Info "Run as admin: Set-ExecutionPolicy -Scope LocalMachine RemoteSigned"
            $cantfix++
        }
    } else {
        Write-Host " OK ($policy)" -ForegroundColor Green
    }

    Write-Host ""
    if ($fixed -gt 0) {
        Write-Success "Fixed $fixed issue(s)"
    }
    if ($cantfix -gt 0) {
        Write-Warning2 "Couldn't auto-fix $cantfix issue(s) - see above"
    }
    if ($fixed -eq 0 -and $cantfix -eq 0) {
        Write-Success "All systems healthy"
    }
    Write-Host ""
}
