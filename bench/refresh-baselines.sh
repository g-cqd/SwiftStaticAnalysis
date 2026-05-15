#!/usr/bin/env bash
# refresh-baselines.sh — regenerate bench/baselines/<scenario>.json from a
# fresh `swa-bench` run. Intended for two flows:
#
#   1. Local. Run on the maintainer's workstation after a deliberate perf
#      change (e.g. arena-backed SA-IS in 0.3.0-α.2). Commit the result.
#
#   2. CI. Triggered by `.github/workflows/refresh-baselines.yml`
#      (workflow_dispatch). The action runs this script on the same
#      runner shape (macos-15) that gates the comparison, then opens a
#      PR with the regenerated baselines.
#
# The script is intentionally minimal and deterministic — no flags. Tune
# warmup / iterations by editing the constants below.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

BASELINE_DIR=bench/baselines
FIXTURE="${SWA_BENCH_FIXTURE:-Sources}"
WARMUP="${SWA_BENCH_WARMUP:-2}"
ITERATIONS="${SWA_BENCH_ITERATIONS:-5}"

SCENARIOS=(
    duplicates-exact
    duplicates-near
    duplicates-semantic
    unused-simple
    unused-reachability
    symbol-lookup
)

echo "Building swa-bench (release)..."
swift build -c release --product swa-bench

mkdir -p "$BASELINE_DIR"

for scenario in "${SCENARIOS[@]}"; do
    echo
    echo "=== $scenario ==="
    .build/release/swa-bench \
        "$scenario" "$FIXTURE" \
        --warmup "$WARMUP" --iterations "$ITERATIONS" \
        --output "$BASELINE_DIR/${scenario}.json"
    echo "Wrote $BASELINE_DIR/${scenario}.json"
done

echo
echo "Baselines refreshed in $BASELINE_DIR/."
echo "Diff and commit if the new numbers reflect an intentional change."
