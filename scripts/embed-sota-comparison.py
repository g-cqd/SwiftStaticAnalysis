#!/usr/bin/env python3
"""
embed-sota-comparison.py — Multi-model self-scan A/B for SOTA code embedders.

Runs the same EmbeddingCloneDiscovery-shape pipeline (extract → embed →
all-pairs cosine → percentile-calibrated threshold → union-find groups)
against this repo's Sources/ for each of the canonical code-embedding
SOTA models. Prints a per-model comparison so we can pick the winner
to integrate into the Swift tool.

Models compared:
  - sentence-transformers/all-MiniLM-L6-v2  (baseline, β.15 in-tool)
  - microsoft/codebert-base                  (RoBERTa, code+NL pretrain)
  - microsoft/graphcodebert-base             (RoBERTa + data-flow training)
  - jinaai/jina-embeddings-v2-base-code      (BERT, code-specific, 8192 ctx)
  - Salesforce/codet5p-110m-embedding        (T5+, code retrieval head)

Notes:
- All four code-trained models use RoBERTa-style byte-level BPE; only
  MiniLM uses WordPiece. The Swift integration path will need a BPE
  tokenizer for whichever code model we pick.
- We use the HF `transformers` AutoModel + mean-pooling for everything
  (consistent across architectures) so cosine numbers are comparable.
"""

import re
import sys
import time
from pathlib import Path

import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES_DIR = REPO_ROOT / "Sources"

FUNC_HEADER_RE = re.compile(
    r"(?P<header>(?:public |private |internal |fileprivate |static |@\w+\s*)*"
    r"(?:func|init)\s+[A-Za-z_][A-Za-z0-9_]*\b[^\{]*)\{"
)
MIN_FUNCTION_LINES = 5
MAX_FUNCTION_LINES = 60


def extract_functions(source: str):
    out = []
    for match in FUNC_HEADER_RE.finditer(source):
        brace_pos = match.end() - 1
        depth = 1
        i = brace_pos + 1
        n = len(source)
        in_string = in_line_comment = in_block_comment = False
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

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    return find, union


def mean_pool(token_embeddings, attention_mask):
    """Mask-aware mean over T axis. Same shape as token_embeddings[:, 0]."""
    mask = attention_mask.unsqueeze(-1).float()
    summed = (token_embeddings * mask).sum(dim=1)
    counts = mask.sum(dim=1).clamp(min=1e-9)
    return summed / counts


def embed_corpus(tokenizer, model, snippets, max_length=256, batch_size=8):
    """Returns L2-normalized (N, D) numpy array of embeddings."""
    model.eval()
    device = "cpu"
    vectors = []
    with torch.no_grad():
        for i in range(0, len(snippets), batch_size):
            batch = [s["code"] for s in snippets[i : i + batch_size]]
            tok = tokenizer(
                batch,
                padding=True,
                truncation=True,
                max_length=max_length,
                return_tensors="pt",
            )
            tok = {k: v.to(device) for k, v in tok.items()}
            out = model(**tok)
            # Most HF AutoModels return BaseModelOutput with last_hidden_state.
            last_hidden = out.last_hidden_state
            pooled = mean_pool(last_hidden, tok["attention_mask"])
            # L2 normalize for cosine = dot product.
            pooled = pooled / pooled.norm(dim=1, keepdim=True).clamp(min=1e-9)
            vectors.append(pooled.cpu().numpy())
    return np.vstack(vectors).astype(np.float32)


