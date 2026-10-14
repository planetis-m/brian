import std/options
import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

type
  State = enum queued, active, closed
  Record = object
    id: string
    state: State
    title: string
    enabled: bool
    alias: Option[string]
    labels: seq[string]

proc main() {.raises.} =
  var values = newSeq[Record](200)
  for index in 0..<values.len:
    values[index] = Record(
      id: "record",
      state: active,
      title: "Known fields only",
      enabled: true,
      alias: none[string](),
      labels: @["one", "two", "three"]
    )

  var checksum = 0
  for iteration in 0..<200:
    checksum += toJson(values).len
  echo checksum

try:
  main()
except:
  quit "bench failed"
