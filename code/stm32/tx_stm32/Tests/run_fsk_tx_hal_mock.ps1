param([string]$Compiler = "gcc")
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$build = Join-Path $env:TEMP ("short_trans_ook_mock_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $build | Out-Null
try {
  Push-Location $projectRoot
  & $Compiler "-std=c11" "-Wall" "-Wextra" "-Werror" "-ITests/hal_mock" "-ICore/Inc" "Core/Src/fsk_tx.c" "Tests/hal_mock/hal_mock.c" "Tests/test_fsk_tx_hal_mock.c" "-o" (Join-Path $build "test_fsk_tx_hal_mock.exe")
  if ($LASTEXITCODE -ne 0) { throw "HAL mock compile failed" }
  & (Join-Path $build "test_fsk_tx_hal_mock.exe")
  if ($LASTEXITCODE -ne 0) { throw "HAL mock test failed" }
}
finally {
  Pop-Location
  if (Test-Path -LiteralPath $build) {
    $resolvedBuild = (Resolve-Path -LiteralPath $build).Path
    $resolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\') + '\'
    if ($resolvedBuild.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedBuild -Recurse -Force
    }
    else { throw "Refusing to remove build directory outside TEMP: $resolvedBuild" }
  }
}
