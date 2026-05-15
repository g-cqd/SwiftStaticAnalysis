# Semantic-Deep Clone Detection

Wire a code-embedding model into the duplication detector to tighten
clone-group precision past what token-shingle MinHash and AST
fingerprinting can reach alone.

## Overview

`DuplicationDetector`'s structural passes (suffix-array exact,
MinHash near, AST-fingerprint semantic) produce candidate clone
groups based on syntactic similarity. Setting
`DuplicationConfiguration.semanticEmbeddingProvider` activates a
verification pass: every candidate group is re-scored against the
embedding-space cosine similarity of its members, and groups whose
minimum pairwise similarity falls below
`semanticEmbeddingThreshold` are dropped as token-level false
positives.

No model bundle ships with SwiftStaticAnalysis. The integration is
**bring-your-own-model**: you supply a Core ML model, a tokenizer
closure, and the model's dimension / context window; the detector
uses your provider.

## Building a `CoreMLSemanticEmbeddingProvider`

### 1. Pick a code-embedding model

The best public options as of 2025:

| Model | Dim | Context | Source |
|---|---|---|---|
| CodeBERT-base | 768 | 512 | https://huggingface.co/microsoft/codebert-base |
| GraphCodeBERT-base | 768 | 512 | https://huggingface.co/microsoft/graphcodebert-base |
| CodeT5-base (encoder) | 768 | 512 | https://huggingface.co/Salesforce/codet5-base |

All three are trained on multi-language code corpora. None are
Swift-fine-tuned out of the box. For Swift-heavy codebases, expect
~10-15 % lower recall than the published BigCloneBench (Java) F1
numbers; a fine-tune on a labelled Swift clone corpus would close
the gap if one existed publicly.

### 2. Convert to Core ML

Use `coremltools` from PyTorch. The standard recipe:

```python
import coremltools as ct
import torch
from transformers import RobertaModel, RobertaTokenizer

# Load the source model.
model = RobertaModel.from_pretrained("microsoft/codebert-base")
model.eval()

# Wrap to produce a single fixed-shape input.
class Wrapper(torch.nn.Module):
    def __init__(self, base):
        super().__init__()
        self.base = base
    def forward(self, input_ids):
        return self.base(input_ids).pooler_output

wrapped = Wrapper(model)
example = torch.zeros((1, 512), dtype=torch.int32)

traced = torch.jit.trace(wrapped, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_ids", shape=(1, 512), dtype=int)],
    outputs=[ct.TensorType(name="pooler_output")],
    minimum_deployment_target=ct.target.macOS14,
)
mlmodel.save("CodeBERT.mlmodel")
```

`coremltools` will compile this to an `.mlmodelc` on first load,
or you can pre-compile via `xcrun coremlc compile`.

### 3. Build a Swift `Tokenizer`

The tokenizer closure converts a Swift `String` into the model's
input token IDs. For RoBERTa-family models (CodeBERT,
GraphCodeBERT), the vocab is BPE-encoded and ships as `vocab.json`
+ `merges.txt`. Pre-tokenize at Python time, ship the resulting
table to Swift, and bridge:

```swift
import Foundation
import DuplicationDetector

/// CodeBERT BPE tokenizer. The actual encode step is whatever
/// matches your model's training tokenizer — this signature is
/// what `CoreMLSemanticEmbeddingProvider` needs.
let tokenizer: CoreMLSemanticEmbeddingProvider.Tokenizer = { snippet in
    // 1. Apply CodeBERT's BPE encoding. The simplest path is to
    //    serialise the snippet to a Python helper at build time
    //    that emits a Swift `let` array; alternatively, port the
    //    BPE encoder to Swift (a few hundred lines of code).
    let ids = encodeWithCodeBERTBPE(snippet)  // [Int32]

    // 2. Add the model's required special tokens. RoBERTa starts
    //    with <s> (id 0) and ends with </s> (id 2).
    var result: [Int32] = [0]
    result.append(contentsOf: ids.prefix(510))  // cap to 510 + 2 specials = 512
    result.append(2)
    return result
}

let provider = CoreMLSemanticEmbeddingProvider(
    modelURL: URL(fileURLWithPath: "/path/to/CodeBERT.mlmodelc"),
    tokenizer: tokenizer,
    embeddingDimension: 768,
    contextWindow: 512,
    inputName: "input_ids",
    outputName: "pooler_output",
)
```

### 4. Plug into `DuplicationConfiguration`

```swift
var config = DuplicationConfiguration.default
config.semanticEmbeddingProvider = provider
config.semanticEmbeddingThreshold = 0.95

let detector = DuplicationDetector(configuration: config)
let clones = try await detector.detectClones(in: swiftFiles)
```

The detector runs its standard structural passes first, then the
verification pass on the candidate set. Embedding failures
(snippet exceeds context window, model load fails) leave the group
in place — fail-open keeps genuine clones from being dropped on a
single oversized member.

## Performance characteristics

- **Per-snippet inference**: ~5–50 ms on M-series Neural Engine
  (768-dim CodeBERT pooler), 50–500 ms on Intel CPU. Run
  duration scales with the structural-pass candidate count, not
  the total source corpus.
- **Memory**: Core ML model bundles are typically 200–500 MB on
  disk; Neural Engine inference uses ~100 MB additional RSS.
- **Throughput**: not currently batched — `embed(snippets:)`
  serialises through `embed(snippet:)`. Override in a subclass to
  batch into a single `MLPrediction` call if your model accepts
  a flexible batch dimension.

## Threshold tuning

- **0.95 (default)**: aggressive precision tightening. Drops
  groups where any pair has cosine similarity below 0.95.
- **0.90**: balanced. Drops obvious false positives, keeps
  structurally similar variants.
- **0.85**: permissive. Roughly matches the structural detector's
  signal; the verification pass barely fires.

## What semantic-deep does NOT do

The current integration is **precision tightening**, not **recall
recovery**. It only re-scores groups the structural passes already
produced. Embedding-based clone *discovery* (embed every snippet
in the corpus, do ANN search to find similarity pairs MinHash
missed) needs a different pipeline:

1. Embed every shingled snippet → vector store.
2. Build an HNSW / IVF index over the vectors.
3. For each snippet, query its top-k nearest neighbors.
4. Threshold + group.

This shape would catch cross-idiom equivalents (the for-loop vs.
reduce false-negative class) that token-shingle MinHash misses
entirely. It's queued as a future direction. The current
`SemanticEmbeddingProvider` protocol is the input shape that path
will reuse.
