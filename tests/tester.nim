import std/[os, syncio]

# Run from the repository root: `nimony c -r tests/tester.nim`.

const
  Tests = ["tbrian", "tfloats"]
  # Nimony strings are always SSO, so there is no string-layout variant to
  # cover. ASan sees the stack, globals and libc calls; heap blocks come from
  # Nimony's own allocator, which ASan does not instrument.
  # `--cc` rejects flags, so they live in a compiler wrapper.
  Asan = "--cc:tests/asan-gcc"
  Configs = [
    ("debug", ""),
    ("release", "-d:release"),
    ("danger", "-d:danger"),
    ("asan", "-d:release " & Asan)
  ]

proc main() =
  for test in Tests:
    for (name, flags) in Configs:
      echo "Testing ", test, " with ", name
      let command = "ASAN_OPTIONS=detect_leaks=0 nimony c -r " & flags &
        " --nimcache:tests/nimcache/" & name & " tests/" & test & ".nim"
      if execShellCmd(command) != 0:
        quit "FAILURE " & command
  echo "All test configurations completed."

main()
