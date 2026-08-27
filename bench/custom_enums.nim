import std/strutils
import brian

type ResponseStatus = enum
  completed, inProgress, failed, cancelled, queued, incomplete, unknown

proc readJson*(dst: var ResponseStatus; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  case p.matchString([
    "completed", "in_progress", "failed", "cancelled", "queued", "incomplete"
  ])
  of 0: dst = completed
  of 1: dst = inProgress
  of 2: dst = failed
  of 3: dst = cancelled
  of 4: dst = queued
  of 5: dst = incomplete
  else: dst = unknown

const Count = 20_000
let payload = "[" & "\"in_progress\",".repeat(Count - 1) & "\"in_progress\"]"
var checksum = 0
for iteration in 0..<20:
  let values = fromJson(payload, seq[ResponseStatus])
  doAssert values.len == Count
  checksum += ord(values[iteration])
echo checksum
