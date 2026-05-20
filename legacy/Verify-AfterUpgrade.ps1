# =====================================================================
# Verify-AfterUpgrade.ps1
# Run this AFTER upgrading to Windows 10 Pro AND enabling Hyper-V
# AND enabling VT-x in BIOS. Confirms everything Cowork needs.
# =====================================================================

Write-Host "`n=== POST-UPGRADE VERIFICATION ===" -ForegroundColor Cyan

$pass = 0; $fail = 0
function Check($name, $condition, $detail) {
    if ($condition) {
        Write-Host "[PASS] $name" -ForegroundColor Green
        if ($detail) { Write-Host "       $detail" -ForegroundColor DarkGray }
        $script:pass++
    } else {
        Write-Host "[FAIL] $name" -ForegroundColor Red
        if ($detail) { Write-Host "       $detail" -ForegroundColor DarkGray }
        $script:fail++
    }
}

# Windows edition is Pro
$caption = (Get-WmiObject Win32_OperatingSystem).Caption
Check "Windows edition is Pro/Enterprise/Education" ($caption -notmatch "Home") $caption

# Hyper-V feature
$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
Check "Hyper-V feature enabled" ($hv -and $hv.State -eq "Enabled") $(if($hv){"State: $($hv.State)"}else{"feature not found"})

# Virtual Machine Platform
$vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
Check "Virtual Machine Platform enabled" ($vmp -and $vmp.State -eq "Enabled") $(if($vmp){"State: $($vmp.State)"})

# Hypervisor Platform
$hp = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction SilentlyContinue
Check "Hypervisor Platform enabled" ($hp -and $hp.State -eq "Enabled") $(if($hp){"State: $($hp.State)"})

# Hypervisor actually running
$hvPresent = (Get-WmiObject Win32_ComputerSystem).HypervisorPresent
Check "Hypervisor is running" $hvPresent "HypervisorPresent: $hvPresent"

# VT-x enabled in firmware
$vtFirmware = systeminfo | Select-String "Virtualization Enabled In Firmware"
$vtOK = $vtFirmware -match "Yes" -or $hvPresent  # if hypervisor present, VT-x must be on
Check "VT-x enabled in BIOS/UEFI" $vtOK $vtFirmware

# CoworkVMService running
$svc = Get-Service CoworkVMService -ErrorAction SilentlyContinue
Check "CoworkVMService running" ($svc -and $svc.Status -eq "Running") $(if($svc){"Status: $($svc.Status)"})

# bcdedit
$bcd = (bcdedit /enum | Select-String "hypervisorlaunchtype").ToString()
Check "Hypervisor launch type is Auto" ($bcd -match "Auto") $bcd

# Cowork log check
$log = "C:\ProgramData\Claude\Logs\cowork-service.log"
if (Test-Path $log) {
    $recent = Get-Content $log -Tail 100
    $hasHyperVError = $recent | Where-Object { $_ -match "Hyper-V is not installed" }
    Check "No recent 'Hyper-V not installed' errors in log" (-not $hasHyperVError) $(if($hasHyperVError){"still seeing the error"}else{"clean"})
}

Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "Passed: $pass" -ForegroundColor Green
Write-Host "Failed: $fail" -ForegroundColor $(if($fail -eq 0){"Green"}else{"Red"})

if ($fail -eq 0) {
    Write-Host "`nEverything checks out. Open Claude Desktop -> Cowork tab. The VM should boot." -ForegroundColor Green
} else {
    Write-Host "`nFix the FAIL items above, then re-run this script." -ForegroundColor Yellow
}
