import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc main() {.raises.} =
  var plain = newSeq[string](400)
  var escaped = newSeq[string](400)
  for index in 0..<plain.len:
    plain[index] = "ordinary string payload"
    escaped[index] = "quoted \" value\nwith \\ slash"

  var checksum = 0
  for iteration in 0..<200:
    checksum += toJson(plain).len
    checksum += toJson(escaped).len
  echo checksum

try:
  main()
except:
  quit "bench failed"
