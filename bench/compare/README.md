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

## Results

Measured with Cachegrind using Nim 2.3.1
(`f1256ddcf4888424ab1bf795d024457c563abf68`) and `-d:release`. Lower
instruction counts are better. All reader runs produced checksum `300`; all
writer runs produced checksum `4800200`.

### Default strings

| Library | Object read | Object write |
| --- | ---: | ---: |
| Brian | 143,014,750 | 72,713,567 |
| jsonx | 165,655,730 | 242,449,610 |
| jsony | 166,315,725 | 98,750,177 |

### `--strings:sso`

| Library | Object read | Object write |
| --- | ---: | ---: |
| Brian | 110,229,386 | 74,709,176 |
| jsony | 142,630,368 | 141,576,233 |

jsonx is not listed because its `streams.nim` does not compile with
`--strings:sso` on this Nim version (`expression has no address`).
