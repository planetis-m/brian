# Cross-library object benchmarks

These matched Cachegrind probes compare Brian with jsonx and jsony. Each run
parses or writes the same 200 six-field objects repeatedly and prints a checksum
instead of a duration. Compare release-build instruction counts only.

## Setup

Create a local `nim.cfg` alongside this README. It is intentionally ignored by
Git and supplies the installed dependency paths:

```ini
--path:"deps/jsonx/src"
--path:"deps/jsony/src"
```

The bundled `atlas.toml` can install the comparison dependencies:

```sh
atlas --project=. --deps=deps install
```

Atlas appends its managed jsonx and jsony paths to this local configuration.

## Run

Build each target independently with `-d:release`:

```sh
nim c -d:release -g -o:objects_read_brian objects_read.nim
nim c -d:release -g -d:compareJsonx -o:objects_read_jsonx objects_read.nim
nim c -d:release -g -d:compareJsony -o:objects_read_jsony objects_read.nim

nim c -d:release -g -o:objects_write_brian objects_write.nim
nim c -d:release -g -d:compareJsonx -o:objects_write_jsonx objects_write.nim
nim c -d:release -g -d:compareJsony -o:objects_write_jsony objects_write.nim
```

Profile each binary separately:

```sh
valgrind --tool=cachegrind ./objects_read_brian
valgrind --tool=cachegrind ./objects_read_jsonx
valgrind --tool=cachegrind ./objects_read_jsony
```

The reader checksum is `300`; the writer checksum is `4800200`. Use the same
payload, compiler version, and release configuration for every comparison.

## Timing

For a 10,000,000-object timing workload, build each target with `-d:danger`
and `-d:Iterations=50000`, then collect 15 runs after three warmups:

```sh
nim c -d:danger -d:Iterations=50000 -o:objects_read_brian objects_read.nim
for i in {1..3}; do taskset -c 1 ./objects_read_brian >/dev/null; done
for i in {1..15}; do /usr/bin/time -f '%e' taskset -c 1 ./objects_read_brian >/dev/null; done
```

Repeat for each library and for `objects_write.nim`; compare medians.

## Results

Measured with Cachegrind using Nim 2.3.1
(`f1256ddcf4888424ab1bf795d024457c563abf68`) and `-d:release`. Lower
instruction counts are better. All reader runs produced checksum `300`; all
writer runs produced checksum `4800200`.

### Default strings

| Library | Object read | Object write |
| --- | ---: | ---: |
| Brian | 131,245,267 | 72,692,163 |
| jsonx | 165,635,601 | 242,434,140 |
| jsony | 166,297,565 | 98,731,967 |

### `--strings:sso`

| Library | Object read | Object write |
| --- | ---: | ---: |
| Brian | 103,251,842 | 74,687,800 |
| jsony | 142,612,312 | 141,558,057 |

jsonx is not listed because its `streams.nim` does not compile with
`--strings:sso` on this Nim version (`expression has no address`).
