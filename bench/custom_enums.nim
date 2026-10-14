import std/strutils
import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

type ResponseStatus = enum
  completed, inProgress = "in_progress", failed, cancelled, queued, incomplete, unknown

proc readJson*(dst: var ResponseStatus; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  readJson(dst, p, unknownFields, unknown)

const Count = 20_000
proc main() {.raises.} =
  let payload = "[" & "\"in_progress\",".repeat(Count - 1) & "\"in_progress\"]"
  var checksum = 0
  for iteration in 0..<20:
    let values = fromJson(payload, seq[ResponseStatus])
    check values.len == Count
    checksum += ord(values[iteration])
  echo checksum

try:
  main()
except:
  quit "bench failed"
