"""Generate decimal corpora and verify brian's float reader against them.

Run from the repo root: python3 bench/float_coverage.py /tmp/brian-coverage

The script writes the corpora below, builds bench/float_coverage.nim against
src/, runs it over every corpus with bit-exact verification against
std/parseutils and std/json, and records per-corpus Cachegrind instruction
counts. The same corpora are reused by tests/arm32-corpus.sh for the 32-bit
cross-check.
"""
from fractions import Fraction
from pathlib import Path
import hashlib
import math
import random
import re
import shlex
import struct
import subprocess
import sys

out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
rng = random.Random(20260914)


def floating(bits):
    return struct.unpack('>d', struct.pack('>Q', bits))[0]


def number(text):
    # Select std/json's float reader even for integral decimal spellings.
    return text if '.' in text or 'e' in text else text + 'e0'


def save(name, values):
    path = out / (name + '.txt')
    path.write_text(''.join(number(value) + '\n' for value in values))
    print(name, hashlib.sha256(path.read_bytes()).hexdigest(), flush=True)
    return path


values = []
while len(values) < 200_000:
    value = floating(rng.getrandbits(64))
    if math.isfinite(value):
        values.append(value)
# Uniform bits samples signs, significands and the complete exponent range.
files = [save('random_17digits', (format(x, '.17g') for x in values)),
         save('shortest_roundtrip', (repr(x) for x in values))]
bits = ''.join(f"{struct.unpack('>Q', struct.pack('>d', x))[0]:016x}\n" for x in values)
for path in files:
    Path(str(path) + '.bits').write_text(bits)
files.append(save('random_decimals', (
    ('-' if rng.randrange(2) else '') + str(rng.randrange(1, 10**rng.randrange(1, 20)))
    + 'e' + str(rng.randrange(-360, 311)) for _ in range(200_000))))

compact = []
for exponent in range(53, 63):
    step = 1 << (exponent - 52)
    for index in range(1_000):
        midpoint = (1 << exponent) + index * step + step // 2
        for delta in [-1, 0, 1]:
            for sign in ['', '-']:
                compact.append(sign + str(midpoint + delta) + 'e0')
files.append(save('compact_halfway_neighbors', compact))

midpoints = []
for _ in range(5_000):
    bits = rng.randrange(1, 0x7fefffffffffffff)
    left, right = Fraction(floating(bits)), Fraction(floating(bits + 1))
    midpoint = (left + right) / 2
    k = midpoint.denominator.bit_length() - 1
    numerator = midpoint.numerator * 5**k
    # Exact midpoint and its two adjacent last-decimal-place spellings.
    for delta in [-1, 0, 1]:
        for sign in [1, -1]:
            midpoints.append(str(sign * (numerator + delta)) + 'e-' + str(k))
files.append(save('exact_halfway_neighbors', midpoints))

edges = []
for bits in [0, 1, 2, 0x000fffffffffffff, 0x0010000000000000,
             0x0010000000000001, 0x7feffffffffffffe, 0x7fefffffffffffff]:
    for sign in [0, 1 << 63]:
        edges.append(repr(floating(bits | sign)))
for exponent in range(-343, 310):
    for significand in ['1', '7', '123456789', '9007199254740993',
                        '1000000000000000000', '9999999999999999999']:
        for sign in ['', '-']:
            edges.append(sign + significand + 'e' + str(exponent))
files.append(save('exponent_boundaries', edges))

# Verify and profile the production reader.
probe = out / 'float_coverage-probe'
command = ['nim', 'c', '--forceBuild:on', '--skipParentCfg:on',
           '--mm:arc', '-d:useMalloc', '--threads:on',
           '-d:release', '-d:brianFloatVerify', '--path:src',
           '--nimcache:' + str(out / 'verify-cache'),
           '-o:' + str(probe), 'bench/float_coverage.nim']
with (out / 'verify.build').open('w') as log:
    log.write(shlex.join(command) + '\n')
    log.flush()
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)

verified = subprocess.run([str(probe), *map(str, files)],
                          capture_output=True, text=True, check=True)
(out / 'verify.rates').write_text(verified.stdout)
print(verified.stdout, flush=True)

profile = [arg for arg in command if arg not in ['-d:brianFloatVerify']]
profile.insert(2, '-d:brianFloatProfile')
profile = [arg.replace('verify-cache', 'profile-cache')
           .replace('float_coverage-probe', 'float_coverage-profile')
           for arg in profile]
with (out / 'profile.build').open('w') as log:
    log.write(shlex.join(profile) + '\n')
    log.flush()
    subprocess.run(profile, stdout=log, stderr=subprocess.STDOUT, check=True)
for path in files:
    cachegrind = ['valgrind', '--tool=cachegrind', '--instr-at-start=no',
                  '--cache-sim=no', '--branch-sim=no',
                  '--cachegrind-out-file=' + str(out / (path.stem + '.cg')),
                  str(out / 'float_coverage-profile'), str(path)]
    profiled = subprocess.run(cachegrind, capture_output=True, text=True, check=True)
    (out / (path.stem + '.profile')).write_text(
        shlex.join(cachegrind) + '\n' + profiled.stdout + profiled.stderr)
    instructions = re.search(r'I\s+refs:\s+([\d,]+)', profiled.stderr).group(1)
    print(path.stem, instructions, flush=True)
