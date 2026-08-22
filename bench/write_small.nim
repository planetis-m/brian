import brian

var checksum = 0
for value in 0..<100_000:
  checksum += toJson(value mod 10).len
echo checksum
