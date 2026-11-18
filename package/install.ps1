# DroidVM GPU driver (unofficial build) - install helper, run elevated.
param([string]$Dir = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:ProgramData 'DroidVM-GPU\install.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
Start-Transcript -Path $log -Append | Out-Null
try {
    try { Checkpoint-Computer -Description 'Before DroidVM GPU driver' -RestorePointType DEVICE_DRIVER_INSTALL } catch { Write-Host "Restore point skipped: $_" }

    $cer = Join-Path $Dir 'DroidVM-GPU-Test.cer'
    foreach ($store in 'Root', 'TrustedPublisher') {
        Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
        Write-Host "Certificate imported into LocalMachine\$store"
    }

    # A test-signed kernel driver only loads with TESTSIGNING enabled.
    $bcd = (bcdedit /enum '{current}') -join "`n"
    if ($bcd -notmatch 'testsigning\s+Yes') {
        bcdedit /set testsigning on | Write-Host
        if ($LASTEXITCODE -ne 0) { throw 'bcdedit /set testsigning on failed (Secure Boot enabled?)' }
        Set-Content (Join-Path (Split-Path $log) 'testsigning-enabled-by-us') '1'
    }

    # Ensure Vulkan runtime loader exists in System32 (ARM64X) and SysWOW64 (x86) on clean Windows 11.
    $drvDir = Join-Path $Dir 'driver'
    $sys32 = Join-Path $env:SystemRoot 'System32'
    $syswow = Join-Path $env:SystemRoot 'SysWOW64'
    if (-not (Test-Path (Join-Path $sys32 'vulkan-1.dll'))) {
        Copy-Item (Join-Path $drvDir 'droidvm_vulkan.dll') (Join-Path $sys32 'vulkan-1.dll') -Force
        Copy-Item (Join-Path $drvDir 'droidvm_vulkan_arm64.dll') $sys32 -Force
        Copy-Item (Join-Path $drvDir 'droidvm_vulkan_arm64ec.dll') $sys32 -Force
        Write-Host "Installed ARM64X vulkan-1.dll into $sys32"
    }
    if ((Test-Path $syswow) -and -not (Test-Path (Join-Path $syswow 'vulkan-1.dll'))) {
        Copy-Item (Join-Path $drvDir 'droidvm_vulkan_x86.dll') (Join-Path $syswow 'vulkan-1.dll') -Force
        Write-Host "Installed x86 vulkan-1.dll into $syswow"
    }

    $inf = Join-Path $drvDir 'virtio_wddm_rs.inf'
    pnputil /add-driver "$inf" /install | Write-Host
    # 0 = ok, 3010 = ok, reboot required; 259 = no matching device (still staged)
    if ($LASTEXITCODE -notin 0, 3010, 259) { throw "pnputil failed with code $LASTEXITCODE" }
    Write-Host 'Done. Reboot is required.'
} finally { Stop-Transcript | Out-Null }
