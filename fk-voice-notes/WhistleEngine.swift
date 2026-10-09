import Foundation

struct WhistleWord: Decodable, Hashable {
    let word: String
    let start: Double
    let end: Double
    let probability: Double?
}

struct WhistleResult: Decodable {
    let text: String
    let language: String?
    let ttft_ms: Double?
    let decode_tps: Double?
    let words: [WhistleWord]?
}

enum EngineError: LocalizedError {
    case missingWeights
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .missingWeights: "whistle.cact isn't in the app bundle. Run setup.sh and rebuild."
        case .engine(let message): message
        }
    }
}

/// Owns the single Whistle model. The engine isn't thread-safe, so every call
/// goes through one serial queue.
final class WhistleEngine: @unchecked Sendable {
    static let shared = WhistleEngine()
    static let sampleRate = 16_000

    private let queue = DispatchQueue(label: "whistle.engine", qos: .userInitiated)
    private var weights: Data?
    private var buffer = [CChar](repeating: 0, count: 1 << 18)

    func load() async throws {
        try await onQueue {
            guard self.weights == nil else { return }
            guard let url = Bundle.main.url(forResource: "whistle", withExtension: "cact") else {
                throw EngineError.missingWeights
            }
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            let code = data.withUnsafeBytes { raw in
                needle_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt64(raw.count))
            }
            if code < 0 { throw EngineError.engine(Self.lastError()) }
            self.weights = data
        }
    }

    func transcribe(_ samples: [Float], language: String?, keywords: String?) async throws -> WhistleResult {
        try await onQueue {
            let code = samples.withUnsafeBufferPointer { audio in
                withOptionalCString(language) { lang in
                    withOptionalCString(keywords) { words in
                        self.buffer.withUnsafeMutableBufferPointer { out in
                            out[0] = 0
                            return needle_transcribe(audio.baseAddress, Int32(audio.count), lang, words, 1,
                                                     out.baseAddress, Int32(out.count))
                        }
                    }
                }
            }
            if code < 0 { throw EngineError.engine(Self.lastError()) }
            let json = self.buffer.withUnsafeBufferPointer { Data(bytes: $0.baseAddress!, count: strlen($0.baseAddress!)) }
            return try JSONDecoder().decode(WhistleResult.self, from: json)
        }
    }

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func lastError() -> String {
        guard let message = needle_last_error() else { return "Whistle engine error" }
        return String(cString: message)
    }
}

private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string, !string.isEmpty else { return body(nil) }
    return string.withCString { body($0) }
}
