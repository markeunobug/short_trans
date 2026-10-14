param(
  [string]$Compiler = "gcc",
  [string]$Output = "Tests/fixtures/ook_1800_timebase_then_data.mem"
)
$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$build = Join-Path $env:TEMP ("short_trans_ook_fixture_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $build | Out-Null
try {
  Push-Location $projectRoot
  New-Item -ItemType Directory -Force (Split-Path -Parent $Output) | Out-Null
  $exe = Join-Path $build "generate_ook_packet_fixture.exe"
  & $Compiler "-std=c11" "-Wall" "-Wextra" "-Werror" "-ITests/hal_mock" "-ICore/Inc" "Core/Src/fsk_tx.c" "Tests/hal_mock/hal_mock.c" "Tests/generate_ook_packet_fixture.c" "-o" $exe
  if ($LASTEXITCODE -ne 0) { throw "fixture generator compile failed" }
  & $exe $Output
  if ($LASTEXITCODE -ne 0) { throw "fixture generator failed" }
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
