#!/bin/sh
# Runs the tests with only the Command Line Tools installed (no Xcode).
# The CLT ship Swift Testing but SwiftPM doesn't add its paths on its own.
set -e
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
exec swift test \
  -Xswiftc -F"$DEV/Frameworks" \
  -Xlinker -F"$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
  "$@"
