#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

tool_root="$repo_root/.bin/muter"
source_dir="$tool_root/src"
binary_path="$tool_root/bin/muter"
stamp_path="$tool_root/ref.txt"

muter_repo="${MUTER_REPO:-https://github.com/muter-mutation-testing/muter.git}"
muter_ref="${MUTER_REF:-master}"

if [[ -x "$binary_path" ]] && [[ -f "$stamp_path" ]] && [[ "$(cat "$stamp_path")" == "$muter_ref" ]]; then
    printf '%s\n' "$binary_path"
    exit 0
fi

rm -rf "$tool_root"
mkdir -p "$tool_root/bin"

git clone --depth 1 "$muter_repo" "$source_dir" >&2
if [[ "$muter_ref" != "master" ]]; then
    git -C "$source_dir" fetch --depth 1 origin "$muter_ref" >&2
    git -C "$source_dir" checkout FETCH_HEAD >&2
fi

swift build -c release --package-path "$source_dir" --product muter >&2
cp "$source_dir/.build/release/muter" "$binary_path"
printf '%s\n' "$muter_ref" > "$stamp_path"
printf '%s\n' "$binary_path"
