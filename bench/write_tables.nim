import std/tables
import brian

var values = initOrderedTable[string, int]()
for index in 0..<200:
  values["key" & $index] = index

var checksum = 0
for _ in 0..<1_000:
  checksum += toJson(values).len
echo checksum
