import brian

type
  Entry = object
    field: string
    value: int
  OpenFields = object
    entries: seq[Entry]

proc readJson(dst: var OpenFields; p: var JsonParser;
              unknownFields: UnknownFieldPolicy) =
  for field in p.jsonFields:
    var value: int
    readJson(value, p, unknownFields)
    dst.entries.add Entry(field: $field, value: value)

const Count = 20_000

proc makePayload(): string =
  result = "{"
  for index in 0..<Count:
    if index > 0:
      result.add ','
    result.add "\"field_" & $index & "\":" & $index
  result.add '}'

proc main() =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<20:
    let fields = fromJson(payload, OpenFields)
    doAssert fields.entries.len == Count
    checksum += fields.entries[iteration].value
  echo checksum

when isMainModule:
  main()
