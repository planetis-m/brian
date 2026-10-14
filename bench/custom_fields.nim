import brian
import std/result
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

type Response = object
  id: int
  active: bool
  retry: int

proc readJson*(dst: var Response; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  for field in p.jsonFields:
    if field == "id":
      readJson(dst.id, p, unknownFields)
    elif field == "active":
      readJson(dst.active, p, unknownFields)
    elif field == "retry":
      readJson(dst.retry, p, unknownFields)
    elif unknownFields == ufReject:
      p.parseError(jeUnknownField)
    else:
      p.skipJson()

proc makePayload(): string =
  result = "["
  for index in 0..<2_000:
    if index > 0: result.add ','
    result.add "{\"id\":" & $index & ",\"active\":true,\"retry\":3}"
  result.add ']'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<20:
    case fromJson(payload, seq[Response])
    of Ok(values):
      check values.len == 2_000
      checksum += values[iteration].retry
    of Err(_):
      check false
  echo checksum

try:
  main()
except:
  quit "bench failed"
