#!/usr/bin/env python3
"""Build isolated, reproducible TX hard-float and RX FPGA artifacts; never program hardware."""
from __future__ import annotations
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GCC = Path(r"C:/software/STM32CubeIDE_1.13.1/STM32CubeIDE/plugins/com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32.11.3.rel1.win32_1.1.0.202305231506/tools/bin/arm-none-eabi-gcc.exe")
DEFAULT_QUARTUS = Path(r"C:/software/quartus22_1/quartus")


def hashes(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}


def run(command, cwd, log, env=None):
    command = [str(item) for item in command]
    with log.open("a", encoding="utf-8") as out:
        out.write("\nCOMMAND " + json.dumps(command) + "\n")
        out.flush()
        result = subprocess.run(command, cwd=cwd, stdout=out, stderr=subprocess.STDOUT, env=env)
    if result.returncode:
        raise RuntimeError(f"exit {result.returncode}: {command[0]}; see {log}")


def stage(destination):
    source = destination / "source"
    paths = [
        "code/stm32/tx_stm32/Core", "code/stm32/tx_stm32/Drivers", "code/stm32/tx_stm32/Tests",
        "code/stm32/tx_stm32/STM32G431RBTX_FLASH.ld", "code/stm32/tx_stm32/tx_stm32.ioc",
        "code/cyclone10/rx_cyclone10/rtl", "code/cyclone10/rx_cyclone10/tb",
        "code/cyclone10/rx_cyclone10/tools", "code/cyclone10/rx_cyclone10/SignalTap",
        "code/cyclone10/rx_cyclone10/rx_cyclone10.v",
        "code/cyclone10/rx_cyclone10/rx_cyclone10.qsf",
        "code/cyclone10/rx_cyclone10/rx_cyclone10.qpf",
        "code/cyclone10/rx_cyclone10/rx_cyclone10.sdc",
        "code/cyclone10/rx_cyclone10/simulation/run_rtl_regression.ps1",
        "tools/gen_fsk_tones.py", "tools/gen_correlator_vectors.py",
        "flutter/lib/main.dart", "codex/UPPER_COMPUTER_PROTOCOL.md",
        "codex/FSK_1700_1900_IMPLEMENTATION_PLAN.md", "tools/build_fsk_release.py",
    ]
    qsf = (ROOT / "code/cyclone10/rx_cyclone10/rx_cyclone10.qsf").read_text()
    for match in re.finditer(r"-name SLD_FILE (.+)", qsf):
        paths.append("code/cyclone10/rx_cyclone10/" + match[1].strip().strip('"'))
    for relative in paths:
        src, dst = ROOT / relative, source / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, dst, ignore=shutil.ignore_patterns("__pycache__", "*.exe", "*.o"))
        else:
            shutil.copy2(src, dst)
    manifest = hashes(source)
    (destination / "source_sha256.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return source


def build_tx(source, destination, gcc):
    project = source / "code/stm32/tx_stm32"
    build = destination / "tx_build"
    build.mkdir()
    log = destination / "tx_build.log"
    common = ["-mcpu=cortex-m4", "-mfpu=fpv4-sp-d16", "-mfloat-abi=hard", "-mthumb",
              "-O0", "-g3", "-ffunction-sections", "-fdata-sections"]
    includes = ["Core/Inc", "Drivers/STM32G4xx_HAL_Driver/Inc",
                "Drivers/STM32G4xx_HAL_Driver/Inc/Legacy", "Drivers/CMSIS/Device/ST/STM32G4xx/Include",
                "Drivers/CMSIS/Include"]
    defines = ["-DDEBUG", "-DUSE_HAL_DRIVER", "-DSTM32G431xx"]
    run([gcc, "--version"], project, log)
    objects = []
    sources = sorted((project / "Core/Src").glob("*.c")) + sorted((project / "Drivers/STM32G4xx_HAL_Driver/Src").glob("*.c"))
    for index, path in enumerate(sources):
        obj = build / f"{index}_{path.stem}.o"
        run([gcc, *common, *defines, *["-I" + str(project / p) for p in includes],
             "--specs=nano.specs", "-std=gnu11", "-Wall", "-Wextra", "-c", path, "-o", obj], project, log)
        objects.append(obj)
    startup = build / "startup.o"
    run([gcc, *common, "-x", "assembler-with-cpp", "-c", project / "Core/Startup/startup_stm32g431rbtx.s", "-o", startup], project, log)
    elf = destination / "artifacts/tx_stm32_1700_1900.elf"
    run([gcc, *common, *objects, startup, "-T" + str(project / "STM32G431RBTX_FLASH.ld"),
         "--specs=nosys.specs", "--specs=nano.specs", "-static", "-Wl,--gc-sections",
         "-Wl,-Map=" + str(build / "tx_stm32.map"), "-Wl,--start-group", "-lc", "-lm", "-Wl,--end-group", "-o", elf], project, log)
    run([gcc.with_name("arm-none-eabi-size.exe"), elf], project, log)
    run([gcc.with_name("arm-none-eabi-readelf.exe"), "-A", elf], project, log)
    for form, suffix in [("ihex", ".hex"), ("binary", ".bin")]:
        run([gcc.with_name("arm-none-eabi-objcopy.exe"), "-O", form, elf, elf.with_suffix(suffix)], project, log)
    return {"status": "PASS", "c_sources": len(sources), "abi": "hard", "artifact": str(elf)}


def build_fpga(source, destination, quartus):
    project = source / "code/cyclone10/rx_cyclone10"
    log = destination / "fpga_build.log"
    env = os.environ.copy()
    env["QUARTUS_ROOTDIR"] = str(quartus)
    env["QSYS_ROOTDIR"] = str(quartus / "sopc_builder/bin")
    env["PATH"] = str(quartus / "bin64") + os.pathsep + env["PATH"]
    run([quartus / "bin64/quartus_sh.exe", "--flow", "compile", "rx_cyclone10"], project, log, env)
    summary = (project / "output_files/rx_cyclone10.sta.summary").read_text()
    slacks = [float(value) for value in re.findall(r"Slack\s*:\s*(-?[0-9.]+)", summary)]
    if not slacks or min(slacks) < 0:
        raise RuntimeError(f"Timing gate failed: minimum slack={min(slacks) if slacks else 'missing'} ns; SOF withheld")
    sof = project / "output_files/rx_cyclone10.sof"
    shutil.copy2(sof, destination / "artifacts/rx_cyclone10_1700_1900.sof")
    return {"status": "PASS", "artifact": str(sof), "minimum_slack_ns": min(slacks), "timing_gate": "PASS", "unconstrained_review": "REQUIRED"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--gcc", type=Path, default=DEFAULT_GCC)
    parser.add_argument("--quartus", type=Path, default=DEFAULT_QUARTUS)
    args = parser.parse_args()
    for tool in (args.gcc, args.quartus / "bin64/quartus_sh.exe"):
        if not tool.is_file():
            parser.error(f"tool not found: {tool}")
    destination = (args.output or ROOT / "_codex/fsk_1700_1900" / datetime.datetime.now().strftime("release_%Y%m%d_%H%M%S")).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    (destination / "artifacts").mkdir()
    source = stage(destination)
    print(f"BUILD_DIRECTORY={destination}", flush=True)
    result = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        jobs = {pool.submit(build_tx, source, destination, args.gcc): "tx",
                pool.submit(build_fpga, source, destination, args.quartus): "fpga"}
        for future in concurrent.futures.as_completed(jobs):
            name = jobs[future]
            try:
                result[name] = future.result()
            except Exception as exc:
                result[name] = {"status": "FAIL", "error": str(exc)}
            print(f"{name}: {result[name]}", flush=True)
            (destination / "build_status.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    (destination / "artifacts_sha256.json").write_text(json.dumps(hashes(destination / "artifacts"), indent=2), encoding="utf-8")
    raise SystemExit(0 if all(item["status"] == "PASS" for item in result.values()) else 1)


if __name__ == "__main__":
    main()
