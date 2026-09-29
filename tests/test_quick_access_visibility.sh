#!/bin/bash
set -euo pipefail
source "$HOME/.hermes/cache/clt266/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "$HOME/.hermes/cache/scratch/folderium-visibility-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -sdk "$SDKROOT" -target arm64-apple-macos26.0 \
  "$REPO/Folderium App/Folderium/Managers/QuickAccessVisibility.swift" \
  "$REPO/tests/QuickAccessVisibilitySmoke.swift" -o "$SCRATCH/visibility-smoke"
"$SCRATCH/visibility-smoke"
