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

proc makePayload(): string =
  result = "["
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "{\"id\":\"record\",\"state\":\"active\","
    result.add "\"title\":\"Known fields only\",\"enabled\":true,"
    result.add "\"alias\":null,\"labels\":[\"one\",\"two\",\"three\"]}"
  result.add ']'

let payload = makePayload()
var checksum = 0
for iteration in 0..<20:
  let values = fromJson(payload, seq[Record])
  doAssert values.len == 200
  checksum += values[iteration mod values.len].labels.len
echo checksum
