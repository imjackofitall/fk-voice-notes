import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case md, txt, srt, vtt

    var id: String { rawValue }
    var label: String {
        switch self {
        case .md: "Notes + Transcript (Markdown)"
        case .txt: "Transcript (Plain Text)"
        case .srt: "SubRip Subtitles (.srt)"
        case .vtt: "WebVTT Subtitles (.vtt)"
        }
    }
}

enum Exporter {
    struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    static func render(_ job: Job, as format: ExportFormat) -> String {
        switch format {
        case .md:
            return markdown(job)
        case .txt:
            return job.text + "\n"
        case .srt:
            return cues(for: job).enumerated().map { index, cue in
                "\(index + 1)\n\(stamp(cue.start, ",")) --> \(stamp(cue.end, ","))\n\(cue.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + cues(for: job).map { cue in
                "\(stamp(cue.start, ".")) --> \(stamp(cue.end, "."))\n\(cue.text)\n"
            }.joined(separator: "\n")
        }
    }

    static func markdown(_ job: Job) -> String {
        var out = "# \(job.notes?.title ?? job.name)\n\n"
        if let notes = job.notes {
            out += "## Summary\n\n\(notes.summary)\n\n"
            if !notes.actions.isEmpty {
                out += "## Action points\n\n" + notes.actions.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n\n"
            }
        }
        return out + "## Transcript\n\n\(job.text)\n"
    }

    /// Groups word timings into readable cues: at most ~6 s or ~84 characters,
    /// breaking early at sentence ends and pauses.
    static func cues(for job: Job) -> [Cue] {
        var cues: [Cue] = []
        for segment in job.segments {
            guard !segment.words.isEmpty else {
                cues.append(Cue(start: segment.start, end: segment.end, text: segment.text))
                continue
            }
            var current: Cue?
            for word in segment.words {
                if var cue = current {
                    let pause = word.start - cue.end
                    let sentenceEnded = cue.text.last.map { ".?!".contains($0) } ?? false
                    let tooLong = word.end - cue.start > 6 || cue.text.count + word.text.count > 84
                    if pause > 1 || tooLong || (sentenceEnded && cue.end - cue.start > 1.5) {
                        cues.append(cue)
                        current = Cue(start: word.start, end: word.end, text: word.text)
                    } else {
                        cue.text += " " + word.text
                        cue.end = word.end
                        current = cue
                    }
                } else {
                    current = Cue(start: word.start, end: word.end, text: word.text)
                }
            }
            if let current { cues.append(current) }
        }
        return cues
    }

    private static func stamp(_ seconds: Double, _ separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }

    @MainActor
    static func save(_ job: Job, as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(job.name).\(format.rawValue)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.directoryURL = job.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try render(job, as: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @MainActor
    static func copy(_ job: Job) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(job.notes == nil ? job.text : markdown(job), forType: .string)
    }
}
