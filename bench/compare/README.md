# Cross-library object benchmarks

These matched Cachegrind probes compare Brian with jsonx and jsony. Each run
parses or writes the same 200 six-field objects repeatedly and prints a checksum
instead of a duration. Compare release-build instruction counts only.

## Setup

Create a local `nim.cfg` alongside this README. It is intentionally ignored by
Git because it describes the Brian checkout on which you are running the
benchmark:

```text
--path:"../../src"
```

Then use Atlas to fetch the comparison libraries:

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
