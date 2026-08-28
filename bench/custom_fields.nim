import brian

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
      p.raiseParseError("expected known field, got \"" & $field & "\"")
    else:
      p.skipJson()

proc makePayload(): string =
  result = "["
  for index in 0..<2_000:
    if index > 0: result.add ','
    result.add "{\"id\":" & $index & ",\"active\":true,\"retry\":3}"
  result.add ']'

proc main() =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<20:
    let values = fromJson(payload, seq[Response])
    doAssert values.len == 2_000
    checksum += values[iteration].retry
  echo checksum

when isMainModule:
  main()
