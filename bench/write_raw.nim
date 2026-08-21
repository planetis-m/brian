import brian

var values = newSeq[RawJson](200)
for index in 0..<values.len:
  values[index] = RawJson("{\"name\":\"raw\",\"items\":[1,true,null]}")

var checksum = 0
for iteration in 0..<20:
  checksum += toJson(values).len
echo checksum
