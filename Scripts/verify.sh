#!/bin/sh
set -eu

# The full package gate: boundaries, the strict test suite, and a whitespace check.
# Run this before reporting package work complete.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

echo "==> Package boundaries"
sh Scripts/validate-package-boundaries.sh

echo "==> Strict test suite"
swift test \
    -Xswiftc -target \
    -Xswiftc arm64-apple-macosx14.0 \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors

echo "==> Whitespace"
if ! command -v git >/dev/null 2>&1; then
    echo "git not available; cannot run the whitespace check" >&2
    exit 2
fi
git diff --check

echo "==> All package gates passed"
