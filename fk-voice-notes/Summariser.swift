import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct MeetingNotes: Hashable {
    var title: String
    var summary: String
    var actions: [String]
}

enum SummaryError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

/// Title, summary and action points from Apple's on-device model (macOS 26+).
enum Summariser {
    static func summarise(_ transcript: String) async throws -> MeetingNotes {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return try await AppleSummariser.summarise(transcript)
        }
        #endif
        throw SummaryError.unavailable("Summaries need macOS 26 with Apple Intelligence turned on.")
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct GeneratedNotes {
    @Guide(description: "A short, specific title for the recording, 3 to 7 words. No date, no quotes, no trailing punctuation.")
    var title: String

    @Guide(description: "A summary of the whole recording in 2 to 4 sentences: what it is about and the key points, in your own words. Cover the beginning, middle and end. Never quote the transcript.")
    var summary: String

    @Guide(description: "Action points: tasks or follow-ups someone committed to or was asked to do. Each is one short imperative sentence, naming the owner if one is named. Empty when there are none.")
    var actionItems: [String]
}

@available(macOS 26, *)
enum AppleSummariser {
    /// The model has a 4,096-token context; ~6,000 characters of transcript leaves room for instructions and output.
    static let chunkSize = 6_000

    static let instructions = """
    You turn speech transcripts into brief notes for the person who recorded them. Write in Australian English. \
    Summarise the main topic and key points across the entire transcript, paraphrasing rather than quoting. \
    Only list action points that are actually stated or clearly requested in the transcript; never invent them. \
    If there are none, return an empty list. Transcripts come from speech recognition, so silently fix obvious mishearings.
    """

    static func summarise(_ transcript: String) async throws -> MeetingNotes {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            throw SummaryError.unavailable(describe(reason))
        }

        var text = transcript
        var prompt = "Transcript:\n"
        // Map-reduce until the material fits in one pass.
        while text.count > chunkSize {
            var partials: [String] = []
            for piece in chunks(of: text) {
                let notes = try await generate("Transcript excerpt:\n\(piece)")
                var line = "- \(notes.summary)"
                if !notes.actionItems.isEmpty { line += "\n  Actions: " + notes.actionItems.joined(separator: "; ") }
                partials.append(line)
            }
            text = partials.joined(separator: "\n")
            prompt = "Notes from consecutive parts of one recording. Write notes for the whole recording, merging duplicate action points:\n"
        }
        let notes = try await generate(prompt + text)
        return MeetingNotes(
            title: notes.title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: notes.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: notes.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )
    }

    private static func generate(_ prompt: String) async throws -> GeneratedNotes {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt, generating: GeneratedNotes.self,
                                         options: GenerationOptions(temperature: 0.2)).content
    }

    /// Splits at sentence ends so each piece stays under `chunkSize`.
    private static func chunks(of text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            if current.count + sentence.count > chunkSize, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += sentence
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to get summaries."
        case .deviceNotEligible: "This Mac can't run Apple's on-device model."
        case .modelNotReady: "Apple's on-device model is still downloading. Try again shortly."
        @unknown default: "Apple's on-device model isn't available."
        }
    }
}
#endif
