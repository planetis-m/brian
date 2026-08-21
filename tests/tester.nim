import std/os

proc run(command: string) =
  if execShellCmd(command) != 0:
    quit "FAILURE " & command

let testDir = getCurrentDir() / "tests"
let commands = [
  "nim c -r -d:debug",
  "nim c -r -d:release",
  "nim c -r -d:danger",
  "nim c -r -d:release --strings:sso",
  "nim c -r -d:danger --strings:sso",
  "ASAN_OPTIONS=detect_leaks=0 nim c -r -d:release -g -d:addressSanitizer",
  "ASAN_OPTIONS=detect_leaks=0 nim c -r -d:release -g -d:addressSanitizer --strings:sso"
]

for path in walkFiles(testDir / "t*.nim"):
  if path.extractFilename != "tester.nim":
    for command in commands:
      echo "Testing ", path.extractFilename, " with ", command
      run command & " " & quoteShell(path)

echo "All test configurations completed."
