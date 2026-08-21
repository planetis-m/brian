import std/sets
import brian

var values = initOrderedSet[int]()
for value in 0..<400:
  values.incl value

var checksum = 0
for _ in 0..<1_000:
  checksum += toJson(values).len
echo checksum
