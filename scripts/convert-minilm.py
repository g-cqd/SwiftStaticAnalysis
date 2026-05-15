#!/usr/bin/env python3
"""
convert-minilm.py — convert sentence-transformers/all-MiniLM-L6-v2 to Core ML.

Output:
- Models/MiniLM.mlpackage  (the Core ML model, 384-dim mean-pooled BERT output)
- Models/MiniLM-vocab.txt  (WordPiece vocab for the Swift-side tokenizer)
- Models/MiniLM-config.json (dimension + context window metadata)

The Swift CoreMLSemanticEmbeddingProvider loads `.mlpackage` directly.
The tokenizer is WordPiece — simpler than RoBERTa-style BPE, ~100 LOC in Swift.
"""

import json
import os
import sys
from pathlib import Path

import torch
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from transformers import AutoModel, AutoTokenizer


@register_torch_op
def new_ones(context, node):
    """Minimal coremltools converter for `Tensor.new_ones(size, dtype=...)`.

    Coremltools 8.x doesn't ship one; BERT's `extended_attention_mask`
    path emits this op. We fill a tensor of ones of the requested shape.
    """
    inputs = _get_inputs(context, node, min_expected=2)
    size = inputs[1]
    res = mb.fill(shape=size, value=1.0, name=node.name)
    context.add(res)

REPO_ROOT = Path(__file__).resolve().parents[1]
MODELS_DIR = REPO_ROOT / "Models"
MODELS_DIR.mkdir(exist_ok=True)

MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
CONTEXT_WINDOW = 128  # fixed for Core ML conversion; trimmed if longer

print(f"=== Downloading {MODEL_NAME} ===")
model = AutoModel.from_pretrained(MODEL_NAME)
model.eval()
tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)

# Dump vocab for the Swift tokenizer.
vocab_path = MODELS_DIR / "MiniLM-vocab.txt"
print(f"=== Writing vocab to {vocab_path} ===")
vocab = tokenizer.get_vocab()
# Index → token, sorted by index.
inv_vocab = sorted(vocab.items(), key=lambda kv: kv[1])
with open(vocab_path, "w") as f:
    for token, idx in inv_vocab:
        f.write(token + "\n")
print(f"Vocab size: {len(inv_vocab)}")


class MeanPooledMiniLM(torch.nn.Module):
    """Wraps BERT + mean pooling to produce a single 384-dim embedding.

    Pass `token_type_ids` explicitly so the underlying BERT does not lazily
    instantiate them via `new_ones` — that op has no coremltools converter
    in the 8.x line.
    """

    def __init__(self, base):
        super().__init__()
        self.base = base

    def forward(self, input_ids, attention_mask, token_type_ids, position_ids):
        output = self.base(
            input_ids=input_ids,
            attention_mask=attention_mask,
            token_type_ids=token_type_ids,
            position_ids=position_ids,
        )
        last_hidden = output.last_hidden_state  # (1, T, 384)
        mask = attention_mask.unsqueeze(-1).float()  # (1, T, 1)
        masked = last_hidden * mask
        summed = masked.sum(dim=1)  # (1, 384)
        counts = mask.sum(dim=1).clamp(min=1e-9)  # (1, 1)
        return summed / counts  # mean over valid tokens


wrapped = MeanPooledMiniLM(model)
wrapped.eval()

print("=== Tracing model ===")
example_ids = torch.zeros((1, CONTEXT_WINDOW), dtype=torch.int32)
example_mask = torch.ones((1, CONTEXT_WINDOW), dtype=torch.int32)
example_tt = torch.zeros((1, CONTEXT_WINDOW), dtype=torch.int32)
example_pos = torch.arange(CONTEXT_WINDOW, dtype=torch.int32).unsqueeze(0)
traced = torch.jit.trace(wrapped, (example_ids, example_mask, example_tt, example_pos))

print("=== Converting to Core ML ===")
mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, CONTEXT_WINDOW), dtype=int),
        ct.TensorType(name="attention_mask", shape=(1, CONTEXT_WINDOW), dtype=int),
        ct.TensorType(name="token_type_ids", shape=(1, CONTEXT_WINDOW), dtype=int),
        ct.TensorType(name="position_ids", shape=(1, CONTEXT_WINDOW), dtype=int),
    ],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS14,
    compute_units=ct.ComputeUnit.ALL,
)

# Identify ourselves in the bundle.
mlmodel.short_description = (
    "sentence-transformers/all-MiniLM-L6-v2, mean-pooled, "
    f"context={CONTEXT_WINDOW}, dim=384"
)
mlmodel.author = "swa convert-minilm.py"

model_out = MODELS_DIR / "MiniLM.mlpackage"
print(f"=== Saving to {model_out} ===")
mlmodel.save(str(model_out))

config_path = MODELS_DIR / "MiniLM-config.json"
config = {
    "model_name": MODEL_NAME,
    "embedding_dimension": 384,
    "context_window": CONTEXT_WINDOW,
    "input_ids_name": "input_ids",
    "attention_mask_name": "attention_mask",
    "output_name": "embedding",
    "vocab_size": len(vocab),
    "pad_token_id": tokenizer.pad_token_id,
    "cls_token_id": tokenizer.cls_token_id,
    "sep_token_id": tokenizer.sep_token_id,
    "unk_token_id": tokenizer.unk_token_id,
    "do_lower_case": getattr(tokenizer, "do_lower_case", True),
}
print(f"=== Writing config to {config_path} ===")
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(json.dumps(config, indent=2))
print("Done.")
