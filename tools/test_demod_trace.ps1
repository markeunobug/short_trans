$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
$project = Join-Path $root 'code/cyclone10/rx_cyclone10'
$run = Join-Path $root '_codex/trace/rtl'
New-Item -ItemType Directory -Force -Path $run | Out-Null
Push-Location $run
try {
    & vlib work
    & vlog -sv -work work "$project/rtl/spi/spi1_slave.v" "$project/rtl/debug/demod_trace.v" "$project/tb/demod_trace_tb.sv"
    if ($LASTEXITCODE) { throw 'vlog failed' }
    & vsim -c -lib work demod_trace_tb -do 'onerror {quit -code 1}; run -all; quit -code 0' 2>&1 | Tee-Object -FilePath trace.log
    if ($LASTEXITCODE -or (Get-Content trace.log -Raw) -notmatch 'demod_trace_tb: PASS') { throw 'trace RTL failed' }
    New-Item -ItemType Directory -Force -Path tb | Out-Null
    Copy-Item -LiteralPath "$project/tb/ook_frame.samples.mem" -Destination 'tb/ook_frame.samples.mem'
    & vlog -sv -work work "$project/rtl/demod/fsk_tone_rom.v" "$project/rtl/demod/fsk_iq_correlator.v" "$project/rtl/demod/fsk_noise_tracker.v" "$project/rtl/demod/fsk_demod_core.v" "$project/rtl/demod/ook_iq_correlator.v" "$project/rtl/sync/ook_symbol_sync.v" "$project/rtl/sync/fsk_symbol_sync.v" "$project/tb/trace_chain_tb.sv"
    if ($LASTEXITCODE) { throw 'chain vlog failed' }
    & vsim -c -lib work trace_chain_tb -do 'onerror {quit -code 1}; run -all; quit -code 0' 2>&1 | Tee-Object -FilePath trace_chain.log
    if ($LASTEXITCODE -or (Get-Content trace_chain.log -Raw) -notmatch 'trace_chain_tb: PASS') { throw 'trace chain failed' }
} finally { Pop-Location }
