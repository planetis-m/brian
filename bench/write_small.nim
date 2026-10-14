import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc main() {.raises.} =
  var checksum = 0
  for value in 0..<100_000:
    checksum += toJson(value mod 10).len
  echo checksum

try:
  main()
except:
  quit "bench failed"
