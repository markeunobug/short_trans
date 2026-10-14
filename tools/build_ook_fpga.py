"""Freeze OOK FPGA sources and run full Quartus without programming hardware."""
import datetime, hashlib, json, os, re, shutil, subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[1]
project=root/"code/cyclone10/rx_cyclone10"
release=root/"_codex/ook"/datetime.datetime.now().strftime("release_%Y%m%d_%H%M%S")
stage=release/"source"
stage.mkdir(parents=True)
paths=["rtl","SignalTap","rx_cyclone10.v","rx_cyclone10.qsf","rx_cyclone10.qpf","rx_cyclone10.sdc"]
qsf=(project/"rx_cyclone10.qsf").read_text()
paths += [m.strip().strip('"') for m in re.findall(r"-name SLD_FILE (.+)",qsf)]
for relative in paths:
    src,dst=project/relative,stage/relative
    dst.parent.mkdir(parents=True,exist_ok=True)
    if src.is_dir(): shutil.copytree(src,dst)
    else: shutil.copy2(src,dst)
hashes={p.relative_to(stage).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in stage.rglob("*") if p.is_file()}
(release/"source_sha256.json").write_text(json.dumps(hashes,indent=2))
quartus=Path("C:/software/intelFPGA_lite/quartus")
env=os.environ.copy();env["QUARTUS_ROOTDIR"]=str(quartus);env["PATH"]=str(quartus/"bin64")+os.pathsep+env["PATH"]
print(f"RELEASE={release}",flush=True)
with (release/"quartus.log").open("w") as log:
    result=subprocess.run([str(quartus/"bin64/quartus_sh.exe"),"--flow","compile","rx_cyclone10"],cwd=stage,env=env,stdout=log,stderr=subprocess.STDOUT)
if result.returncode: raise RuntimeError(f"Quartus failed; {release/'quartus.log'}")
out_match=re.search(r"-name PROJECT_OUTPUT_DIRECTORY (.+)",qsf)
out=stage/(out_match[1].strip().strip('"') if out_match else "output_files")
summary=(out/"rx_cyclone10.sta.summary").read_text()
slacks=[float(x) for x in re.findall(r"Slack\s*:\s*(-?[0-9.]+)",summary)]
if not slacks or min(slacks)<0: raise RuntimeError(f"Timing failed: {slacks}")
drift=[relative for relative,h in hashes.items() if hashlib.sha256((project/relative).read_bytes()).hexdigest()!=h]
report={"compile":"PASS","min_reported_slack_ns":min(slacks),"live_source_drift":drift,"sof_sha256":hashlib.sha256((out/"rx_cyclone10.sof").read_bytes()).hexdigest(),"sof":str(out/"rx_cyclone10.sof"),"note":"STA coverage and warnings require review; no board test."}
(release/"result.json").write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2),flush=True)
