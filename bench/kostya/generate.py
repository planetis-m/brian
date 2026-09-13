"""Reproducible input with the schema/scales of kostya/benchmarks/json."""
import json
import random
import string
from pathlib import Path

rng = random.Random(20260913)
coordinates = [
    {
        "x": rng.random() * -10e-30,
        "y": rng.random() * 10e30,
        "z": rng.random(),
        "name": "".join(rng.sample(string.ascii_lowercase, 6)) + f" {rng.randrange(10000)}",
        "opts": {"1": [1, True]},
    }
    for _ in range(524_288)
]
Path("/tmp/1.json").write_text(
    json.dumps({"coordinates": coordinates, "info": "some info"}, indent=2) + "\n"
)
