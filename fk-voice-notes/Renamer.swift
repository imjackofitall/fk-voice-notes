import Foundation

/// Renames the source file to "yyyy-MM-dd Title.ext", dated by the file's creation date.
enum Renamer {
    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @MainActor
    static func rename(_ job: Job, title: String) throws {
        let clean = sanitise(title)
        guard !clean.isEmpty else { return }
        let source = job.url
        let date = (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        let directory = source.deletingLastPathComponent()
        let ext = source.pathExtension
        let base = "\(dateFormat.string(from: date)) \(clean)"

        var target = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while target.standardizedFileURL != source.standardizedFileURL,
              FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        guard target.standardizedFileURL != source.standardizedFileURL else { return }
        try FileManager.default.moveItem(at: source, to: target)
        job.url = target
    }

    static func sanitise(_ title: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
        let words = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: " .'‘’“”"))
        return String(trimmed.prefix(80)).trimmingCharacters(in: .whitespaces)
    }
}
