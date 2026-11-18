# Runs on windows-latest: builds the multi-arch driver package from Linux artifacts,
# creates the catalog, test-signs everything and compiles the installers.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$env_ = @{}; Get-Content versions.env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $env_[$Matches[1]] = $Matches[2] }
$run = if ($env:RUN_NUMBER) { $env:RUN_NUMBER } else { '0' }
$version = "0.2.$run"

$stage = Join-Path $root 'stage'; $drv = Join-Path $stage 'driver'; $dist = Join-Path $root 'dist'
Remove-Item -Recurse -Force $stage, $dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $drv, $dist | Out-Null

# ---- collect binaries (ARM64 + ARM64EC + x86 + ARM64X forwarders)
$sysFile = Get-ChildItem (Join-Path $root 'bin\bin-arm64') -Recurse -Filter 'virtio_wddm_rs.sys' | Select-Object -First 1
if (-not $sysFile) { throw 'Missing virtio_wddm_rs.sys in bin-arm64' }
Copy-Item $sysFile.FullName $drv
foreach ($name in @('bin-arm64', 'bin-arm64ec', 'bin-x86', 'bin-arm64x')) {
    $dir = Join-Path $root "bin\$name"
    if (-not (Test-Path $dir)) { throw "Missing artifact directory: $dir" }
    Get-ChildItem $dir -Recurse -Filter '*.dll' | Copy-Item -Destination $drv -Force
}
Copy-Item package\freedreno_icd.aarch64.json, package\freedreno_icd.x86.json $drv

$expected = @(
    'virtio_wddm_rs.sys',
    'dx11um_virtio.dll', 'dx11um_virtio_arm64.dll', 'dx11um_virtio_arm64ec.dll', 'dx11um_virtio_x86.dll',
    'dx12um_virtio.dll', 'dx12um_virtio_arm64.dll', 'dx12um_virtio_arm64ec.dll', 'dx12um_virtio_x86.dll',
    'vulkan_freedreno.dll', 'vulkan_freedreno_arm64.dll', 'vulkan_freedreno_arm64ec.dll', 'vulkan_freedreno_x86.dll',
    'droidvm_vulkan.dll', 'droidvm_vulkan_arm64.dll', 'droidvm_vulkan_arm64ec.dll', 'droidvm_vulkan_x86.dll',
    'droidvm_opengl.dll', 'droidvm_opengl_arm64.dll', 'droidvm_opengl_arm64ec.dll', 'droidvm_opengl_x86.dll',
    'freedreno_icd.aarch64.json', 'freedreno_icd.x86.json'
)
foreach ($f in $expected) {
    if (-not (Test-Path (Join-Path $drv $f))) { throw "Missing required driver payload file: $f" }
}

# ---- INF
$inf = Get-Content package\virtio_wddm_rs.inx -Raw
$inf = $inf.Replace('%%BUILDDATE%%', (Get-Date).ToUniversalTime().ToString('MM/dd/yyyy'))
$inf = $inf.Replace('%%VERSION%%', "20.15.2.$run")
[IO.File]::WriteAllText((Join-Path $drv 'virtio_wddm_rs.inf'), $inf.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::ASCII)

# ---- tools: Inf2Cat from the WDK NuGet, signtool from the installed SDK
$nuget = Join-Path $root 'wdk-nuget'
if (-not (Test-Path $nuget)) {
    $v = $env_['NUGET_VER']
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.windows.wdk.x64/$v/microsoft.windows.wdk.x64.$v.nupkg" -OutFile wdk.zip
    Expand-Archive wdk.zip $nuget; Remove-Item wdk.zip
}
$inf2cat = Get-ChildItem $nuget -Recurse -Filter Inf2Cat.exe | Select-Object -First 1
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe |
    Where-Object FullName -match '\\x64\\' | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $inf2cat -or -not $signtool) { throw "Inf2Cat=$inf2cat signtool=$signtool" }

