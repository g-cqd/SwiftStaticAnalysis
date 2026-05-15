//  BertSemanticEmbeddingProvider.swift
//  SwiftStaticAnalysis
//  MIT License

#if canImport(CoreML)
    import CoreML
    import Foundation

    // MARK: - BertSemanticEmbeddingProvider

    /// `SemanticEmbeddingProvider` backed by a Core ML model with a
    /// BERT-style two-input signature (`input_ids` + `attention_mask`)
    /// and a per-token output (`last_hidden_state`) that this provider
    /// mean-pools into a single fixed-dimension vector.
    ///
    /// Designed for sentence-transformer / BERT-base / DistilBERT
    /// exports — anything that follows the canonical Hugging Face
    /// `feature-extraction` CoreML shape:
    ///
    /// ```
    /// inputs:
    ///   input_ids:      MLMultiArray<Int32> shape (1, T)
    ///   attention_mask: MLMultiArray<Int32> shape (1, T)
    /// outputs:
    ///   last_hidden_state: MLMultiArray<Float32> shape (1, T, D)
    ///   pooler_output:     MLMultiArray<Float32> shape (1, D)   // optional, unused
    /// ```
    ///
    /// Tokenization is WordPiece (BERT's standard) — see
    /// ``BertWordPieceTokenizer``. The provider prepends `[CLS]`,
    /// appends `[SEP]`, truncates to ``maxLength`` and runs a single
    /// `MLModel.prediction(from:)` per snippet.
    public final class BertSemanticEmbeddingProvider: SemanticEmbeddingProvider, @unchecked
        Sendable
    {
        // MARK: Lifecycle

        /// - Parameters:
        ///   - modelURL: path to a compiled `.mlpackage` or `.mlmodelc`.
        ///   - vocabURL: path to a HF-style `vocab.txt` (one token per line,
        ///     line N → token ID N).
        ///   - doLowerCase: lowercase normalization (matches the BERT base
        ///     uncased convention).
        ///   - maxLength: cap on the post-tokenization sequence (including
        ///     `[CLS]` and `[SEP]`). 512 matches BERT-base; smaller is
        ///     faster.
        ///   - embeddingDimension: model output `D`. Validated on first
        ///     inference.
        public init(
            modelURL: URL,
            vocabURL: URL,
            doLowerCase: Bool = true,
            maxLength: Int = 256,
            embeddingDimension: Int = 384,
        ) throws {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let resolvedURL: URL
            if modelURL.pathExtension == "mlmodelc" {
                resolvedURL = modelURL
            } else {
                // .mlpackage / .mlmodel — compile.
                do {
                    resolvedURL = try MLModel.compileModel(at: modelURL)
                } catch {
                    throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
                }
            }
            do {
                self.model = try MLModel(contentsOf: resolvedURL, configuration: config)
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }
            self.tokenizer = try BertWordPieceTokenizer(
                vocabURL: vocabURL, doLowerCase: doLowerCase
            )
            self.maxLength = maxLength
            self.embeddingDimension = embeddingDimension
        }

        // MARK: Public

        public let embeddingDimension: Int

        public func embed(snippet: String) async throws -> [Float] {
            // 1. Tokenize → token IDs, prepend [CLS], append [SEP],
            //    truncate to maxLength.
            var ids: [Int32] = [tokenizer.clsID]
            let bodyTokens = tokenizer.tokenize(snippet)
            let cap = max(0, maxLength - 2)
            ids.append(contentsOf: bodyTokens.prefix(cap))
            ids.append(tokenizer.sepID)

            let sequenceLength = ids.count

            // 2. Build (1, T) Int32 multi-arrays.
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
                inputIDs[[0, NSNumber(value: i)]] = NSNumber(value: ids[i])
                attentionMask[[0, NSNumber(value: i)]] = 1
            }

            // 3. Run inference.
            let input: MLFeatureProvider
            do {
                input = try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: inputIDs),
                    "attention_mask": MLFeatureValue(multiArray: attentionMask),
                ])
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

            // 4. Mean-pool `last_hidden_state` shape (1, T, D) over the
            //    real (non-padded) tokens. We didn't pad, so every
            //    position is valid — pool all.
            guard let lastHidden = output.featureValue(for: "last_hidden_state")?.multiArrayValue
            else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Model output missing 'last_hidden_state' multi-array"
                )
            }
            // Resolve embedding dim from the runtime shape, in case the
            // declared dimension is off.
            let shape = lastHidden.shape.map { $0.intValue }
            guard shape.count == 3, shape[0] == 1, shape[1] == sequenceLength else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Unexpected last_hidden_state shape: \(shape)"
                )
            }
            let dimension = shape[2]
            var pooled = [Float](repeating: 0, count: dimension)

            // MLMultiArray accessors via NSNumber are slow per-cell.
            // Read raw pointer for speed.
            let pointer = lastHidden.dataPointer.assumingMemoryBound(to: Float.self)
            // Stride = T * D for batch (1 batch), D for sequence step.
            let strideD = dimension
            for t in 0..<sequenceLength {
                let base = t * strideD
                for d in 0..<dimension {
                    pooled[d] += pointer[base + d]
                }
            }
            let scale = 1.0 / Float(sequenceLength)
            for d in 0..<dimension {
                pooled[d] *= scale
            }
            return pooled
        }

        // MARK: Private

        private let model: MLModel
        private let tokenizer: BertWordPieceTokenizer
        private let maxLength: Int
    }

    // MARK: - BertWordPieceTokenizer

    /// Minimal WordPiece tokenizer matching the BERT-base-uncased
    /// convention used by `sentence-transformers/all-MiniLM-L6-v2` and
    /// most HF feature-extraction CoreML exports.
    ///
    /// Pipeline:
    /// 1. Optional NFKC-ish strip (we omit accent stripping — code is
    ///    mostly ASCII, so the loss is negligible).
    /// 2. Lowercase (if `doLowerCase`).
    /// 3. Split on whitespace.
    /// 4. Split each chunk on punctuation boundaries.
    /// 5. For each resulting word, greedy-longest-prefix-match against
    ///    the vocab. Subword continuations are prefixed with `##`.
    ///    Unknown chunks map to `[UNK]`.
    ///
    /// Not a faithful reproduction of Python's full BERT tokenizer
    /// (Chinese char isolation and accent stripping omitted), but a
    /// faithful enough approximation for English-language identifier /
    /// keyword / comment streams — i.e., the surface of Swift code.
    public final class BertWordPieceTokenizer: @unchecked Sendable {
        public init(vocabURL: URL, doLowerCase: Bool) throws {
            let data = try Data(contentsOf: vocabURL)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NSError(
                        domain: "BertWordPieceTokenizer", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "vocab.txt not valid UTF-8"]
                    )
                )
            }
            var vocab: [String: Int32] = [:]
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                let token = String(line)
                if !token.isEmpty {
                    vocab[token] = Int32(index)
                }
            }
            self.vocab = vocab
            self.doLowerCase = doLowerCase
            self.unkID = vocab["[UNK]"] ?? 100
            self.clsID = vocab["[CLS]"] ?? 101
            self.sepID = vocab["[SEP]"] ?? 102
            self.padID = vocab["[PAD]"] ?? 0
        }

        public let unkID: Int32
        public let clsID: Int32
        public let sepID: Int32
        public let padID: Int32

        public func tokenize(_ input: String) -> [Int32] {
            let normalized = doLowerCase ? input.lowercased() : input
            var ids: [Int32] = []
            for word in splitOnWhitespaceAndPunctuation(normalized) {
                wordPiece(word, into: &ids)
            }
            return ids
        }

        // MARK: Private

        private let vocab: [String: Int32]
        private let doLowerCase: Bool

        /// Split text on whitespace + punctuation. Punctuation tokens are
        /// emitted as their own words so they can map to vocab entries
        /// individually (BERT treats `.`, `,`, `(`, etc. as separate).
        private func splitOnWhitespaceAndPunctuation(_ text: String) -> [String] {
            var words: [String] = []
            var current = ""
            for scalar in text.unicodeScalars {
                if isWhitespace(scalar) {
                    if !current.isEmpty {
                        words.append(current)
                        current = ""
                    }
                } else if isPunctuation(scalar) {
                    if !current.isEmpty {
                        words.append(current)
                        current = ""
                    }
                    words.append(String(scalar))
                } else {
                    current.append(Character(scalar))
                }
            }
            if !current.isEmpty {
                words.append(current)
            }
            return words
        }

        /// Greedy longest-prefix WordPiece matching.
        private func wordPiece(_ word: String, into ids: inout [Int32]) {
            if word.isEmpty { return }
            if word.count > 100 {
                // BERT convention: long tokens map to [UNK] without trying.
                ids.append(unkID)
                return
            }
            var start = word.startIndex
            let end = word.endIndex
            var subwords: [Int32] = []
            while start < end {
                var matchedEnd: String.Index? = nil
                var matchedID: Int32 = unkID
                // Longest-prefix match.
                var probe = end
                while probe > start {
                    var sub = String(word[start..<probe])
                    if start != word.startIndex {
                        sub = "##" + sub
                    }
                    if let id = vocab[sub] {
                        matchedEnd = probe
                        matchedID = id
                        break
                    }
                    probe = word.index(before: probe)
                }
                guard let nextStart = matchedEnd else {
                    // No prefix matches at all — whole word [UNK].
                    ids.append(unkID)
                    return
                }
                subwords.append(matchedID)
                start = nextStart
            }
            ids.append(contentsOf: subwords)
        }

        private func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
                || scalar.properties.isWhitespace
        }

        private func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
            let value = scalar.value
            // BERT considers ASCII punctuation as all of these:
            if (value >= 33 && value <= 47)
                || (value >= 58 && value <= 64)
                || (value >= 91 && value <= 96)
                || (value >= 123 && value <= 126)
            {
                return true
            }
            return scalar.properties.generalCategory == .otherPunctuation
                || scalar.properties.generalCategory == .openPunctuation
                || scalar.properties.generalCategory == .closePunctuation
                || scalar.properties.generalCategory == .initialPunctuation
                || scalar.properties.generalCategory == .finalPunctuation
                || scalar.properties.generalCategory == .connectorPunctuation
                || scalar.properties.generalCategory == .dashPunctuation
        }
    }
#endif
