import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum Language: String, CaseIterable, Identifiable {
    case auto, en, de, fr, es, it, nl, pl

    var id: String { rawValue }
    var code: String? { self == .auto ? nil : rawValue }
    var label: String {
        switch self {
        case .auto: "Detect language"
        case .en: "English"
        case .de: "German"
        case .fr: "French"
        case .es: "Spanish"
        case .it: "Italian"
        case .nl: "Dutch"
        case .pl: "Polish"
        }
    }
}

struct TimedWord: Hashable {
    let text: String
    let start: Double
    let end: Double
}

/// A sentence-sized run of words: the unit the transcript highlights and seeks by.
struct Line: Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    let text: String

    static func build(from segment: Segment, firstID: Int) -> [Line] {
        guard !segment.words.isEmpty else {
            return [Line(id: firstID, start: segment.start, end: segment.end, text: segment.text)]
        }
        var lines: [Line] = []
        var words: [TimedWord] = []
        func flush() {
            guard let first = words.first, let last = words.last else { return }
            lines.append(Line(id: firstID + lines.count, start: first.start, end: last.end,
                              text: words.map(\.text).joined(separator: " ")))
            words = []
        }
        for word in segment.words {
            if let last = words.last, word.start - last.end > 1.5 { flush() }
            words.append(word)
            let length = word.end - (words.first?.start ?? word.end)
            let sentenceEnd = word.text.last.map { ".?!".contains($0) } ?? false
            if (sentenceEnd && length > 4) || length > 14 { flush() }
        }
        flush()
        return lines
    }
}

struct Segment: Identifiable, Hashable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
    let language: String?
    let words: [TimedWord]
}

@Observable
final class Job: Identifiable {
    enum Status: Equatable {
        case queued, decoding, transcribing, done
        case failed(String)
    }

    enum NotesStatus: Equatable {
        case none, working, done
        case failed(String)
    }

    let id = UUID()
    var url: URL
    var status: Status = .queued
    var notesStatus: NotesStatus = .none
    var notes: MeetingNotes?
    var progress: Double = 0
    var duration: Double = 0
    var elapsed: Double = 0
    var segments: [Segment] = []
    var lines: [Line] = []
    var peaks: [Float] = []
    var checked: Set<Int> = []
    let addedAt = Date()

    init(url: URL) { self.url = url }

    var title: String { notes?.title ?? name }
    var recordedAt: Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? addedAt
    }

    /// One line of status for the sidebar, phase by phase.
    var phase: String {
        switch status {
        case .queued: return "Waiting"
        case .decoding: return "Reading audio…"
        case .transcribing: return "Transcribing · \(Int(progress * 100))%"
        case .failed(let message): return message
        case .done:
            if notesStatus == .working { return "Summarising…" }
            var parts = [formatClock(duration)]
            if let notes, !notes.actions.isEmpty {
                parts.append(notes.actions.count == 1 ? "1 action point" : "\(notes.actions.count) action points")
            } else if segments.isEmpty {
                parts.append("no speech")
            }
            return parts.joined(separator: " · ")
        }
    }

    var name: String { url.deletingPathExtension().lastPathComponent }
    var text: String { segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    var isWorking: Bool { status == .decoding || status == .transcribing }
    var languages: [String] {
        var seen: [String] = []
        for case let language? in segments.map(\.language) where !seen.contains(language) { seen.append(language) }
        return seen
    }
    var speed: Double { elapsed > 0 ? duration / elapsed : 0 }
}

