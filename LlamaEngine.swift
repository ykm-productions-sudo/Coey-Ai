import Foundation
import llama

struct ChatTurn {
    let role: String
    let content: String
}

struct GenerationOptions {
    var temperature: Float = 0.8
    var topP: Float = 0.95
    var topK: Int32 = 40
    var repeatPenalty: Float = 1.1
    var maxTokens: Int = 256
}

enum LlamaEngineError: LocalizedError {
    case modelNotLoaded
    case tokenizeFailed
    case contextFailed
    case decodeFailed
    case emptyPrompt

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "The weights are not loaded yet."
        case .tokenizeFailed: return "The prompt could not be tokenized."
        case .contextFailed: return "llama.cpp could not open a context."
        case .decodeFailed: return "llama.cpp stopped while reading the prompt."
        case .emptyPrompt: return "The prompt is empty."
        }
    }
}

/// Serial llama.cpp runner. The model stays resident; a fresh context is
/// created for every turn so the KV cache always matches the prompt.
final class LlamaEngine {

    static let shared = LlamaEngine()

    private let queue = DispatchQueue(label: "ai.coey.llama", qos: .userInitiated)
    private let stateLock = NSLock()

    private var model: OpaquePointer?
    private var loadedPath: String?
    private var backendReady = false
    private var cancelled = false

    private var preferredContext = 2048
    private var preferredThreads = 4
    private var preferredBatch = 128

    private init() {}

    // MARK: - Loading

