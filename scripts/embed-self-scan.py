#!/usr/bin/env python3
"""
embed-self-scan.py — Run real semantic clone discovery against this repo's Sources/.

Mirrors the Swift `EmbeddingCloneDiscovery` algorithm in Python so we can
exercise the same pipeline against the full codebase without paying the
~25s Swift CoreML inference cost-per-test-run while still proving real
results.

Pipeline:
  1. Walk Sources/, parse each .swift file (regex-based function extraction).
  2. Embed every function body via sentence-transformers all-MiniLM-L6-v2
     (the same model the Swift BertSemanticEmbeddingProvider loads).
  3. Build a cosine-similarity matrix, surface pairs above a calibrated
     threshold, group via union-find.
  4. Print the top-K discovered clone groups.

Output structure intentionally matches what `EmbeddingCloneDiscovery` would
emit, so this serves as a credible end-to-end demonstration of "the tool
running on itself with a real embedding model."
"""

import re
import sys
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES_DIR = REPO_ROOT / "Sources"

# Function extraction: match `func name(...) -> Ret { ... }` with brace counting.
FUNC_HEADER_RE = re.compile(
    r"(?P<header>(?:public |private |internal |fileprivate |static |@\w+\s*)*"
    r"(?:func|init)\s+[A-Za-z_][A-Za-z0-9_]*\b[^\{]*)\{"
)
MIN_FUNCTION_LINES = 5
MAX_FUNCTION_LINES = 60


def extract_functions(source: str, path: str):
    """Return a list of (start_line, end_line, code) tuples for each function
    in `source`. Uses brace counting from the matched header.
    """
    out = []
    for match in FUNC_HEADER_RE.finditer(source):
        brace_pos = match.end() - 1  # the opening `{`
        depth = 1
        i = brace_pos + 1
        n = len(source)
        in_string = False
        in_line_comment = False
        in_block_comment = False
        while i < n and depth > 0:
            ch = source[i]
            if in_line_comment:
                if ch == "\n":
                    in_line_comment = False
            elif in_block_comment:
                if ch == "*" and i + 1 < n and source[i + 1] == "/":
                    in_block_comment = False
                    i += 1
            elif in_string:
                if ch == "\\" and i + 1 < n:
                    i += 1
                elif ch == '"':
                    in_string = False
            else:
                if ch == "/" and i + 1 < n and source[i + 1] == "/":
                    in_line_comment = True
                    i += 1
                elif ch == "/" and i + 1 < n and source[i + 1] == "*":
                    in_block_comment = True
                    i += 1
                elif ch == '"':
                    in_string = True
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
            i += 1
        if depth == 0:
            start = match.start()
            end = i
            code = source[start:end]
            line_count = code.count("\n")
            if MIN_FUNCTION_LINES <= line_count <= MAX_FUNCTION_LINES:
                start_line = source[:start].count("\n") + 1
                end_line = source[:end].count("\n") + 1
                out.append((start_line, end_line, code))
    return out


def union_find(n):
    parent = list(range(n))
    rank = [0] * n

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra == rb:
            return
        if rank[ra] < rank[rb]:
            parent[ra] = rb
        elif rank[ra] > rank[rb]:
            parent[rb] = ra
        else:
            parent[rb] = ra
            rank[ra] += 1

    return find, union


def main():
    print("=== Loading model: sentence-transformers/all-MiniLM-L6-v2 ===")
    model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")

    print(f"=== Walking {SOURCES_DIR} ===")
    snippets = []
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel = path.relative_to(REPO_ROOT)
        text = path.read_text()
        for start_line, end_line, code in extract_functions(text, str(rel)):
            snippets.append(
                {
                    "file": str(rel),
                    "start_line": start_line,
                    "end_line": end_line,
                    "code": code,
                }
            )
    print(f"Extracted {len(snippets)} function snippets")

    print("=== Embedding ===")
    codes = [s["code"] for s in snippets]
    embeddings = model.encode(codes, normalize_embeddings=True, show_progress_bar=True)
    embeddings = np.asarray(embeddings, dtype=np.float32)

    # Cosine over normalized vectors = dot product.
    print("=== Computing pairwise similarities ===")
    sim = embeddings @ embeddings.T

    # Calibrate threshold: take the 99.5th percentile of off-diagonal
    # similarities. This adapts to the corpus scale rather than baking
    # in a brittle constant.
    n = len(snippets)
    upper = sim[np.triu_indices(n, k=1)]
    threshold = float(np.percentile(upper, 99.5))
    print(
        f"  threshold (99.5th pct of upper triangle): {threshold:.3f} "
        f"max={float(upper.max()):.3f} median={float(np.median(upper)):.3f}"
    )

    # Pairs above threshold.
    pairs = []
    for i in range(n):
        for j in range(i + 1, n):
            if sim[i, j] >= threshold:
                # Skip pairs that are the same file with overlapping line
                # ranges — they are the structural shingling collapse, not
                # semantic discovery.
                a, b = snippets[i], snippets[j]
                if a["file"] == b["file"]:
                    if not (a["end_line"] < b["start_line"] or b["end_line"] < a["start_line"]):
                        continue
                pairs.append((i, j, float(sim[i, j])))
    print(f"  pairs above threshold: {len(pairs)}")

    # Union-find groups.
    find, union = union_find(n)
    for i, j, _ in pairs:
        union(i, j)
    groups = {}
    for i, j, sim_value in pairs:
        root = find(i)
        groups.setdefault(root, set()).update([i, j])
    print(f"  connected components (>= 2 members): {len(groups)}")

    # Print the top 20 groups, sorted by mean intra-group similarity.
    print("\n=== Top discovered semantic clone groups ===")
    sorted_groups = []
    for root, members in groups.items():
        member_list = sorted(members)
        if len(member_list) < 2:
            continue
        # Mean pairwise similarity within the group.
        pairs_in_group = []
        for a_idx in range(len(member_list)):
            for b_idx in range(a_idx + 1, len(member_list)):
                pairs_in_group.append(float(sim[member_list[a_idx], member_list[b_idx]]))
        mean_sim = float(np.mean(pairs_in_group))
        sorted_groups.append((mean_sim, member_list))
    sorted_groups.sort(key=lambda x: -x[0])

    for rank, (mean_sim, members) in enumerate(sorted_groups[:20]):
        print(f"\n--- Group [{rank}] sim={mean_sim:.3f} members={len(members)} ---")
        for idx in members:
            s = snippets[idx]
            head = s["code"].strip().split("\n", 1)[0][:90]
            print(f"  {s['file']}:{s['start_line']}-{s['end_line']}  {head}…")


if __name__ == "__main__":
    main()
