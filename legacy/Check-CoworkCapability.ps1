# =====================================================================
# Check-CoworkCapability.ps1
# Checks every layer Cowork needs to start a VM
# Run in PowerShell as Administrator
# =====================================================================

Write-Host "`n=== COWORK CAPABILITY CHECK ===" -ForegroundColor Cyan

# 1. Windows edition (must be Pro/Enterprise/Education, NOT Home)
$os = Get-WmiObject Win32_OperatingSystem
Write-Host "`n[1] Windows Edition:" -ForegroundColor Yellow
Write-Host "    $($os.Caption)"
Write-Host "    Version: $($os.Version)  Build: $($os.BuildNumber)"
$isHome = $os.Caption -match "Home"
if ($isHome) {
    Write-Host "    BLOCKER: Home editions do not support Hyper-V" -ForegroundColor Red
} else {
    Write-Host "    OK: Edition supports Hyper-V" -ForegroundColor Green
}

# 2. CPU virtualization capabilities
Write-Host "`n[2] CPU Virtualization (from systeminfo):" -ForegroundColor Yellow
$si = systeminfo | Select-String "Virtualization|VM Monitor|Second Level|Data Execution|hypervisor"
$si | ForEach-Object { Write-Host "    $_" }

# 3. Is a hypervisor currently running?
Write-Host "`n[3] Hypervisor Present:" -ForegroundColor Yellow
$hv = (Get-WmiObject Win32_ComputerSystem).HypervisorPresent
Write-Host "    HypervisorPresent: $hv"

# 4. Windows optional features
Write-Host "`n[4] Required Windows Features:" -ForegroundColor Yellow
$features = @("Microsoft-Hyper-V-All","Microsoft-Hyper-V","VirtualMachinePlatform","HypervisorPlatform")
foreach ($f in $features) {
    $state = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
    if ($state) {
        $color = if ($state.State -eq "Enabled") { "Green" } else { "Red" }
        Write-Host ("    {0,-30} {1}" -f $f, $state.State) -ForegroundColor $color
    } else {
        Write-Host ("    {0,-30} NOT AVAILABLE on this edition" -f $f) -ForegroundColor Red
    }
}

# 5. Boot config
Write-Host "`n[5] Hypervisor Launch Type:" -ForegroundColor Yellow
bcdedit /enum | Select-String "hypervisorlaunchtype" | ForEach-Object { Write-Host "    $_" }

# 6. CoworkVMService
Write-Host "`n[6] CoworkVMService:" -ForegroundColor Yellow
$svc = Get-Service CoworkVMService -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "    Status: $($svc.Status)   StartType: $($svc.StartType)"
} else {
    Write-Host "    Service not found (Claude Desktop not installed?)" -ForegroundColor Red
}

# 7. Memory and CPU count
Write-Host "`n[7] Hardware Resources:" -ForegroundColor Yellow
$cs = Get-WmiObject Win32_ComputerSystem
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$cores = $cs.NumberOfLogicalProcessors
Write-Host "    Total RAM: ${ramGB} GB"
Write-Host "    Logical CPUs: $cores"
if ($ramGB -lt 8) { Write-Host "    WARNING: 8GB+ recommended" -ForegroundColor Yellow }

# 8. Latest Cowork log error
Write-Host "`n[8] Latest Cowork Service Log Errors:" -ForegroundColor Yellow
$log = "C:\ProgramData\Claude\Logs\cowork-service.log"
if (Test-Path $log) {
    Get-Content $log -Tail 200 | Select-String -Pattern "ErrorMessage|not installed|failed|0x8" | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
} else {
    Write-Host "    No log file found"
}

# VERDICT
Write-Host "`n=== VERDICT ===" -ForegroundColor Cyan
if ($isHome) {
    Write-Host "Cowork CANNOT fully run on this machine without upgrading Windows." -ForegroundColor Red
    Write-Host "Reason: Hyper-V is a Pro/Enterprise/Education feature." -ForegroundColor Red
    Write-Host "Fix: Upgrade to Windows 10/11 Pro, then enable Hyper-V." -ForegroundColor Yellow
} else {
    Write-Host "Edition supports Cowork. Check items above for what's still missing." -ForegroundColor Green
}
