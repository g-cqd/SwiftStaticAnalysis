//  CoreMLSemanticEmbeddingProvider.swift
//  SwiftStaticAnalysis
//  MIT License

#if canImport(CoreML)
    import CoreML
    import Foundation

    // MARK: - CoreMLSemanticEmbeddingProvider

    /// `SemanticEmbeddingProvider` backed by a user-supplied Core ML
    /// model. Wraps the standard Apple `MLModel` inference pipeline:
    /// tokenise the source snippet (caller-supplied closure),
    /// pack the IDs into an `MLMultiArray`, run inference, extract the
    /// pooled-output vector.
    ///
    /// ## Bring-your-own-model
    ///
    /// No model bundle ships with SwiftStaticAnalysis. To use this
    /// provider end-to-end, a downstream consumer must:
    ///
    /// 1. Convert a code-embedding model (CodeBERT, GraphCodeBERT,
    ///    CodeT5, a Swift-fine-tuned variant) to Core ML via
    ///    `coremltools` — see
    ///    https://developer.apple.com/documentation/coreml/converting-pytorch-models-to-core-ml
    ///    for the conversion recipe.
    /// 2. Supply a tokenizer closure that matches the model's training
    ///    vocabulary. The tokenizer maps a Swift `String` to a
    ///    `[Int]` of token IDs and reports the model's context window
    ///    (max sequence length) via the closure's input cap.
    /// 3. Instantiate with `init(modelURL:tokenizer:embeddingDimension:
    ///    contextWindow:inputName:outputName:)`.
    ///
    /// The provider compiles the model on first use (via
    /// `MLModel.compileModel(at:)`) and caches the compiled model URL
    /// for subsequent runs. Inference happens on the Neural Engine when
    /// the model and host both support it (Apple Silicon).
    ///
    /// ## Expected model shape
    ///
    /// Input: `MLMultiArray<Int32>` of shape `[1, contextWindow]`
    /// containing token IDs (zero-padded to `contextWindow`).
    /// Output: `MLMultiArray<Float32>` of shape `[1, embeddingDimension]`
    /// — typically the model's `[CLS]` token embedding or a mean-pooled
    /// representation. Models that differ from this shape need a
    /// wrapper Core ML pipeline before being passed here.
    public final class CoreMLSemanticEmbeddingProvider: SemanticEmbeddingProvider {
        /// Closure that converts a Swift `String` into a sequence of
        /// model-vocabulary token IDs. The caller is responsible for any
        /// special-token handling (`[CLS]`, `[SEP]`, etc.) and for
        /// truncating to the model's context window.
        public typealias Tokenizer = @Sendable (String) throws -> [Int32]

        /// Create a provider rooted at a Core ML model file.
        ///
        /// - Parameters:
        ///   - modelURL: URL to either an `.mlmodel` source bundle (which
        ///     will be compiled on first use) or a pre-compiled
        ///     `.mlmodelc` directory.
        ///   - tokenizer: Closure mapping `String` → `[Int32]` token IDs.
        ///   - embeddingDimension: Length of the model's embedding
        ///     vector. The output `MLMultiArray` must match this.
        ///   - contextWindow: Maximum token-sequence length the model
        ///     accepts. The provider zero-pads / refuses inputs that
        ///     exceed it.
        ///   - inputName: Name of the model's input port (typically
        ///     `"input_ids"`). Defaults to `"input_ids"` matching the
        ///     CodeBERT family.
        ///   - outputName: Name of the model's output port. Defaults to
        ///     `"pooler_output"` matching CodeBERT/RoBERTa.
        public init(
            modelURL: URL,
            tokenizer: @escaping Tokenizer,
            embeddingDimension: Int,
            contextWindow: Int,
            inputName: String = "input_ids",
            outputName: String = "pooler_output",
        ) {
            self.modelURL = modelURL
            self.tokenize = tokenizer
            self.embeddingDimension = embeddingDimension
            self.contextWindow = contextWindow
            self.inputName = inputName
            self.outputName = outputName
        }

        public let embeddingDimension: Int

        public func embed(snippet: String) async throws -> [Float] {
            let model = try loadModel()
            let tokens = try tokenize(snippet)
            guard tokens.count <= contextWindow else {
                throw SemanticEmbeddingError.snippetTooLong(
                    actual: tokens.count, limit: contextWindow,
                )
            }
            let input = try makeInputArray(from: tokens)
            let prediction: MLFeatureProvider
            do {
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    inputName: MLFeatureValue(multiArray: input)
                ])
                prediction = try await model.prediction(from: provider)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(reason: error.localizedDescription)
            }
            guard let outputValue = prediction.featureValue(for: outputName),
                let outputArray = outputValue.multiArrayValue
            else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Model output '\(outputName)' is missing or not an MLMultiArray",
                )
            }
            return try makeEmbeddingVector(from: outputArray)
        }

        // MARK: - Private

        private let modelURL: URL
        private let tokenize: Tokenizer
        private let contextWindow: Int
        private let inputName: String
        private let outputName: String

        /// Compiled-model cache. Populated on first `embed(snippet:)` call.
        /// Apple's `MLModel` is `Sendable`-safe once initialised; we serialise
        /// the compile step itself with a lock so concurrent first-callers
        /// don't recompile.
        private let compiledModelStorage = ModelStorage()

        private final class ModelStorage: @unchecked Sendable {
            private let lock = NSLock()
            private var model: MLModel?

            func get(or load: () throws -> MLModel) throws -> MLModel {
                lock.lock()
                defer { lock.unlock() }
                if let cached = model {
                    return cached
                }
                let loaded = try load()
                model = loaded
                return loaded
            }
        }

        private func loadModel() throws -> MLModel {
            try compiledModelStorage.get {
                let compiledURL: URL
                if modelURL.pathExtension == "mlmodelc" {
                    compiledURL = modelURL
                } else {
                    do {
                        compiledURL = try MLModel.compileModel(at: modelURL)
                    } catch {
                        throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
                    }
                }
                do {
                    return try MLModel(contentsOf: compiledURL)
                } catch {
                    throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
                }
            }
        }

        private func makeInputArray(from tokens: [Int32]) throws -> MLMultiArray {
            let array: MLMultiArray
            do {
                array = try MLMultiArray(
                    shape: [1, NSNumber(value: contextWindow)],
                    dataType: .int32,
                )
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(reason: error.localizedDescription)
            }
            // Zero-pad: MLMultiArray buffers initialise unspecified; an
            // explicit fill is the safe default.
            for index in 0..<contextWindow {
                array[index] = NSNumber(value: index < tokens.count ? tokens[index] : 0)
            }
            return array
        }

        private func makeEmbeddingVector(from output: MLMultiArray) throws -> [Float] {
            let count = output.count
            guard count == embeddingDimension else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "Model produced \(count) values; expected \(embeddingDimension)",
                )
            }
            var vector = [Float](repeating: 0, count: count)
            for index in 0..<count {
                vector[index] = output[index].floatValue
            }
            return vector
        }
    }

#endif  // canImport(CoreML)