def evaluate(model_name, tokenizer, model, snippets, max_length=256):
    print(f"\n{'=' * 70}\n=== Evaluating: {model_name}\n{'=' * 70}")
    t0 = time.time()
    embeddings = embed_corpus(tokenizer, model, snippets, max_length=max_length)
    elapsed = time.time() - t0
    print(f"  embedding time: {elapsed:.1f}s  ({elapsed / len(snippets) * 1000:.1f}ms/snippet)")
    sim = embeddings @ embeddings.T
    n = len(snippets)
    upper = sim[np.triu_indices(n, k=1)]
    p99_5 = float(np.percentile(upper, 99.5))
    p99 = float(np.percentile(upper, 99.0))
    p95 = float(np.percentile(upper, 95.0))
    mean_sim = float(upper.mean())
    median_sim = float(np.median(upper))

    print(
        f"  similarity stats: max={float(upper.max()):.3f}  "
        f"p99.5={p99_5:.3f}  p99={p99:.3f}  p95={p95:.3f}  "
        f"mean={mean_sim:.3f}  median={median_sim:.3f}"
    )

    # Pairs above 99.5 threshold (same shape as our Swift discovery).
    pairs = []
    for i in range(n):
        for j in range(i + 1, n):
            if sim[i, j] >= p99_5:
                a, b = snippets[i], snippets[j]
                if a["file"] == b["file"]:
                    if not (a["end_line"] < b["start_line"] or b["end_line"] < a["start_line"]):
                        continue
                pairs.append((i, j, float(sim[i, j])))

    find, union = union_find(n)
    for i, j, _ in pairs:
        union(i, j)
    groups = {}
    for i, j, _ in pairs:
        root = find(i)
        groups.setdefault(root, set()).update([i, j])
    nontrivial_groups = [g for g in groups.values() if len(g) >= 2]

    # Mean group similarity.
    group_sims = []
    for members in nontrivial_groups:
        ml = sorted(members)
        gp = []
        for a_idx in range(len(ml)):
            for b_idx in range(a_idx + 1, len(ml)):
                gp.append(float(sim[ml[a_idx], ml[b_idx]]))
        if gp:
            group_sims.append(float(np.mean(gp)))

    print(f"  pairs above threshold: {len(pairs)}")
    print(f"  connected components ≥2: {len(nontrivial_groups)}")
    if group_sims:
        print(
            f"  group similarity: max={max(group_sims):.3f}  "
            f"mean={float(np.mean(group_sims)):.3f}  median={float(np.median(group_sims)):.3f}"
        )

    # Show top 5 groups for qualitative inspection.
    sorted_groups = sorted(
        nontrivial_groups,
        key=lambda members: -np.mean(
            [
                float(sim[ml[a], ml[b]])
                for ml in [sorted(members)]
                for a in range(len(ml))
                for b in range(a + 1, len(ml))
            ]
        ),
    )
    print(f"\n  Top 5 groups (by mean intra-group cosine):")
    for rank, members in enumerate(sorted_groups[:5]):
        ml = sorted(members)
        pair_sims = [
            float(sim[ml[a], ml[b]])
            for a in range(len(ml))
            for b in range(a + 1, len(ml))
        ]
        mean_g = float(np.mean(pair_sims))
        print(f"    [{rank}] sim={mean_g:.3f} n={len(ml)}")
        for idx in ml:
            s = snippets[idx]
            head = s["code"].strip().split("\n", 1)[0][:80]
            print(f"      {s['file']}:{s['start_line']}-{s['end_line']}  {head}…")

    return {
        "name": model_name,
        "elapsed": elapsed,
        "max": float(upper.max()),
        "p99_5": p99_5,
        "p99": p99,
        "p95": p95,
        "mean": mean_sim,
        "median": median_sim,
        "pairs": len(pairs),
        "components": len(nontrivial_groups),
    }


def main():
    print("=== Walking Sources/ ===")
    snippets = []
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel = path.relative_to(REPO_ROOT)
        text = path.read_text()
        for start_line, end_line, code in extract_functions(text):
            snippets.append(
                {
                    "file": str(rel),
                    "start_line": start_line,
                    "end_line": end_line,
                    "code": code,
                }
            )
    print(f"  {len(snippets)} function snippets")

    models = [
        ("sentence-transformers/all-MiniLM-L6-v2", 256),
        ("microsoft/codebert-base", 256),
        ("microsoft/graphcodebert-base", 256),
        ("jinaai/jina-embeddings-v2-base-code", 512),
        ("Salesforce/codet5p-110m-embedding", 256),
    ]

    summary = []
    for name, max_length in models:
        try:
            tokenizer = AutoTokenizer.from_pretrained(name, trust_remote_code=True)
            model = AutoModel.from_pretrained(name, trust_remote_code=True)
            stats = evaluate(name, tokenizer, model, snippets, max_length=max_length)
            summary.append(stats)
        except Exception as e:
            print(f"\n  FAILED {name}: {type(e).__name__}: {str(e)[:200]}")

    print("\n\n========================  SOTA COMPARISON SUMMARY  ========================")
    headers = ["model", "time(s)", "p99.5", "max", "pairs", "groups"]
    print(
        f"{headers[0]:<48} {headers[1]:>8} {headers[2]:>7} {headers[3]:>7} {headers[4]:>7} {headers[5]:>7}"
    )
    print("-" * 90)
    for s in summary:
        print(
            f"{s['name']:<48} {s['elapsed']:>8.1f} {s['p99_5']:>7.3f} "
            f"{s['max']:>7.3f} {s['pairs']:>7} {s['components']:>7}"
        )
    print()


if __name__ == "__main__":
    main()
