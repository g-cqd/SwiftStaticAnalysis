#!/usr/bin/env bash
# compare.sh — gate a PR on benchmark regressions.
#
# Inputs:
#   $1  Directory of fresh results JSON (one file per scenario; same
#       naming as `bench/baselines/`).
#   $2  Directory of baseline JSON (defaults to `bench/baselines`).
#
# Thresholds:
#   MEAN_REGRESSION_PCT   default 10  (% over baseline mean = fail)
#   P99_REGRESSION_PCT    default 25  (% over baseline p99  = fail)
#
# Per-scenario overrides live in
#   bench/baselines/<scenario>.thresholds.json
# with shape `{ "meanPct": Number, "p99Pct": Number }`. Missing file →
# defaults. The override file is loaded best-effort; an unreadable file
# falls back to defaults.
#
# Outputs:
#   - Markdown table on stdout (suitable for a PR comment).
#   - Exit 0 = within thresholds.
#   - Exit 1 = any scenario regressed beyond its threshold.
#   - Exit 2 = baseline or results file missing for an expected scenario.

set -euo pipefail

RESULTS_DIR="${1:-.bench}"
BASELINE_DIR="${2:-bench/baselines}"
DEFAULT_MEAN_PCT="${MEAN_REGRESSION_PCT:-10}"
DEFAULT_P99_PCT="${P99_REGRESSION_PCT:-25}"

if [[ ! -d "$BASELINE_DIR" ]]; then
    echo "compare.sh: baseline directory '$BASELINE_DIR' not found." >&2
    exit 2
fi

if [[ ! -d "$RESULTS_DIR" ]]; then
    echo "compare.sh: results directory '$RESULTS_DIR' not found." >&2
    exit 2
fi

fail_count=0
missing_count=0

emit_row() {
    # Emit a markdown table row. Caller supplies status + numbers.
    printf "| %s | %s | %s | %s | %s | %s | %s |\n" "$@"
}

emit_row "Scenario" "Status" "Mean now" "Mean base" "Δ%" "p99 now" "p99 base"
emit_row "---" "---" "---:" "---:" "---:" "---:" "---:"

for baseline in "$BASELINE_DIR"/*.json; do
    [[ -f "$baseline" ]] || continue
    scenario_file=$(basename "$baseline")
    scenario=${scenario_file%.json}
    result="$RESULTS_DIR/$scenario.json"

    if [[ ! -f "$result" ]]; then
        emit_row "$scenario" "🚫 missing" "—" "—" "—" "—" "—"
        missing_count=$((missing_count + 1))
        continue
    fi

    mean_now=$(jq -r '.wallSecondsMean' "$result")
    mean_base=$(jq -r '.wallSecondsMean' "$baseline")
    p99_now=$(jq -r '.wallSecondsP99' "$result")
    p99_base=$(jq -r '.wallSecondsP99' "$baseline")

    overrides="$BASELINE_DIR/$scenario.thresholds.json"
    mean_pct=$DEFAULT_MEAN_PCT
    p99_pct=$DEFAULT_P99_PCT
    if [[ -f "$overrides" ]]; then
        mean_override=$(jq -r '.meanPct // empty' "$overrides" 2>/dev/null || echo "")
        p99_override=$(jq -r '.p99Pct // empty' "$overrides" 2>/dev/null || echo "")
        [[ -n "$mean_override" ]] && mean_pct=$mean_override
        [[ -n "$p99_override" ]] && p99_pct=$p99_override
    fi

    mean_delta=$(awk -v now="$mean_now" -v base="$mean_base" 'BEGIN{ if (base+0 == 0) print 0; else printf "%.2f", (now/base - 1) * 100 }')
    p99_delta=$(awk -v now="$p99_now" -v base="$p99_base" 'BEGIN{ if (base+0 == 0) print 0; else printf "%.2f", (now/base - 1) * 100 }')

    mean_breached=$(awk -v d="$mean_delta" -v t="$mean_pct" 'BEGIN{ print (d+0 > t+0) ? 1 : 0 }')
    p99_breached=$(awk -v d="$p99_delta" -v t="$p99_pct" 'BEGIN{ print (d+0 > t+0) ? 1 : 0 }')

    status="✅ ok"
    if [[ "$mean_breached" == "1" || "$p99_breached" == "1" ]]; then
        status="❌ regressed"
        fail_count=$((fail_count + 1))
    fi

    mean_now_fmt=$(awk -v v="$mean_now" 'BEGIN{ printf "%.4fs", v }')
    mean_base_fmt=$(awk -v v="$mean_base" 'BEGIN{ printf "%.4fs", v }')
    p99_now_fmt=$(awk -v v="$p99_now" 'BEGIN{ printf "%.4fs", v }')
    p99_base_fmt=$(awk -v v="$p99_base" 'BEGIN{ printf "%.4fs", v }')

    emit_row "$scenario" "$status" "$mean_now_fmt" "$mean_base_fmt" "${mean_delta}%" "$p99_now_fmt" "$p99_base_fmt"
done

echo
echo "_Thresholds: mean ≤ +${DEFAULT_MEAN_PCT}%, p99 ≤ +${DEFAULT_P99_PCT}% over baseline._"

if [[ "$missing_count" -gt 0 ]]; then
    echo "compare.sh: $missing_count scenario(s) missing from results." >&2
    exit 2
fi

if [[ "$fail_count" -gt 0 ]]; then
    echo "compare.sh: $fail_count scenario(s) exceeded regression thresholds." >&2
    exit 1
fi

exit 0
