"""Build and Cachegrind float probes in the current checkout's build context.

Usage: python3 bench/measure_float_path.py /tmp/results [workload ...]
Run against each source revision separately; this script never changes source.
"""
from pathlib import Path
import re
import shlex
import subprocess
import sys

out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
names = sys.argv[2:] or [
    "floats_fast", "floats_fallback", "strings_plain", "objects_known", "integers",
    "kostya_orc", "kostya_arc",
]
for name in names:
    flags = ["-d:release", "-g"]
    source = f"bench/{name}.nim"
    if name in ("kostya_orc", "kostya_arc"):
        source = "bench/kostya/kostya_brian.nim"
        flags = [
            "-d:danger", "--mm:" + name.split("_")[1], "--opt:speed",
            "--passC:-Wall -Wextra -pedantic -Wcast-align -O3 -march=native "
            "-flto=auto -Wa,-mbranches-within-32B-boundaries",
            "--passL:-march=native -flto=auto",
        ]
    command = [
        "nim", "c", "--forceBuild:on", *flags,
        "--nimcache:" + str(out / (name + "-cache")), "-o:" + str(out / name), source,
    ]
    with (out / (name + ".build")).open("w") as log:
        log.write(shlex.join(command) + "\n")
        log.flush()
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    command = [
        "valgrind", "--tool=cachegrind", "--cache-sim=no", "--branch-sim=no",
        "--cachegrind-out-file=" + str(out / (name + ".cg")), str(out / name),
    ]
    if name in ("kostya_orc", "kostya_arc"):
        command.insert(1, "--instr-at-start=no")
    run = subprocess.run(command, capture_output=True, text=True, check=True)
    (out / (name + ".log")).write_text(shlex.join(command) + "\n" + run.stdout + run.stderr)
    size = subprocess.check_output(["size", "-A", str(out / name)], text=True)
    (out / (name + ".size")).write_text(size)
    instructions = re.search(r"I\s+refs:\s+([\d,]+)", run.stderr).group(1)
    print(name, instructions, run.stdout.strip(), flush=True)
