import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TranscriptionStore.self) private var store
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
        } detail: {
            ZStack {
                if let job = store.selectedJob {
                    DetailView(job: job)
                        .id(job.id)
                        .transition(.opacity)
                } else {
                    DropPrompt(targeted: dropTargeted)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: store.selection)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Language", selection: $store.language) {
                    ForEach(Language.allCases) { Text($0.label).tag($0) }
                }
                .help("Language for new transcriptions")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.showImporter = true } label: { Label("Open Audio", systemImage: "plus") }
                    .help("Open audio or video files (⌘O)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            withAnimation(.snappy(duration: 0.2)) { dropTargeted = targeted }
        }
        .overlay {
            if dropTargeted && store.selectedJob != nil {
                DropOverlay().transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .onPasteCommand(of: [.fileURL]) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in store.add([url]) } }
                }
            }
        }
        .fileImporter(isPresented: $store.showImporter, allowedContentTypes: [.audiovisualContent],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.add(urls) }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(TranscriptionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            ForEach(store.jobs.reversed()) { job in
                JobRow(job: job)
                    .tag(job.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .contextMenu {
                        if case .failed = job.status { Button("Retry") { store.retry(job) } }
                        if job.status == .done {
                            Button("Transcribe Again") { store.retry(job) }
                            Button("Summarise Again") { store.resummarise(job) }.disabled(job.segments.isEmpty)
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                        Divider()
                        Button("Remove from List") { store.remove([job.id]) }.disabled(job.isWorking)
                    }
            }
        }
        .onDeleteCommand { if let id = store.selection { store.remove([id]) } }
        .overlay {
            if store.jobs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2)
                    Text("Recordings you add appear here")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.tertiary)
                .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                EngineStatus()
                Toggle("Summarise and find action points", isOn: $store.summarise)
                Toggle("Rename file to date + title", isOn: $store.autoRename)
                    .disabled(!store.summarise)
                TextField("Keywords: names, jargon…", text: $store.keywords)
                    .textFieldStyle(.roundedBorder)
                    .help("Comma-separated words and phrases Whistle should favour")
            }
            .font(.callout)
            .padding(12)
        }
    }
}

private struct EngineStatus: View {
    @Environment(TranscriptionStore.self) private var store

    var body: some View {
        if let error = store.engineError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        } else if !store.engineReady {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading Whistle…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(job: job).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                Text(job.phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .animation(.smooth, value: job.title)
            .animation(.smooth, value: job.phase)
        }
        .padding(.vertical, 4)
    }
}

private struct StatusIcon: View {
    let job: Job

    var body: some View {
        ZStack {
            switch job.status {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .decoding:
                ProgressView().controlSize(.small)
            case .transcribing:
                ProgressRing(progress: job.progress)
            case .done where job.notesStatus == .working:
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.4), value: job.status)
        .animation(.smooth, value: job.notesStatus)
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.04, progress))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2)
        .animation(.smooth, value: progress)
    }
}

// MARK: - Empty state

private struct DropPrompt: View {
    @Environment(TranscriptionStore.self) private var store
    let targeted: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "waveform")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: targeted)
            VStack(spacing: 6) {
                Text(targeted ? "Drop to transcribe" : "Drop audio or video here")
                    .font(.title2.weight(.semibold))
                    .contentTransition(.opacity)
                Text("Transcribed, summarised and renamed on this Mac. Nothing leaves it.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Choose Files…") { store.showImporter = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("or paste with ⌘V").foregroundStyle(.tertiary)
            }
            Text("M4A · MP3 · WAV · AIFF · FLAC · CAF · MP4 · MOV")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(48)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: [8, 6]))
                .background(targeted ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 18))
        }
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: targeted)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
            Label("Drop to add", systemImage: "arrow.down.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}

// MARK: - Detail

private struct DetailView: View {
    let job: Job
    @State private var player = PlayerModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Header(job: job)
                        NotesSection(job: job)
                        TranscriptSection(job: job, player: player)
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: currentLine) { _, line in
                    guard player.autoScroll, player.isPlaying, let line else { return }
                    withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(line, anchor: .center) }
                }
            }
            if job.duration > 0 {
                Divider()
                PlayerBar(player: player, peaks: job.peaks)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: job.duration > 0)
        .navigationTitle(job.title)
        .toolbar {
            ToolbarItemGroup {
                Button { Exporter.copy(job) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy notes and transcript")
                    .disabled(job.segments.isEmpty)
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.label) { Exporter.save(job, as: format) }
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export notes, transcript or subtitles")
                    .disabled(job.status != .done || job.segments.isEmpty)
            }
        }
        .onAppear { if job.duration > 0 { player.load(job.url, duration: job.duration) } }
        .onChange(of: job.url) { _, url in player.load(url, duration: job.duration) }
        .onChange(of: job.duration) { _, duration in if duration > 0 { player.load(job.url, duration: duration) } }
        .onDisappear { player.stop() }
    }

    private var currentLine: Int? {
        job.lines.last(where: { $0.start <= player.time + 0.05 })?.id
    }
}