@MainActor
@Observable
final class TranscriptionStore {
    var jobs: [Job] = []
    var selection: Job.ID?
    var language: Language = .auto
    var keywords = ""
    var engineReady = false
    var engineError: String?
    var showImporter = false
    var summarise: Bool = UserDefaults.standard.object(forKey: "summarise") as? Bool ?? true {
        didSet { UserDefaults.standard.set(summarise, forKey: "summarise") }
    }
    var autoRename: Bool = UserDefaults.standard.object(forKey: "autoRename") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRename, forKey: "autoRename") }
    }

    @ObservationIgnored private var running = false

    init() {
        Task { await loadEngine() }
    }

    var selectedJob: Job? { jobs.first { $0.id == selection } }

    func loadEngine() async {
        do {
            try await WhistleEngine.shared.load()
            engineReady = true
            pump()
        } catch {
            engineError = error.localizedDescription
        }
    }

    func add(_ urls: [URL]) {
        let files = urls.flatMap(Self.expand)
        guard !files.isEmpty else { return }
        let new = files.map(Job.init)
        withAnimation(.snappy) { jobs.append(contentsOf: new) }
        selection = new.first?.id
        pump()
    }

    func remove(_ ids: Set<Job.ID>) {
        withAnimation(.snappy) { jobs.removeAll { ids.contains($0.id) && !$0.isWorking } }
        if let selection, !jobs.contains(where: { $0.id == selection }) { self.selection = jobs.last?.id }
    }

    func retry(_ job: Job) {
        job.status = .queued
        job.segments = []
        job.lines = []
        job.checked = []
        job.notes = nil
        job.notesStatus = .none
        job.progress = 0
        pump()
    }

    func resummarise(_ job: Job) {
        Task { await makeNotes(for: job) }
    }

    /// Title, summary and action points from the on-device model, then the file rename.
    private func makeNotes(for job: Job) async {
        let transcript = job.text
        guard !transcript.isEmpty else { return }
        job.notesStatus = .working
        do {
            let notes = try await Summariser.summarise(transcript)
            withAnimation(.smooth(duration: 0.45)) {
                job.checked = []
                job.notes = notes
                job.notesStatus = .done
            }
            if autoRename { try Renamer.rename(job, title: notes.title) }
        } catch {
            job.notesStatus = .failed(error.localizedDescription)
        }
    }

    private func pump() {
        guard engineReady, !running, let job = jobs.first(where: { $0.status == .queued }) else { return }
        running = true
        Task {
            await run(job)
            running = false
            pump()
        }
    }

    private func run(_ job: Job) async {
        let clock = ContinuousClock()
        let started = clock.now
        let language = self.language.code
        let keywords = self.keywords
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        job.status = .decoding
        job.segments = []
        job.lines = []
        do {
            let samples = try await AudioLoader.load(url: job.url)
            let rate = Double(WhistleEngine.sampleRate)
            job.duration = Double(samples.count) / rate
            job.peaks = Waveform.peaks(samples)
            let ranges = Segmenter.split(samples)
            job.status = .transcribing

            for (index, range) in ranges.enumerated() {
                let offset = Double(range.lowerBound) / rate
                let result = try await WhistleEngine.shared.transcribe(Array(samples[range]), language: language,
                                                                       keywords: keywords)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let words = (result.words ?? []).compactMap { word -> TimedWord? in
                        let token = word.word.trimmingCharacters(in: .whitespaces)
                        return token.isEmpty ? nil : TimedWord(text: token, start: offset + word.start, end: offset + word.end)
                    }
                    let segment = Segment(start: offset, end: Double(range.upperBound) / rate, text: text,
                                          language: result.language, words: words)
                    job.segments.append(segment)
                    job.lines += Line.build(from: segment, firstID: job.lines.count)
                }
                job.progress = Double(index + 1) / Double(ranges.count)
                job.elapsed = (clock.now - started).seconds
            }
            job.elapsed = (clock.now - started).seconds
            job.status = .done
            if summarise { await makeNotes(for: job) }
        } catch {
            job.status = .failed(error.localizedDescription)
        }
    }

    private static func expand(_ url: URL) -> [URL] {
        guard url.isFileURL else { return [] }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return isMedia(url) ? [url] : [] }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                   options: [.skipsHiddenFiles])
        return (items?.allObjects as? [URL] ?? []).filter(isMedia).sorted { $0.path < $1.path }
    }

    private static func isMedia(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent)
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}

func formatClock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = total / 60 % 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func formatElapsed(_ seconds: Double) -> String {
    seconds < 10 ? String(format: "%.2f s", seconds) : formatClock(seconds)
}
