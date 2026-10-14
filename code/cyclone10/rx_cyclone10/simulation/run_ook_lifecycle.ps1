$ErrorActionPreference='Stop'
$projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runRoot=Join-Path $PSScriptRoot ('.ook_lifecycle_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
$work=Join-Path $runRoot work
Push-Location $projectRoot
try {
  & vlib $work
  if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
  & vlog -sv -work $work rtl/sync/ook_symbol_sync.v tb/ook_lifecycle_tb.sv *> (Join-Path $runRoot compile.log)
  if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
  $log=Join-Path $runRoot simulation.log
  & vsim -c -novopt -lib $work ook_lifecycle_tb -do 'onerror {quit -code 1}; run -all; quit -f' *> $log
  $text=Get-Content -LiteralPath $log -Raw
  if ($LASTEXITCODE -ne 0 -or $text -notmatch 'PASS: ook_lifecycle_tb' -or $text -match '\*\* (Error|Fatal)') { throw "Lifecycle simulation failed: $log" }
  Write-Output "PASS: OOK lifecycle; log=$log"
}
finally { Pop-Location }
