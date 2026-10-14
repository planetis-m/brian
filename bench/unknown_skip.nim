import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

type Envelope = object
  name: string
  enabled: bool

proc makePayload(): string =
  result = "["
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "{\"name\":\"known\",\"enabled\":true,\"extension\":{"
    result.add "\"deep\":[{\"value\":[\"a\",\"b\",{\"c\":false}]},null],"
    result.add "\"opaque\":\"skip this escaped \\\" string\\\"\"}}"
  result.add ']'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<100:
    let values = fromJson(payload, seq[Envelope])
    check values.len == 200
    checksum += values[iteration mod values.len].name.len
  echo checksum

try:
  main()
except:
  quit "bench failed"
