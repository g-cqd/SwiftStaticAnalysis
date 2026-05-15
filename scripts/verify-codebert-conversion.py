#!/usr/bin/env python3
"""
verify-codebert-conversion.py — A/B the original PyTorch CodeBERT vs the
converted Core ML CodeBERT (rsvalerio/codebert-base-coreml) on a fixed
set of snippets, to detect any conversion-induced accuracy loss.

Reports:
  - Pairwise cosine similarities under each backend
  - Max divergence between PyTorch and CoreML vectors per snippet
  - Whether PyTorch and CoreML agree on the relative ranking of pairs
"""

import json
import numpy as np
import torch
from pathlib import Path
from transformers import AutoModel, AutoTokenizer
import coremltools as ct

REPO_ROOT = Path(__file__).resolve().parents[1]
BUNDLE = REPO_ROOT / "Models" / "CodeBERT"
CTX = 128


SNIPPETS = {
    "fnv1a-original": (
        "public static func hash(_ data: [UInt8]) -> UInt64 {"
        "    var hash: UInt64 = 0xcbf29ce484222325;"
        "    for byte in data { hash ^= UInt64(byte); hash &*= 0x100000001B3 }"
        "    return hash"
        "}"
    ),
    "fnv1a-renamed": (
        "public static func computeHash(_ bytes: [UInt8]) -> UInt64 {"
        "    var result: UInt64 = 0xcbf29ce484222325;"
        "    for b in bytes { result ^= UInt64(b); result &*= 0x100000001B3 }"
        "    return result"
        "}"
    ),
    "parse-url": (
        "func parseURL(_ s: String) -> URL? { return URL(string: s) }"
    ),
    "extractAssigned": (
        "private func extractAssignedValue(_ statement: CFGStatement) -> String? {"
        "    let desc = statement.syntax.description.trimmingCharacters(in: .whitespacesAndNewlines);"
        "    if desc.count < 100 { return desc }"
        "    return nil"
        "}"
    ),
    "extractValue": (
        "private func extractValue(from statement: CFGStatement) -> String? {"
        "    let desc = statement.syntax.description.trimmingCharacters(in: .whitespacesAndNewlines);"
        "    if desc.count < 50 { return desc }"
        "    return nil"
        "}"
    ),
}

names = list(SNIPPETS.keys())


def mean_pool(last_hidden, attention_mask):
    mask = attention_mask.unsqueeze(-1).float()
    summed = (last_hidden * mask).sum(dim=1)
    counts = mask.sum(dim=1).clamp(min=1e-9)
    return summed / counts


def cosine(a, b):
    a = a / (np.linalg.norm(a) + 1e-9)
    b = b / (np.linalg.norm(b) + 1e-9)
    return float(np.dot(a, b))


print("=" * 72)
print("PyTorch CodeBERT (microsoft/codebert-base, no conversion)")
print("=" * 72)
tok = AutoTokenizer.from_pretrained("microsoft/codebert-base")
model = AutoModel.from_pretrained("microsoft/codebert-base")
model.eval()
pt_vecs = {}
with torch.no_grad():
    for name, code in SNIPPETS.items():
        enc = tok(code, padding="max_length", truncation=True, max_length=CTX, return_tensors="pt")
        out = model(**enc)
        pooled = mean_pool(out.last_hidden_state, enc["attention_mask"])
        pt_vecs[name] = pooled[0].cpu().numpy()
print("vectors shape:", pt_vecs[names[0]].shape)


print()
print("=" * 72)
print("Core ML CodeBERT (rsvalerio/codebert-base-coreml)")
print("=" * 72)
mlmodel = ct.models.MLModel(str(BUNDLE / "Model.mlpackage"))
print("mlmodel inputs:", [i.name for i in mlmodel.get_spec().description.input])
print("mlmodel outputs:", [o.name for o in mlmodel.get_spec().description.output])

cml_vecs = {}
# Reuse the same tokenizer so token IDs are identical between backends.
for name, code in SNIPPETS.items():
    enc = tok(code, padding="max_length", truncation=True, max_length=CTX, return_tensors="np")
    input_ids = enc["input_ids"].astype(np.int32)
    attention_mask = enc["attention_mask"].astype(np.int32)
    pred = mlmodel.predict({
        "input_ids": input_ids,
        "attention_mask": attention_mask,
    })
    out_key = "hidden_states" if "hidden_states" in pred else "last_hidden_state"
    last_hidden = pred[out_key]  # (1, T, D)
    mask = attention_mask[..., None].astype(np.float32)
    pooled = (last_hidden * mask).sum(axis=1) / np.clip(mask.sum(axis=1), 1e-9, None)
    cml_vecs[name] = pooled[0]


print()
print("=" * 72)
print("PER-VECTOR DIVERGENCE (PyTorch vs CoreML)")
print("=" * 72)
print(f"{'snippet':<22} {'cos(pt,cml)':>14} {'L2 dist':>12} {'rel diff %':>14}")
for name in names:
    pt_v = pt_vecs[name]
    cml_v = cml_vecs[name]
    pt_norm = pt_v / (np.linalg.norm(pt_v) + 1e-9)
    cml_norm = cml_v / (np.linalg.norm(cml_v) + 1e-9)
    cos = float(np.dot(pt_norm, cml_norm))
    dist = float(np.linalg.norm(pt_v - cml_v))
    rel = 100.0 * dist / (np.linalg.norm(pt_v) + 1e-9)
    print(f"{name:<22} {cos:>14.6f} {dist:>12.4f} {rel:>13.2f}%")


print()
print("=" * 72)
print("PAIRWISE COSINE COMPARISON")
print("=" * 72)
print(f"{'pair':<48} {'pytorch':>10} {'coreml':>10} {'Δ':>8}")
pairs = [
    ("fnv1a-original", "fnv1a-renamed"),
    ("fnv1a-original", "parse-url"),
    ("fnv1a-original", "extractAssigned"),
    ("extractAssigned", "extractValue"),
    ("extractAssigned", "parse-url"),
    ("extractValue", "parse-url"),
]
for a, b in pairs:
    pt_c = cosine(pt_vecs[a], pt_vecs[b])
    cml_c = cosine(cml_vecs[a], cml_vecs[b])
    delta = cml_c - pt_c
    label = f"{a}  ↔  {b}"
    print(f"{label:<48} {pt_c:>10.4f} {cml_c:>10.4f} {delta:>+8.4f}")


print()
print("=" * 72)
print("RELATIVE-RANKING AGREEMENT")
print("=" * 72)
# Sort pairs by cosine under each backend, check agreement.
pt_ranking = sorted(pairs, key=lambda ab: -cosine(pt_vecs[ab[0]], pt_vecs[ab[1]]))
cml_ranking = sorted(pairs, key=lambda ab: -cosine(cml_vecs[ab[0]], cml_vecs[ab[1]]))
print("PyTorch top->bot:")
for ab in pt_ranking:
    print(f"  {ab[0]} ↔ {ab[1]}: {cosine(pt_vecs[ab[0]], pt_vecs[ab[1]]):.4f}")
print()
print("CoreML top->bot:")
for ab in cml_ranking:
    print(f"  {ab[0]} ↔ {ab[1]}: {cosine(cml_vecs[ab[0]], cml_vecs[ab[1]]):.4f}")
print()
print("Same ordering?" , "YES" if pt_ranking == cml_ranking else "NO — divergence")