private struct Header: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.title)
                .font(.system(size: 28, weight: .bold))
                .textSelection(.enabled)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.4), value: job.title)
            FlowRow {
                Meta(icon: "calendar", text: job.recordedAt.formatted(date: .abbreviated, time: .shortened))
                if job.duration > 0 { Meta(icon: "clock", text: formatClock(job.duration)) }
                if !job.languages.isEmpty {
                    Meta(icon: "globe", text: job.languages.map { $0.uppercased() }.joined(separator: ", "))
                }
                if job.status == .done, job.elapsed > 0 {
                    Meta(icon: "bolt.fill", text: "\(formatElapsed(job.elapsed)) · \(String(format: "%.0f", job.speed))× realtime")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([job.url]) } label: {
                    Meta(icon: "doc", text: job.url.lastPathComponent)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
    }
}

private struct Meta: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentTransition(.opacity)
    }
}

private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Notes

private struct NotesSection: View {
    let job: Job

    var body: some View {
        Group {
            if let notes = job.notes {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(icon: "sparkles", title: "Summary") {
                            CopyButton(text: notes.summary)
                        }
                        Text(notes.summary)
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                    if !notes.actions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(icon: "checklist", title: "Action points") {
                                CopyButton(text: notes.actions.map { "- \($0)" }.joined(separator: "\n"))
                            }
                            ForEach(Array(notes.actions.enumerated()), id: \.offset) { index, action in
                                ActionRow(text: action, checked: job.checked.contains(index)) {
                                    withAnimation(.snappy) {
                                        if job.checked.contains(index) { job.checked.remove(index) } else { job.checked.insert(index) }
                                    }
                                }
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 10)))
            } else if job.notesStatus == .working {
                SummarySkeleton().transition(.opacity)
            }
            if case .failed(let message) = job.notesStatus {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.smooth(duration: 0.45), value: job.notesStatus)
    }
}

private struct SectionTitle<Accessory: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text(title).font(.headline)
            Spacer()
            accessory
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

private struct ActionRow: View {
    let text: String
    let checked: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.green : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 15))
                Text(text)
                    .font(.system(size: 15))
                    .strikethrough(checked, color: .secondary)
                    .foregroundStyle(checked ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SummarySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Writing summary…").font(.headline)
            }
            ForEach([1.0, 0.94, 0.97, 0.62], id: \.self) { width in
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(width: geometry.size.width * width)
                }
                .frame(height: 11)
            }
        }
        .shimmer()
    }
}

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.5)
                        .offset(x: phase * geometry.size.width * 1.5)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    fileprivate func shimmer() -> some View { modifier(Shimmer()) }
}

// MARK: - Transcript

private struct TranscriptSection: View {
    let job: Job
    let player: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(icon: "text.quote", title: "Transcript") {
                if !job.segments.isEmpty { CopyButton(text: job.text) }
            }
            if job.lines.isEmpty {
                placeholder.padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(job.lines) { line in
                        LineRow(line: line, active: line.id == activeLine) {
                            player.seek(to: line.start, play: true)
                        }
                        .id(line.id)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .animation(.smooth(duration: 0.35), value: job.lines.count)
            }
        }
    }

    private var activeLine: Int? {
        guard player.isPlaying || player.time > 0 else { return nil }
        return job.lines.last(where: { $0.start <= player.time + 0.05 })?.id
    }

    @ViewBuilder private var placeholder: some View {
        switch job.status {
        case .queued:
            Text("Waiting to start…").foregroundStyle(.secondary)
        case .decoding:
            Label("Reading audio…", systemImage: "waveform").foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .transcribing:
            Label("Transcribing…", systemImage: "waveform").foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .done:
            Text("No speech found.").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

private struct LineRow: View {
    let line: Line
    let active: Bool
    var seek: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button(action: seek) {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .opacity(hovering || active ? 1 : 0)
                    Text(formatClock(line.start)).monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 62, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Play from here")
            Text(line.text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(active ? Color.accentColor : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(active ? Color.accentColor.opacity(0.08) : hovering ? Color.secondary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: active)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
