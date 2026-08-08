#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sources="$root/Sources"

# A missing search tool must fail the gate. Reporting clean boundaries because the
# scanner never ran is worse than not running the gate at all.
if command -v rg >/dev/null 2>&1; then
    search() { rg -n "$1" "$sources"; }
elif command -v grep >/dev/null 2>&1; then
    search() { grep -rnE "$1" "$sources"; }
else
    echo "No search tool available: install ripgrep or grep" >&2
    exit 2
fi

if [ ! -d "$sources" ]; then
    echo "Source directory not found: $sources" >&2
    exit 2
fi

# `search` exits non-zero when it finds nothing, which is the passing case here,
# so each check is guarded against `set -e`.
status=0

if search 'Bundle\.main|AppContainer|QuizConfiguration|Срб|SerbianQuiz|MilosPetrusic|ca-app-pub'; then
    echo "Package contains app-specific configuration or content" >&2
    status=1
fi

if search '^(@preconcurrency )?import (Firebase|FirebaseCore|FirebaseAnalytics|GoogleMobileAds|StoreKit|GameKit|MultipeerConnectivity)'; then
    echo "Package imports an app-owned vendor SDK" >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    exit "$status"
fi

echo "QuizEngine package boundaries are clean"
