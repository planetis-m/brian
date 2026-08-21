import std/options
import brian

type
  State = enum queued, active, closed
  Record = object
    id: string
    state: State
    title: string
    enabled: bool
    alias: Option[string]
    labels: seq[string]

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
for iteration in 0..<20:
  checksum += toJson(values).len
echo checksum
