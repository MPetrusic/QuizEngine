#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sources="$root/Sources"

if rg -n 'Bundle\.main|AppContainer|QuizConfiguration|Срб|SerbianQuiz|MilosPetrusic|ca-app-pub' "$sources"; then
    echo "Package contains app-specific configuration or content" >&2
    exit 1
fi

if rg -n '^(@preconcurrency )?import (Firebase|FirebaseCore|FirebaseAnalytics|GoogleMobileAds|StoreKit|GameKit|MultipeerConnectivity)' "$sources"; then
    echo "Package imports an app-owned vendor SDK" >&2
    exit 1
fi

echo "QuizEngine package boundaries are clean"
