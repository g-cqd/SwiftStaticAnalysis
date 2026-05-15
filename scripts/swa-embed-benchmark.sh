#!/usr/bin/env bash
# swa-embed-benchmark.sh
#
# Benchmark every Models/<Bundle>/ through the swa CLI on this repo's Sources/.
# Reports per-model + per-threshold: group count, dup-line count, wall time,
# and the top-3 discovered group cosines.
#
# Apples-to-apples: same input snippets (FunctionSnippetExtractor walking
# Sources/), same SwiftSyntax extraction, same EmbeddingCloneDiscovery
# pipeline. Only the bundle (model + tokenizer) differs per run.

set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

SWA=.build/release/swa
SRC=Sources
RESULTS=/tmp/swa-bench-results.tsv
DETAILS=/tmp/swa-bench-details.txt

THRESHOLDS=(0.80 0.85 0.90 0.95)
BUNDLES=(MiniLM BGEBase BGELarge MxbaiLarge MSMarcoCode CodeBERT EmbeddingGemma)

# Ensure release binary exists
if [ ! -x "$SWA" ]; then
    echo "Building release..."
    swift build -c release --product swa
fi

# Header
printf "bundle\tthreshold\tgroups\tdup_lines\ttime_s\ttop_cosine\n" > "$RESULTS"
: > "$DETAILS"

for BUNDLE in "${BUNDLES[@]}"; do
    if [ ! -d "Models/$BUNDLE" ]; then
        echo "SKIP: Models/$BUNDLE not present"
        continue
    fi
    for TH in "${THRESHOLDS[@]}"; do
        OUT=$(mktemp)
        START=$(date +%s)
        "$SWA" duplicates "$SRC" \
            --embedding-bundle "Models/$BUNDLE" \
            --embedding-similarity "$TH" \
            --embedding-max-length 128 \
            --types exact --min-tokens 10000 \
            -f text 2>&1 | grep -v "E5RT" > "$OUT"
        END=$(date +%s)
        ELAPSED=$((END - START))

        # Parse output
        GROUPS=$(grep -cE '^  \[' "$OUT" || echo 0)
        DUP_LINES=$(grep -oE 'semantic [0-9]+ groups [0-9]+ duplicated lines' "$OUT" \
                    | awk '{print $4}' | head -1)
        DUP_LINES=${DUP_LINES:-0}
        TOP_COS=$(grep -oE '\[1\] [0-9]+%' "$OUT" | head -1 | awk '{print $2}')
        TOP_COS=${TOP_COS:-"--"}

        printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$BUNDLE" "$TH" "$GROUPS" "$DUP_LINES" "$ELAPSED" "$TOP_COS" \
            | tee -a "$RESULTS"

        # Capture top-5 groups for qualitative review
        {
            echo "=== $BUNDLE @ $TH (groups=$GROUPS, ${ELAPSED}s) ==="
            grep -B1 -A2 '^  \[[1-5]\]' "$OUT" | head -25 || true
            echo
        } >> "$DETAILS"

        rm -f "$OUT"
    done
done

echo
echo "===================  BENCHMARK SUMMARY  ==================="
column -t -s $'\t' "$RESULTS"
echo
echo "Detailed top-groups per run: $DETAILS"
