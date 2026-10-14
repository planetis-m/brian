import std/options
import brian
import std/result
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

proc makePayload(): string =
  result = "["
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "{\"id\":\"record\",\"state\":\"active\","
    result.add "\"title\":\"Known fields only\",\"enabled\":true,"
    result.add "\"alias\":null,\"labels\":[\"one\",\"two\",\"three\"]}"
  result.add ']'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<100:
    case fromJson(payload, seq[Record])
    of Ok(values):
      check values.len == 200
      checksum += values[iteration mod values.len].labels.len
    of Err(_):
      check false
  echo checksum

try:
  main()
except:
  quit "bench failed"
