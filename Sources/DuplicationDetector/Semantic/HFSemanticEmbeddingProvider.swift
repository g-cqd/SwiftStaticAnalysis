//  HFSemanticEmbeddingProvider.swift
//  SwiftStaticAnalysis
//  MIT License

#if canImport(CoreML)
    import CoreML
    import Foundation
    import Tokenizers

    // MARK: - HFSemanticEmbeddingProvider

    /// `SemanticEmbeddingProvider` backed by a Core ML model + a
    /// HuggingFace `AutoTokenizer`, suitable for the standard HF
    /// feature-extraction shape used by **every** mainstream code
    /// embedder:
    ///
    /// - `microsoft/codebert-base`             (RoBERTa, 125M)
    /// - `microsoft/graphcodebert-base`        (RoBERTa + data-flow training)
    /// - `jinaai/jina-embeddings-v2-base-code` (BERT, code-trained, 8192 ctx)
    /// - `Salesforce/codet5p-110m-embedding`   (RoBERTa, T5+ embedding head)
    /// - `sentence-transformers/all-MiniLM-L6-v2` (BERT, English-NL baseline)
    ///
    /// Layout the provider expects on disk (`bundleDir`):
    ///
    /// ```
    /// <bundleDir>/
    ///   model.mlpackage            # or *.mlmodelc, or compiled on first use
    ///   tokenizer.json             # HuggingFace tokenizer.json (canonical)
    ///   tokenizer_config.json      # optional but recommended
    ///   special_tokens_map.json    # optional
    ///   ...                        # any other HF tokenizer-folder files
    /// ```
    ///
    /// Swift-side, `Tokenizers.AutoTokenizer.from(modelFolder:)` handles
    /// BPE/WordPiece/SentencePiece transparently, so a single provider
    /// type covers every model in the HF feature-extraction zoo.
    public final class HFSemanticEmbeddingProvider: SemanticEmbeddingProvider, @unchecked
        Sendable
    {
        // MARK: Lifecycle

        /// - Parameters:
        ///   - bundleDir: directory containing both the CoreML model
        ///     bundle (`.mlpackage` / `.mlmodelc`) and the HF tokenizer
        ///     folder (`tokenizer.json`, etc.). Either co-locate them or
        ///     pass `modelURL` explicitly to override.
        ///   - modelURL: explicit override for the model bundle path. If
        ///     `nil`, the provider picks the first `.mlmodelc` or
        ///     `.mlpackage` found in `bundleDir`.
        ///   - maxLength: cap on post-tokenization sequence length
        ///     (including special tokens). 256 is a good default for
        ///     short code snippets; jina-v2 supports up to 8192.
        ///   - inputIDsName: model input feature name for token IDs
        ///     (default `"input_ids"`).
        ///   - attentionMaskName: model input for attention mask
        ///     (default `"attention_mask"`).
        ///   - tokenTypeIDsName: optional third input (BERT-style
        ///     models that need it explicitly because lazy `new_ones`
        ///     creation breaks coremltools tracing). Pass `nil` to
        ///     skip; the provider only feeds this input if the model
        ///     declares it.
        ///   - positionIDsName: same as above for `position_ids`.
        ///   - lastHiddenStateName: model output for per-token vectors
        ///     (default `"last_hidden_state"` — mean-pooled here).
        public init(
            bundleDir: URL,
            modelURL: URL? = nil,
            maxLength: Int = 256,
            inputIDsName: String = "input_ids",
            attentionMaskName: String = "attention_mask",
            tokenTypeIDsName: String? = "token_type_ids",
            positionIDsName: String? = "position_ids",
            lastHiddenStateName: String = "last_hidden_state",
        ) async throws {
            // Resolve model path.
            let resolvedModelURL: URL
            if let modelURL {
                resolvedModelURL = modelURL
            } else if let found = HFSemanticEmbeddingProvider.findModel(in: bundleDir) {
                resolvedModelURL = found
            } else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NSError(
                        domain: "HFSemanticEmbeddingProvider",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No .mlpackage or .mlmodelc in \(bundleDir.path)"
                        ],
                    )
                )
            }

            // Compile if needed.
            let compiledURL: URL
            if resolvedModelURL.pathExtension == "mlmodelc" {
                compiledURL = resolvedModelURL
            } else {
                do {
                    compiledURL = try await MLModel.compileModel(at: resolvedModelURL)
                } catch {
                    throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
                }
            }

            let config = MLModelConfiguration()
            config.computeUnits = .all
            do {
                self.model = try MLModel(contentsOf: compiledURL, configuration: config)
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }

            // Load tokenizer from the bundle directory.
            do {
                self.tokenizer = try await AutoTokenizer.from(modelFolder: bundleDir)
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }

            self.maxLength = maxLength
            self.inputIDsName = inputIDsName
            self.attentionMaskName = attentionMaskName
            self.tokenTypeIDsName = tokenTypeIDsName
            self.positionIDsName = positionIDsName

            // Auto-resolve output name. Try the requested name first, then
            // common alternates (`hidden_states`, `output`), finally fall
            // back to the first declared multi-array output.
            let declaredOutputs = model.modelDescription.outputDescriptionsByName
            if declaredOutputs[lastHiddenStateName] != nil {
                self.lastHiddenStateName = lastHiddenStateName
            } else if declaredOutputs["hidden_states"] != nil {
                self.lastHiddenStateName = "hidden_states"
            } else if declaredOutputs["output"] != nil {
                self.lastHiddenStateName = "output"
            } else if let first = declaredOutputs.first(where: {
                $0.value.type == .multiArray
            }) {
                self.lastHiddenStateName = first.key
            } else {
                self.lastHiddenStateName = lastHiddenStateName
            }

            // Resolve which optional inputs the model actually accepts.
            let inputDescriptions = model.modelDescription.inputDescriptionsByName
            let declaredInputs = Set(inputDescriptions.keys)
            self.acceptsTokenTypeIDs = tokenTypeIDsName.flatMap { declaredInputs.contains($0) } ?? false
            self.acceptsPositionIDs = positionIDsName.flatMap { declaredInputs.contains($0) } ?? false

            // Detect fixed input shape. EmbeddingGemma and other fully-baked
            // exports declare `input_ids` as e.g. [1, 128] rather than the
            // dynamic [1, 1]. When fixed, every inference call must pad up
            // to that length; when dynamic (shape[1] <= 1 or unconstrained),
            // we use the snippet's actual token count.
            if let inputDesc = inputDescriptions[inputIDsName],
                let shape = inputDesc.multiArrayConstraint?.shape,
                shape.count == 2,
                shape[1].intValue > 1
            {
                self.fixedSequenceLength = shape[1].intValue
            } else {
                self.fixedSequenceLength = nil
            }

            // Resolve embedding dimension. Try, in order:
            // 1. HF `config.json` `hidden_size` in the bundle (canonical).
            // 2. The model spec's output shape (fails when shape is dynamic).
            // 3. Default fallback (768 — BERT-base).
            let configURL = bundleDir.appendingPathComponent("config.json")
            if let hiddenSize = HFSemanticEmbeddingProvider.readHiddenSize(from: configURL) {
                self.embeddingDimension = hiddenSize
            } else if let outputDesc = model.modelDescription.outputDescriptionsByName[
                lastHiddenStateName
            ],
                let shape = outputDesc.multiArrayConstraint?.shape,
                shape.count == 3, shape[2].intValue > 0
            {
                self.embeddingDimension = shape[2].intValue
            } else {
                self.embeddingDimension = HFSemanticEmbeddingProvider.defaultDimensionGuess
            }
        }

        // MARK: Public

        public let embeddingDimension: Int

        public func embed(snippet: String) async throws -> [Float] {
            // 1. Tokenize via HF AutoTokenizer (handles BPE/WordPiece/etc).
            //    The tokenizer appends model-specific special tokens
            //    (CLS/SEP for BERT, <s>/</s> for RoBERTa).
            var ids = tokenizer.encode(text: snippet)
            // Truncation policy. Fixed-shape models cap to their declared
            // sequence length; dynamic models cap to `maxLength`.
            let effectiveMax = fixedSequenceLength ?? maxLength
            if ids.count > effectiveMax {
                ids = Array(ids.prefix(effectiveMax))
            }
            let realTokenCount = ids.count
            guard realTokenCount > 0 else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Tokenizer produced an empty sequence"
                )
            }
            // Padded length is fixed when the model demands it, otherwise
            // matches the real token count.
            let sequenceLength = fixedSequenceLength ?? realTokenCount

            // 2. Build Int32 multi-arrays for every input the model needs.
            //    Pad to sequenceLength; attention_mask is 1 for real tokens,
            //    0 for padding.
            guard
                let inputIDs = try? MLMultiArray(
                    shape: [1, NSNumber(value: sequenceLength)], dataType: .int32
                ),
                let attentionMask = try? MLMultiArray(
                    shape: [1, NSNumber(value: sequenceLength)], dataType: .int32
                )
            else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Failed to allocate input MLMultiArrays"
                )
            }
            for i in 0..<sequenceLength {
                if i < realTokenCount {
                    inputIDs[[0, NSNumber(value: i)]] = NSNumber(value: Int32(ids[i]))
                    attentionMask[[0, NSNumber(value: i)]] = 1
                } else {
                    inputIDs[[0, NSNumber(value: i)]] = 0
                    attentionMask[[0, NSNumber(value: i)]] = 0
                }
            }

            var features: [String: MLFeatureValue] = [
                inputIDsName: MLFeatureValue(multiArray: inputIDs),
                attentionMaskName: MLFeatureValue(multiArray: attentionMask),
            ]
            if acceptsTokenTypeIDs, let name = tokenTypeIDsName {
                let tt = try? MLMultiArray(
                    shape: [1, NSNumber(value: sequenceLength)], dataType: .int32
                )
                if let tt {
                    for i in 0..<sequenceLength {
                        tt[[0, NSNumber(value: i)]] = 0
                    }
                    features[name] = MLFeatureValue(multiArray: tt)
                }
            }
            if acceptsPositionIDs, let name = positionIDsName {
                let pos = try? MLMultiArray(
                    shape: [1, NSNumber(value: sequenceLength)], dataType: .int32
                )
                if let pos {
                    for i in 0..<sequenceLength {
                        pos[[0, NSNumber(value: i)]] = NSNumber(value: Int32(i))
                    }
                    features[name] = MLFeatureValue(multiArray: pos)
                }
            }

            // 3. Inference.
            let input: MLFeatureProvider
            do {
                input = try MLDictionaryFeatureProvider(dictionary: features)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Failed to build feature provider: \(error.localizedDescription)"
                )
            }
            let output: MLFeatureProvider
            do {
                output = try await model.prediction(from: input)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: error.localizedDescription
                )
            }

            // 4. Pool the output. Two shapes are accepted:
            //    - (1, T, D) per-token  → mean-pool over T.
            //    - (1, D)    pre-pooled → use directly. EmbeddingGemma /
            //      sentence-transformer exports already do the pooling
            //      inside the model graph and emit a 2D tensor.
            guard let lastHidden = output.featureValue(for: lastHiddenStateName)?.multiArrayValue
            else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Model output missing '\(lastHiddenStateName)' multi-array"
                )
            }
            let shape = lastHidden.shape.map { $0.intValue }
            let pointer = lastHidden.dataPointer.assumingMemoryBound(to: Float.self)

            if shape.count == 2, shape[0] == 1, shape[1] > 0 {
                // Pre-pooled output: copy directly.
                let dimension = shape[1]
                var pooled = [Float](repeating: 0, count: dimension)
                for d in 0..<dimension {
                    pooled[d] = pointer[d]
                }
                return pooled
            }
            guard shape.count == 3, shape[0] == 1, shape[1] == sequenceLength else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason:
                        "Unexpected \(lastHiddenStateName) shape: \(shape) for seqLen=\(sequenceLength)"
                )
            }
            // Mean-pool over REAL tokens only (skip padding) so the pooled
            // vector reflects the snippet, not the pad zeros.
            let dimension = shape[2]
            var pooled = [Float](repeating: 0, count: dimension)
            for t in 0..<realTokenCount {
                let base = t * dimension
                for d in 0..<dimension {
                    pooled[d] += pointer[base + d]
                }
            }
            let scale = 1.0 / Float(realTokenCount)
            for d in 0..<dimension {
                pooled[d] *= scale
            }
            return pooled
        }

        /// Per-token output (L2-normalized, padding-stripped) for the
        /// snippet. Returns a `[realTokenCount × D]` matrix as `[[Float]]`,
        /// one row per real token.
        ///
        /// Used by `MaxSimVerifier` for late-interaction reranking
        /// (ColBERT-style) — addresses the limitation of pooled cosine
        /// where every-token-averaged similarity masks per-token
        /// alignment signal.
        ///
        /// Runs the same forward pass as `embed(snippet:)` but skips the
        /// mean-pool. Pre-pooled exports (EmbeddingGemma, some sentence-
        /// transformer variants) throw because they don't surface
        /// per-token hidden states.
        public func embedTokens(snippet: String) async throws -> [[Float]] {
            var ids = tokenizer.encode(text: snippet)
            let effectiveMax = fixedSequenceLength ?? maxLength
            if ids.count > effectiveMax {
                ids = Array(ids.prefix(effectiveMax))
            }
            let realTokenCount = ids.count
            guard realTokenCount > 0 else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Tokenizer produced an empty sequence"
                )
            }
            let sequenceLength = fixedSequenceLength ?? realTokenCount

            guard
                let inputIDs = try? MLMultiArray(
                    shape: [1, NSNumber(value: sequenceLength)], dataType: .int32
                ),
                let attentionMask = try? MLMultiArray(
                    shape: [1, NSNumber(value: sequenceLength)], dataType: .int32
                )
            else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Failed to allocate input MLMultiArrays"
                )
            }
            for i in 0..<sequenceLength {
                if i < realTokenCount {
                    inputIDs[[0, NSNumber(value: i)]] = NSNumber(value: Int32(ids[i]))
                    attentionMask[[0, NSNumber(value: i)]] = 1
                } else {
                    inputIDs[[0, NSNumber(value: i)]] = 0
                    attentionMask[[0, NSNumber(value: i)]] = 0
                }
            }

            var features: [String: MLFeatureValue] = [
                inputIDsName: MLFeatureValue(multiArray: inputIDs),
                attentionMaskName: MLFeatureValue(multiArray: attentionMask),
            ]
            if acceptsTokenTypeIDs, let name = tokenTypeIDsName {
                let tt = try? MLMultiArray(
                    shape: [1, NSNumber(value: sequenceLength)], dataType: .int32
                )
                if let tt {
                    for i in 0..<sequenceLength { tt[[0, NSNumber(value: i)]] = 0 }
                    features[name] = MLFeatureValue(multiArray: tt)
                }
            }
            if acceptsPositionIDs, let name = positionIDsName {
                let pos = try? MLMultiArray(
                    shape: [1, NSNumber(value: sequenceLength)], dataType: .int32
                )
                if let pos {
                    for i in 0..<sequenceLength {
                        pos[[0, NSNumber(value: i)]] = NSNumber(value: Int32(i))
                    }
                    features[name] = MLFeatureValue(multiArray: pos)
                }
            }

            let input = try MLDictionaryFeatureProvider(dictionary: features)
            let output = try await model.prediction(from: input)

            guard let lastHidden = output.featureValue(for: lastHiddenStateName)?.multiArrayValue
            else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Model output missing '\(lastHiddenStateName)' multi-array"
                )
            }
            let shape = lastHidden.shape.map { $0.intValue }
            guard shape.count == 3, shape[0] == 1, shape[1] == sequenceLength else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason:
                        "embedTokens requires per-token output (1, T, D); got \(shape). "
                        + "Pre-pooled exports (e.g. EmbeddingGemma) don't support late-interaction reranking."
                )
            }
            let pointer = lastHidden.dataPointer.assumingMemoryBound(to: Float.self)
            let dimension = shape[2]
            var tokens: [[Float]] = []
            tokens.reserveCapacity(realTokenCount)
            for t in 0..<realTokenCount {
                let base = t * dimension
                var row = [Float](repeating: 0, count: dimension)
                var sumSq: Float = 0
                for d in 0..<dimension {
                    let v = pointer[base + d]
                    row[d] = v
                    sumSq += v * v
                }
                // L2-normalize so downstream MaxSim is cosine = dot.
                if sumSq > 0 {
                    let inv = 1.0 / sumSq.squareRoot()
                    for d in 0..<dimension {
                        row[d] *= inv
                    }
                }
                tokens.append(row)
            }
            return tokens
        }

        // MARK: Private

        private let model: MLModel
        private let tokenizer: any Tokenizer
        private let maxLength: Int
        private let inputIDsName: String
        private let attentionMaskName: String
        private let tokenTypeIDsName: String?
        private let positionIDsName: String?
        private let lastHiddenStateName: String
        private let acceptsTokenTypeIDs: Bool
        private let acceptsPositionIDs: Bool
        private let fixedSequenceLength: Int?

        /// Probe for `.mlpackage` first, then `.mlmodelc`, anywhere in
        /// `dir` (one level deep).
        private static func findModel(in dir: URL) -> URL? {
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                )
            else { return nil }
            for url in contents where url.pathExtension == "mlpackage" {
                return url
            }
            for url in contents where url.pathExtension == "mlmodelc" {
                return url
            }
            return nil
        }

        private static let defaultDimensionGuess = 768

        /// Read `hidden_size` from a HF `config.json` next to the model.
        private static func readHiddenSize(from configURL: URL) -> Int? {
            guard let data = try? Data(contentsOf: configURL),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            if let hidden = json["hidden_size"] as? Int { return hidden }
            if let hidden = json["d_model"] as? Int { return hidden }  // T5-family
            return nil
        }
    }
#endif
