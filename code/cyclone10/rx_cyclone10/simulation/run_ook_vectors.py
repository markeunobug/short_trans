"""Run exact RTL/CRC/payload scoreboards in an isolated, retained ModelSim library."""
import json, subprocess, datetime, re, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
run = root / "_codex" / ("ook_vectors_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
run.mkdir(parents=True)
def execute(args, name, marker=None):
    result = subprocess.run(args, cwd=run, capture_output=True, text=True)
    text = result.stdout + result.stderr
    (run / (name + ".log")).write_text(text)
    if result.returncode or re.search(r"FAIL|\*\* (?:Error|Fatal)", text) or (marker and marker not in text):
        raise RuntimeError(f"{name} failed: {run / (name + '.log')}")
execute(["vlib", "work"], "vlib")
files = ["rtl/demod/ook_iq_correlator.v", "rtl/sync/ook_symbol_sync.v", "rtl/protocol/crc8_atm.v", "rtl/protocol/crc16_ccitt.v", "rtl/protocol/fsk_frame_rx.v", "tb/ook_validation_vectors_tb.sv", "tb/ook_tx_fixture_chain_tb.sv"]
execute(["vlog", "-sv", "-work", "work", "+incdir+"+str(root/"rtl/protocol")] + [str(root/f) for f in files], "compile")
manifest = json.loads((root / "tb/ook_validation_vectors/manifest.json").read_text())
scenarios = [(s, 0) for s in manifest["scenarios"]]
scenarios += [(manifest["scenarios"][2], n*48) for n in range(1,10)]
if "--fixture-only" in sys.argv: scenarios=[]
for s, prefix in scenarios:
    name = s["name"] + f"_prefix{prefix}"
    good = [f for f in s["expected_frames"] if f["valid"]]
    base_valid = False
    meta, payload = [], []
    for f in good:
        is_base = f["type"] == "TIME_BASE"
        body = bytes.fromhex(f["payload_hex"])
        tv = is_base or base_valid
        value = ((0x21 if is_base else 0x20) << 50) | (f["sequence"] << 42) | (len(body) << 34) | (f["timestamp"] << 2) | (int(tv) << 1) | int(is_base)
        meta.append(f"{value:016x}")
        payload.extend(f"{x:02x}" for x in body)
        base_valid |= is_base
    mp, pp = run/(name+".meta.mem"), run/(name+".payload.mem")
    mp.write_text("\n".join(meta)+"\n")
    pp.write_text("\n".join(payload)+"\n")
    args = [f"+FILE={(root/'tb/ook_validation_vectors'/s['files']['samples_i20_mem']).as_posix()}", f"+COUNT={s['sample_count']}", f"+EXPECT_FRAMES={len(good)}", f"+EXPECT_SEQ0={good[0]['sequence']}", f"+PREFIX={prefix}", f"+META={mp.as_posix()}", f"+PAYLOAD={pp.as_posix()}", f"+BYTES={len(payload)}", f"+CRC={len(s['expected_frames'])-len(good)}"]
    execute(["vsim", "-c", "-novopt", "-lib", "work", "ook_validation_vectors_tb"] + args + ["-do", "onerror {quit -code 1}; run -all; quit -f"], name, "PASS: ook_validation_vectors_tb")
    print("PASS", name, flush=True)
execute(["vsim", "-c", "-novopt", "-lib", "work", "ook_tx_fixture_chain_tb", "+FIXTURE="+(root.parents[1]/"stm32/tx_stm32/Tests/fixtures/ook_1800_timebase_then_data.mem").as_posix(), "-do", "onerror {quit -code 1}; run -all; quit -f"], "tx_fixture", "PASS: ook_tx_fixture_chain_tb")
print(f"PASS: {len(scenarios)} vector runs and actual TX fixture; logs={run}")