# ---- certificate: repo secret if present, otherwise a fresh test cert
$subject = 'CN=DroidVM GPU Test (unofficial build)'
$pfx = Join-Path $stage 'sign.pfx'
$pw = if ($env:SIGN_PFX_PASSWORD) { $env:SIGN_PFX_PASSWORD } else { [guid]::NewGuid().ToString() }
if ($env:SIGN_PFX_BASE64) {
    [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:SIGN_PFX_BASE64))
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($pfx, $pw)
} else {
    $cert = New-SelfSignedCertificate -Subject $subject -Type CodeSigningCert -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(5) `
        -CertStoreLocation Cert:\CurrentUser\My
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password (ConvertTo-SecureString $pw -AsPlainText -Force) | Out-Null
}
Export-Certificate -Cert $cert -FilePath (Join-Path $stage 'DroidVM-GPU-Test.cer') | Out-Null

function Sign($files) {
    & $signtool.FullName sign /fd SHA256 /f $pfx /p $pw $files
    if ($LASTEXITCODE) { throw "signtool failed on $files" }
}
Sign (Get-ChildItem $drv -Include *.sys, *.dll -Recurse).FullName

& $inf2cat.FullName /driver:$drv /os:10_GE_ARM64 /uselocaltime
if ($LASTEXITCODE) { throw 'Inf2Cat failed' }
Sign (Join-Path $drv 'virtio_wddm_rs.cat')

# ---- installers
Copy-Item package\install.ps1, package\uninstall.ps1, package\setup.iss, package\uninstall.iss, package\README-install.txt $stage
Copy-Item LICENSE (Join-Path $stage 'LICENSE.txt')
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { choco install innosetup -y --no-progress | Out-Null; $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
Push-Location $stage
foreach ($iss in 'setup.iss', 'uninstall.iss') { & $iscc /Q "/DAppVersion=$version" $iss; if ($LASTEXITCODE) { throw "ISCC $iss failed" } }
Pop-Location
# ---- diagnostic variant: same package, KMD built with bringup-diagnostics
$diagSysObj = Get-ChildItem (Join-Path $root 'bin\bin-arm64') -Recurse -Filter 'virtio_wddm_rs_diag.sys' | Select-Object -First 1
$diagSys = if ($diagSysObj) { $diagSysObj.FullName } else { $null }
if ($diagSys -and (Test-Path $diagSys)) {
    $drvDiag = Join-Path $stage 'driver-diag'
    Copy-Item $drv $drvDiag -Recurse
    Remove-Item (Join-Path $drvDiag 'virtio_wddm_rs.cat')
    Copy-Item $diagSys (Join-Path $drvDiag 'virtio_wddm_rs.sys') -Force
    Sign (Join-Path $drvDiag 'virtio_wddm_rs.sys')
    & $inf2cat.FullName /driver:$drvDiag /os:10_GE_ARM64 /uselocaltime
    if ($LASTEXITCODE) { throw 'Inf2Cat (diag) failed' }
    Sign (Join-Path $drvDiag 'virtio_wddm_rs.cat')
    Push-Location $stage
    Rename-Item driver driver-normal; Rename-Item driver-diag driver
    & $iscc /Q "/DAppVersion=$version-diag" "/DOutName=DroidVM-GPU-Setup-diag" setup.iss
    if ($LASTEXITCODE) { throw 'ISCC diag failed' }
    Rename-Item driver driver-diag; Rename-Item driver-normal driver
    Pop-Location
    Sign (Join-Path $stage 'DroidVM-GPU-Setup-diag.exe')
    Copy-Item (Join-Path $stage 'DroidVM-GPU-Setup-diag.exe') $dist
}
Sign (Join-Path $stage 'DroidVM-GPU-Setup.exe'), (Join-Path $stage 'DroidVM-GPU-Uninstall.exe')

Copy-Item (Join-Path $stage 'DroidVM-GPU-Setup.exe'), (Join-Path $stage 'DroidVM-GPU-Uninstall.exe') $dist
Copy-Item tools\DroidVM-GPU-Logs.cmd $dist
Compress-Archive -Path $drv, (Join-Path $stage 'DroidVM-GPU-Test.cer'), package\install.ps1, package\uninstall.ps1 -DestinationPath (Join-Path $dist 'DroidVM-GPU-driver.zip')
Get-ChildItem $dist -File | ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name } |
    Set-Content (Join-Path $dist 'SHA256SUMS.txt')

$rev = Get-ChildItem bin -Recurse -Filter REVISIONS.md | Select-Object -First 1
@"
**Мультиархитектурная сборка** драйвера VirtIO-GPU для Windows 11 ARM64 (DroidVM / Adreno 829 & A7xx/A8xx).
Авторы базового драйвера: anonymix007 и команда DroidVM. Лицензия AGPL-3.0.

> Перед установкой сделайте клон диска ВМ. Подписано тестовым сертификатом
> (``$($cert.Thumbprint)``), установщик включает TESTSIGNING.

### Что исправлено и добавлено в этой сборке
- **Фикс багов GPU и вылетов на Adreno 829 (Gunyah S2):**
  - Гостевые аллокации в `virtio_wddm_rs.sys` (`GuestBacking`) переведены на `MmAllocatePagesForMdlEx` с `MmWriteCombined`, а Turnip/Freedreno (`MSM_BO_WC`) и `vdrm_wddm` синхронизированы через `MemoryBarrier()` перед submit — устраняет stale cache lines, `0xc00002b6` и `DEVICE_LOST` на Gunyah.
  - Исправлен двойной вызов `pfnDeallocateCb` при разрушении ресурсов в `dx11um_virtio` (приводивший к `DEVICE_LOST`).
- **Полная поддержка архитектур `ARM64` + `x64` / `ARM64EC` (через ARM64X pure forwarders) + `x86` (WoW64)** во всех API.
- **OpenGL 4.6 (`droidvm_opengl.dll`):** нативный Gallium Freedreno WGL ICD + Zink поверх Vulkan (с автоподхватом `droidvm_vulkan` из DriverStore).
- **DirectX 9 / 9Ex:** активирован системный `D3D9On12` (`<>` в слоте D3D9 для 64-бит и WoW64 x86).
- **DirectX 10 / 10.1 / 11 (`dx11um_virtio.dll`):** аппаратное ускорение через DXVK.
- **DirectX 12 Ultimate — Feature Level `12_2`, Shader Model `6.6` (`dx12um_virtio.dll`):**
  - Raytracing Tier 1.1 (DXR State Objects, Acceleration Structures, `DispatchRays`)
  - Mesh & Amplification Shaders Tier 1 (`DispatchMesh`)
  - Variable Rate Shading Tier 2
  - Sampler Feedback Tier 0.9, Enhanced Barriers, Tiled Resources Tier 3, Conservative Rasterization Tier 3.

### Файлы релиза
- ``DroidVM-GPU-Setup.exe`` — автоустановщик (сертификат + `vulkan-1.dll` + драйвер, перезагрузка)
- ``DroidVM-GPU-Setup-diag.exe`` — диагностический вариант с записью шагов KMD в реестр
- ``DroidVM-GPU-Uninstall.exe`` — откат драйвера
- ``DroidVM-GPU-driver.zip`` — архив драйвера для ручной установки (`pnputil`)

Исходники:
$(if ($rev) { Get-Content $rev.FullName -Raw })
"@ | Set-Content (Join-Path $dist 'RELEASE_NOTES.md') -Encoding utf8
Get-ChildItem $dist