    var isLoaded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return model != nil
    }

    func load(
        path: String,
        nCtx: Int,
        nThreads: Int,
        nBatch: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            if self.model != nil, self.loadedPath == path {
                completion(.success(()))
                return
            }

            self.unloadLocked()
            self.preferredContext = max(512, min(4096, nCtx))
            self.preferredThreads = max(1, min(8, nThreads))
            self.preferredBatch = max(32, min(512, nBatch))

            if !self.backendReady {
                llama_backend_init()
                self.backendReady = true
            }

            var params = llama_model_default_params()
#if targetEnvironment(simulator)
            params.n_gpu_layers = 0
#else
            params.n_gpu_layers = -1
#endif

            guard let loaded = llama_model_load_from_file(path, params) else {
                completion(.failure(
                    NSError(
                        domain: "CoeyLlama",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "The weights could not be opened. They may be incomplete."]
                    )
                ))
                return
            }

            self.model = loaded
            self.loadedPath = path
            completion(.success(()))
        }
    }

    func unload() {
        queue.async {
            self.unloadLocked()
        }
    }

    private func unloadLocked() {
        if let model {
            llama_model_free(model)
        }
        model = nil
        loadedPath = nil
    }

    // MARK: - Generation

    func abort() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
    }

    private func beginTurn() {
        stateLock.lock()
        cancelled = false
        stateLock.unlock()
    }

    private func isCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    func generate(
        messages: [ChatTurn],
        options: GenerationOptions,
        onToken: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            do {
                try self.generateLocked(
                    messages: messages,
                    options: options,
                    onToken: onToken
                )
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func generateLocked(
        messages: [ChatTurn],
        options: GenerationOptions,
        onToken: @escaping (String) -> Void
    ) throws {
        guard let model else { throw LlamaEngineError.modelNotLoaded }
        guard let vocab = llama_model_get_vocab(model) else {
            throw LlamaEngineError.modelNotLoaded
        }

        beginTurn()

        let maxTokens = max(1, min(options.maxTokens, 1024))
        let requestedCtx = preferredContext

        // Build the prompt, dropping the oldest turns if it will not fit.
        var turns = messages
        var prompt = applyTemplate(turns, model: model)
        var tokens = tokenize(prompt, vocab: vocab)

        var guardCount = 0
        while tokens.count + maxTokens + 8 > requestedCtx,
              turns.count > 1,
              guardCount < 64 {
            if turns.first?.role == "system", turns.count > 2 {
                turns.remove(at: 1)
            } else {
                turns.removeFirst()
            }
            prompt = applyTemplate(turns, model: model)
            tokens = tokenize(prompt, vocab: vocab)
            guardCount += 1
        }

        guard !tokens.isEmpty else { throw LlamaEngineError.emptyPrompt }

        let contextSize = min(
            4096,
            max(512, tokens.count + maxTokens + 8)
        )

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = UInt32(max(32, min(512, preferredBatch)))
        contextParams.n_threads = Int32(preferredThreads)
        contextParams.n_threads_batch = contextParams.n_threads

        guard let context = llama_init_from_model(model, contextParams) else {
            throw LlamaEngineError.contextFailed
        }
        defer { llama_free(context) }

        // Prefill in batches.
        let batchSize = Int(contextParams.n_batch)
        var index = 0
        while index < tokens.count {
            if isCancelled() { return }
            let count = min(batchSize, tokens.count - index)
            var batch = llama_batch_init(Int32(count), 0, 1)
            batch.n_tokens = 0

            for offset in 0..<count {
                let slot = Int(batch.n_tokens)
                batch.token?[slot] = tokens[index + offset]
                batch.pos?[slot] = Int32(index + offset)
                batch.n_seq_id?[slot] = 1
                batch.seq_id?[slot]?[0] = 0
                batch.logits?[slot] = (offset == count - 1) ? 1 : 0
                batch.n_tokens += 1
            }

            let status = llama_decode(context, batch)
            llama_batch_free(batch)
            if status != 0 { throw LlamaEngineError.decodeFailed }
            index += count
        }

        // Sampler chain.
        let samplerParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(samplerParams) else {
            throw LlamaEngineError.contextFailed
        }
        defer { llama_sampler_free(chain) }

        let penalty = max(1.0, min(2.0, options.repeatPenalty))
        llama_sampler_chain_add(
            chain,
            llama_sampler_init_penalties(
                llama_vocab_n_tokens(vocab),
                64,
                penalty,
                0.0,
                0.0
            )
        )
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(max(1, options.topK)))
        llama_sampler_chain_add(
            chain,
            llama_sampler_init_top_p(max(0.01, min(1.0, options.topP)), 1)
        )
        llama_sampler_chain_add(
            chain,
            llama_sampler_init_temp(max(0.01, min(2.0, options.temperature)))
        )
        llama_sampler_chain_add(
            chain,
            llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max))
        )

        var decoder = Utf8Stream()
        var generated = 0

        while generated < maxTokens {
            if isCancelled() { break }

            let token = llama_sampler_sample(chain, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            llama_sampler_accept(chain, token)

            if let piece = decoder.push(pieceBytes(for: token, vocab: vocab)),
               !piece.isEmpty {
                onToken(piece)
            }
            generated += 1

            var next = token
            let batch = llama_batch_get_one(&next, 1)
            if llama_decode(context, batch) != 0 { break }
        }
    }

    // MARK: - Prompt helpers

    private func applyTemplate(_ messages: [ChatTurn], model: OpaquePointer) -> String {
        guard !messages.isEmpty else { return "" }

        let template = llama_model_chat_template(model, nil)

        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer {
            for pointer in roles { if let pointer { free(pointer) } }
            for pointer in contents { if let pointer { free(pointer) } }
        }

        var chat: [llama_chat_message] = []
        for index in 0..<messages.count {
            guard let role = roles[index], let content = contents[index] else { continue }
            chat.append(
                llama_chat_message(
                    role: UnsafePointer(role),
                    content: UnsafePointer(content)
                )
            )
        }

        var capacity = 1024
        for message in messages {
            capacity += message.content.utf8.count * 2 + 64
        }

        for _ in 0..<5 {
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
            defer { buffer.deallocate() }

            let written = chat.withUnsafeBufferPointer { pointer -> Int32 in
                llama_chat_apply_template(
                    template,
                    pointer.baseAddress,
                    chat.count,
                    true,
                    buffer,
                    Int32(capacity)
                )
            }

            if written > 0, Int(written) <= capacity {
                let data = Data(bytes: buffer, count: Int(written))
                return String(decoding: data, as: UTF8.self)
            }
            if written <= 0 { break }
            capacity = Int(written) + 64
        }

        return fallbackChatML(messages)
    }

    private func fallbackChatML(_ messages: [ChatTurn]) -> String {
        var prompt = ""
        for message in messages {
            prompt += "<|im_start|>\(message.role)\n\(message.content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) -> [llama_token] {
        let byteCount = text.utf8.count
        guard byteCount > 0 else { return [] }

        var capacity = byteCount + 16
        for _ in 0..<4 {
            var tokens = [llama_token](repeating: 0, count: capacity)
            let written = llama_tokenize(
                vocab,
                text,
                Int32(byteCount),
                &tokens,
                Int32(capacity),
                false,
                true
            )
            if written >= 0 {
                return Array(tokens.prefix(Int(written)))
            }
            capacity = Int(-written) + 16
        }
        return []
    }

    private func pieceBytes(for token: llama_token, vocab: OpaquePointer) -> [UInt8]? {
        var capacity = 128
        for _ in 0..<3 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let written = llama_token_to_piece(
                vocab,
                token,
                &buffer,
                Int32(capacity),
                0,
                false
            )
            if written > 0, Int(written) <= capacity {
                return buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
            }
            if written == 0 { return nil }
            capacity = abs(Int(written)) + 8
        }
        return nil
    }

    // MARK: - Incremental UTF-8

    private struct Utf8Stream {
        private var pending: [UInt8] = []

        mutating func push(_ bytes: [UInt8]?) -> String? {
            guard let bytes, !bytes.isEmpty else { return nil }
            pending.append(contentsOf: bytes)

            var output: [UInt8] = []
            var index = 0

            while index < pending.count {
                let lead = pending[index]
                let length: Int
                switch lead {
                case 0x00..<0x80: length = 1
                case 0xC0..<0xE0: length = 2
                case 0xE0..<0xF0: length = 3
                case 0xF0..<0xF8: length = 4
                default:
                    index += 1
                    continue
                }

                guard index + length <= pending.count else { break }
                let slice = Array(pending[index..<(index + length)])
                if String(bytes: slice, encoding: .utf8) != nil {
                    output.append(contentsOf: slice)
                    index += length
                } else {
                    index += 1
                }
            }

            if index > 0 {
                pending.removeFirst(index)
            }
            guard !output.isEmpty else { return nil }
            return String(decoding: output, as: UTF8.self)
        }
    }
}
