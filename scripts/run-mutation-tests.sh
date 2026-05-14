#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
output_dir="$repo_root/.tmp/mutation"
selected_profiles=()

profiles=(
    core
    duplication
    unused
    symbol
    output
    umbrella
    cli
    mcp
)

list_profiles() {
    printf '%s\n' "${profiles[@]}"
}

profile_test_target() {
    case "$1" in
    core) echo "SwiftStaticAnalysisCoreTests" ;;
    duplication) echo "DuplicationDetectorTests" ;;
    unused) echo "UnusedCodeDetectorTests" ;;
    symbol) echo "SymbolLookupTests" ;;
    output) echo "SwiftStaticAnalysisOutputTests" ;;
    umbrella) echo "SwiftStaticAnalysisTests" ;;
    cli) echo "CLITests" ;;
    mcp) echo "SwiftStaticAnalysisMCPTests" ;;
    *)
        echo "Unknown profile: $1" >&2
        exit 1
        ;;
    esac
}

profile_mutation_roots() {
    case "$1" in
    core) echo "Sources/SwiftStaticAnalysisCore" ;;
    duplication) echo "Sources/DuplicationDetector" ;;
    unused) echo "Sources/UnusedCodeDetector" ;;
    symbol) echo "Sources/SymbolLookup" ;;
    output) echo "Sources/SwiftStaticAnalysisOutput" ;;
    umbrella) echo "Sources/SwiftStaticAnalysis" ;;
    cli) echo "Sources/swa" ;;
    mcp) echo "Sources/SwiftStaticAnalysisMCP Sources/swa-mcp" ;;
    *)
        echo "Unknown profile: $1" >&2
        exit 1
        ;;
    esac
}

profile_timeout() {
    case "$1" in
    core | duplication | unused | symbol) echo "180" ;;
    output | umbrella | cli | mcp) echo "120" ;;
    *)
        echo "Unknown profile: $1" >&2
        exit 1
        ;;
    esac
}

usage() {
    cat <<'EOF'
Usage: scripts/run-mutation-tests.sh [--profile NAME]... [--output-dir PATH] [--list-profiles]

Options:
  --profile NAME      Mutation profile to run. Repeat to run multiple profiles.
  --output-dir PATH   Directory for Muter configs and JSON reports.
  --list-profiles     Print the supported mutation profiles.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --profile)
        selected_profiles+=("$2")
        shift 2
        ;;
    --output-dir)
        output_dir="$2"
        shift 2
        ;;
    --list-profiles)
        list_profiles
        exit 0
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 1
        ;;
    esac
done

if [[ ${#selected_profiles[@]} -eq 0 ]] || [[ "${selected_profiles[*]}" == "all" ]]; then
    selected_profiles=("${profiles[@]}")
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

muter_path="$("$script_dir/bootstrap-muter.sh")"

pushd "$repo_root" >/dev/null

for profile in "${selected_profiles[@]}"; do
    target="$(profile_test_target "$profile")"
    files_to_mutate=""
    for root in $(profile_mutation_roots "$profile"); do
        while IFS= read -r file; do
            if [[ -n "$files_to_mutate" ]]; then
                files_to_mutate+=","
            fi
            files_to_mutate+="$file"
        done < <(find "$root" -type f -name '*.swift' | sort)
    done

    if [[ -z "$files_to_mutate" ]]; then
        echo "Profile '${profile}' did not resolve to any Swift files." >&2
        exit 1
    fi

    timeout_seconds="$(profile_timeout "$profile")"
    config_path="$output_dir/${profile}.muter.conf.yml"
    report_path="$output_dir/${profile}.json"
    log_path="$output_dir/${profile}.muter.log"
    stage_path="$output_dir/staging/${profile}"

    cat > "$config_path" <<EOF
arguments:
- test
- --parallel
- --filter
- ${target}
executable: /usr/bin/swift
exclude:
- .bin
- .build
- Package.swift
- Tests
- Tests/Fixtures
testSuiteTimeout: ${timeout_seconds}
EOF

    rm -rf "$stage_path" "${stage_path}_mutated"
    mkdir -p "$stage_path"
    rsync -a --delete \
        --exclude '.bin' \
        --exclude '.build' \
        --exclude '.git' \
        --exclude '.tmp' \
        --exclude 'SwiftStaticAnalysis_mutated' \
        ./ "$stage_path/"

    echo "Running mutation profile '${profile}' with test target '${target}'"
    set +e
    (
        cd "$stage_path"
        "$muter_path" \
            --configuration "$config_path" \
            --files-to-mutate "$files_to_mutate" \
            --format json \
            --output "$report_path" \
            --skip-coverage \
            --skip-update-check
    ) 2>&1 | tee "$log_path"
    muter_status=${PIPESTATUS[0]}
    set -e

    if [[ $muter_status -ne 0 ]]; then
        if rg -q "wasn't able to discover any code it could mutation test" "$log_path"; then
            printf '{\n  "skipped": true,\n  "reason": "no_mutation_points"\n}\n' > "$report_path"
            echo "Skipping mutation profile '${profile}': no mutation points found."
            continue
        fi

        exit "$muter_status"
    fi
done

popd >/dev/null
