#!/usr/bin/env python3
"""
convert-hf-encoder.py — Convert a HuggingFace encoder model to a Core ML bundle
suitable for the Swift `HFSemanticEmbeddingProvider`.

Bundle layout produced (under `Models/<bundle-name>/`):
    Model.mlpackage             # CoreML model (input_ids + attention_mask +
                                # optional token_type_ids/position_ids -> last_hidden_state)
    tokenizer.json              # HuggingFace fast-tokenizer JSON (canonical)
    tokenizer_config.json       # auxiliary tokenizer config
    special_tokens_map.json     # optional
    config.json                 # model config

Usage:
    python3 scripts/convert-hf-encoder.py microsoft/graphcodebert-base GraphCodeBERT
    python3 scripts/convert-hf-encoder.py microsoft/codebert-base CodeBERT
    python3 scripts/convert-hf-encoder.py jinaai/jina-embeddings-v2-base-code JinaCode
"""

import json
import shutil
import sys
from pathlib import Path

import coremltools as ct
import torch
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from transformers import AutoConfig, AutoModel, AutoTokenizer

REPO_ROOT = Path(__file__).resolve().parents[1]
MODELS_DIR = REPO_ROOT / "Models"

CONTEXT_WINDOW = 256


@register_torch_op
def new_ones(context, node):
    """coremltools 8.x doesn't ship a converter for `Tensor.new_ones`."""
    inputs = _get_inputs(context, node, min_expected=2)
    size = inputs[1]
    res = mb.fill(shape=size, value=1.0, name=node.name)
    context.add(res)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    hf_name = sys.argv[1]
    bundle_name = sys.argv[2]
    bundle_dir = MODELS_DIR / bundle_name
    bundle_dir.mkdir(parents=True, exist_ok=True)

    print(f"=== Loading {hf_name} ===")
    config = AutoConfig.from_pretrained(hf_name, trust_remote_code=True)
    model = AutoModel.from_pretrained(hf_name, trust_remote_code=True)
    tokenizer = AutoTokenizer.from_pretrained(hf_name, trust_remote_code=True)
    model.eval()

    # Copy tokenizer.json (and the other HF tokenizer files) into the bundle.
    print(f"=== Saving tokenizer to {bundle_dir} ===")
    tokenizer.save_pretrained(str(bundle_dir))

    # Detect required inputs by inspecting the underlying model signature.
    # All four canonical code embedders accept:
    #   - input_ids
    #   - attention_mask
    #   - (optional) token_type_ids
    #   - (optional) position_ids
    has_token_type = "token_type_ids" in tokenizer.model_input_names
    print(f"  has token_type_ids input: {has_token_type}")

    class Wrapped(torch.nn.Module):
        """Encoder + explicit pass-throughs of token_type_ids / position_ids
        so the underlying model doesn't lazily new_ones them at trace time
        (coremltools 8.x's converter can't handle that)."""

        def __init__(self, base, with_token_type):
            super().__init__()
            self.base = base
            self.with_token_type = with_token_type

        def forward(self, input_ids, attention_mask, token_type_ids, position_ids):
            kwargs = {
                "input_ids": input_ids,
                "attention_mask": attention_mask,
                "position_ids": position_ids,
            }
            if self.with_token_type:
                kwargs["token_type_ids"] = token_type_ids
            out = self.base(**kwargs)
            return out.last_hidden_state

    wrapped = Wrapped(model, has_token_type).eval()

    example_ids = torch.zeros((1, CONTEXT_WINDOW), dtype=torch.int32)
    example_mask = torch.ones((1, CONTEXT_WINDOW), dtype=torch.int32)
    example_tt = torch.zeros((1, CONTEXT_WINDOW), dtype=torch.int32)
    example_pos = torch.arange(CONTEXT_WINDOW, dtype=torch.int32).unsqueeze(0)

    print("=== Tracing ===")
    traced = torch.jit.trace(
        wrapped, (example_ids, example_mask, example_tt, example_pos), strict=False
    )

    inputs = [
        ct.TensorType(name="input_ids", shape=(1, CONTEXT_WINDOW), dtype=int),
        ct.TensorType(name="attention_mask", shape=(1, CONTEXT_WINDOW), dtype=int),
        ct.TensorType(name="token_type_ids", shape=(1, CONTEXT_WINDOW), dtype=int),
        ct.TensorType(name="position_ids", shape=(1, CONTEXT_WINDOW), dtype=int),
    ]

    print("=== Converting to Core ML ===")
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        outputs=[ct.TensorType(name="last_hidden_state")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.short_description = f"{hf_name} encoder, last_hidden_state, ctx={CONTEXT_WINDOW}"
    mlmodel.author = "swa convert-hf-encoder.py"

    model_out = bundle_dir / "Model.mlpackage"
    if model_out.exists():
        shutil.rmtree(model_out)
    mlmodel.save(str(model_out))
    print(f"  saved -> {model_out}")

    meta_path = bundle_dir / "swa-meta.json"
    meta = {
        "hf_name": hf_name,
        "context_window": CONTEXT_WINDOW,
        "hidden_size": int(config.hidden_size),
        "model_input_names": list(tokenizer.model_input_names),
    }
    meta_path.write_text(json.dumps(meta, indent=2))
    print(f"  meta  -> {meta_path}")
    print(json.dumps(meta, indent=2))
    print("Done.")


if __name__ == "__main__":
    main()
