import std/options

when defined(compareJsonx):
  import jsonx
  export jsonx
elif defined(compareJsony):
  import jsony
  export jsony
else:
  import brian
  export brian

type
  State* = enum
    queued, active, closed

  Record* = object
    id*: string
    state*: State
    title*: string
    enabled*: bool
    alias*: Option[string]
    labels*: seq[string]

proc makePayload*(): string =
  result = "["
  for index in 0..<200:
    if index > 0:
      result.add ','
    result.add "{\"id\":\"record\",\"state\":\"active\","
    result.add "\"title\":\"Known fields only\",\"enabled\":true,"
    result.add "\"alias\":null,\"labels\":[\"one\",\"two\",\"three\"]}"
  result.add ']'
