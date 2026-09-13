"""Generate numeric corpora and compare one/two-word conversion coverage.

Run from the repo root: python3 bench/float_coverage.py /tmp/brian-coverage
The one-word candidate is made in the output directory, not in production code.
"""
from fractions import Fraction
from pathlib import Path
import hashlib
import math
import random
import re
import shlex
import shutil
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

# Reconstruct the one-word candidate in a temporary source tree. Production
# retains the two-word product after the measured halfway-neighbor regression.
reference = out / 'one_word-src'
reference.mkdir(exist_ok=True)
for source in Path('src').glob('*.nim'):
    shutil.copyfile(source, reference / source.name)
source = (reference / 'brian.nim').read_text()
old = """  var product = multiplyWide(normalized, power.hi)
  let tail = multiplyWide(normalized, power.lo)
  product.lo += tail.hi
  if product.lo < tail.hi: inc product.hi"""
assert source.count(old) == 1
source = source.replace(old, '  let product = multiplyWide(normalized, power)').replace(
    '      (remainder == halfway - 1 and product.lo >= high(uint64) - 1):',
    '      remainder == halfway - 1:')
source = source.replace(
    '  # The cached power is rounded down with error < 1. Discarding the low\n'
    '  # product word adds error < 1, so the exact scaled product is in [P, P+2).',
    '  # The downward-rounded 64-bit power gives the interval [P, P+normalized).')
(reference / 'brian.nim').write_text(source)
powers = ['const FloatPowers: array[-342..308, uint64] = [']
for q in range(-342, 309):
    n, d = (10**q, 1) if q >= 0 else (1, 10**-q)
    e = (q * 217706) // 65536 - 63
    a, b = (n, d << e) if e >= 0 else (n << -e, d)
    powers.append(f"  0x{a // b:016x}'u64,")
(reference / 'brian_float_powers.nim').write_text('\n'.join(powers) + '\n]\n')

root = Path.cwd()
for variant in ['one_word', 'two_word']:
    implementation = root / 'src' if variant == 'two_word' else reference
    # Absolute include prevents an ancestor nim.cfg from silently selecting
    # the production module for both variants. Both builds have explicit flags.
    runner = out / 'float_coverage.nim'
    runner.write_text(Path('bench/float_coverage.nim').read_text().replace(
        'include brian', 'include "' + str(implementation / 'brian.nim') + '"'))
    command = ['nim', 'c', '--forceBuild:on', '--skipParentCfg:on',
               '--mm:arc', '-d:useMalloc', '--threads:on',
               '-d:release', '-d:brianFloatVerify',
               '--path:' + str(implementation),
               '--nimcache:' + str(out / (variant + '-cache')),
               '-o:' + str(out / (variant + '-probe')), str(runner)]
    with (out / (variant + '.build')).open('w') as log:
        log.write(shlex.join(command) + '\n')
        log.flush()
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    generated = ''.join(p.read_text() for p in (out / (variant + '-cache')).glob('*.c'))
    assert ('tail_1' in generated) == (variant == 'two_word')
    run = subprocess.run([str(out / (variant + '-probe')), *map(str, files)],
                         capture_output=True, text=True, check=True)
    (out / (variant + '.rates')).write_text(run.stdout)
    print(variant, run.stdout, flush=True)
    profile = [arg for arg in command if arg not in
               ['-d:brianFloatVerify']]
    profile.insert(2, '-d:brianFloatProfile')
    profile = [arg.replace(variant + '-cache', variant + '-profile-cache')
               .replace(variant + '-probe', variant + '-profile') for arg in profile]
    with (out / (variant + '.profile-build')).open('w') as log:
        log.write(shlex.join(profile) + '\n')
        log.flush()
        subprocess.run(profile, stdout=log, stderr=subprocess.STDOUT, check=True)
    for path in files:
        command = ['valgrind', '--tool=cachegrind', '--instr-at-start=no',
                   '--cache-sim=no', '--branch-sim=no',
                   '--cachegrind-out-file=' + str(out / (variant + '-' + path.stem + '.cg')),
                   str(out / (variant + '-profile')), str(path)]
        run = subprocess.run(command, capture_output=True, text=True, check=True)
        (out / (variant + '-' + path.stem + '.profile')).write_text(
            shlex.join(command) + '\n' + run.stdout + run.stderr)
        instructions = re.search(r'I\s+refs:\s+([\d,]+)', run.stderr).group(1)
        print(variant, path.stem, instructions, flush=True)
