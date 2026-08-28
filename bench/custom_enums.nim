import std/strutils
import brian

type ResponseStatus = enum
  completed, inProgress = "in_progress", failed, cancelled, queued, incomplete, unknown

proc readJson*(dst: var ResponseStatus; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  readJson(dst, p, unknownFields, unknown)

const Count = 20_000
let payload = "[" & "\"in_progress\",".repeat(Count - 1) & "\"in_progress\"]"
var checksum = 0
for iteration in 0..<20:
  let values = fromJson(payload, seq[ResponseStatus])
  doAssert values.len == Count
  checksum += ord(values[iteration])
echo checksum
