## Compare direct typed object encoding across brian, jsonx, and jsony.
##
## Compile normally for brian, with -d:compareJsonx for jsonx, or with
## -d:compareJsony for jsony. See README.md in this directory for setup.

import std/options
import common

const Iterations {.intdefine.} = 200

var values = newSeq[Record](200)
for index in 0..<values.len:
  values[index] = Record(
    id: "record",
    state: active,
    title: "Known fields only",
    enabled: true,
    alias: none(string),
    labels: @["one", "two", "three"]
  )

var checksum = 0
for _ in 0..<Iterations:
  checksum += toJson(values).len

echo checksum
