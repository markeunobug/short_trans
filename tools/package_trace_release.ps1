param(
    [Parameter(Mandatory=$true)][string]$FpgaRelease,
    [Parameter(Mandatory=$true)][string]$ArmBuild
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
$fpga = (Resolve-Path $FpgaRelease).Path
$arm = (Resolve-Path $ArmBuild).Path
$result = Get-Content -LiteralPath (Join-Path $fpga 'result.json') -Raw | ConvertFrom-Json
if ($result.compile -ne 'PASS' -or @($result.live_source_drift).Count -ne 0) { throw 'FPGA release is not a clean PASS' }
$expected = Get-Content -LiteralPath (Join-Path $arm 'source_hashes.json') -Raw | ConvertFrom-Json
foreach ($entry in $expected) {
    if ((Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -ne $entry.Hash) { throw "ARM source drift: $($entry.Path)" }
}
$target = Join-Path $root '_codex/trace/release_20260924_v1'
if (Test-Path -LiteralPath $target) { throw "Release already exists; refusing overwrite: $target" }
New-Item -ItemType Directory -Path $target | Out-Null
Copy-Item -LiteralPath $result.sof -Destination (Join-Path $target 'receiver_fpga.sof')
foreach ($extension in @('hex','bin','elf')) {
    Copy-Item -LiteralPath (Join-Path $arm "rx_stm32_ook.$extension") -Destination (Join-Path $target "receiver_arm.$extension")
}
Copy-Item -LiteralPath (Join-Path $root 'flutter/build/windows/x64/runner/Release') -Destination (Join-Path $target 'host') -Recurse
foreach ($document in @('DEMOD_TRACE_QUICKSTART.md','DEMOD_TRACE_PROTOCOL.md','DEMOD_TRACE_VALIDATION.md')) {
    Copy-Item -LiteralPath (Join-Path $root "codex/$document") -Destination $target
}
$files = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object {
    [ordered]@{path=$_.FullName.Substring($target.Length+1); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash; bytes=$_.Length}
})
[ordered]@{
    created=(Get-Date -Format o); fpga_release=$fpga; arm_build=$arm;
    hardware_programmed=$false; board_validated=$false; files=$files
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $target 'manifest.json') -Encoding utf8
Write-Output "RELEASE=$target"
