import Accelerate
import AVFoundation
import SwiftUI

/// Playback for the selected recording, driving transcript highlighting.
@MainActor
@Observable
final class PlayerModel {
    var time: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var rate: Float = 1
    var autoScroll = true

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func load(_ url: URL, duration: Double) {
        guard url != self.url else { return }
        let resume = time
        stop()
        self.url = url
        self.duration = duration
        let player = AVPlayer(url: url)
        self.player = player
        if resume > 0 { seek(to: resume) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.time = time.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.seek(to: 0)
            }
        }
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        url = nil
        isPlaying = false
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.playImmediately(atRate: rate)
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double, play: Bool = false) {
        let target = min(max(0, seconds), max(duration, 0))
        time = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play, !isPlaying { toggle() }
    }

    func skip(_ delta: Double) { seek(to: time + delta) }

    func cycleRate() {
        let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
        rate = rates[((rates.firstIndex(of: rate) ?? 0) + 1) % rates.count]
        if isPlaying { player?.rate = rate }
    }
}

enum Waveform {
    /// Peak amplitude per bin, normalised to 0...1, for drawing.
    static func peaks(_ samples: [Float], bins: Int = 360) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let size = max(1, samples.count / bins)
        var peaks = [Float](repeating: 0, count: bins)
        samples.withUnsafeBufferPointer { audio in
            for bin in 0..<bins {
                let start = bin * size
                guard start < audio.count else { break }
                let count = min(size, audio.count - start)
                vDSP_maxmgv(audio.baseAddress! + start, 1, &peaks[bin], vDSP_Length(count))
            }
        }
        let top = max(peaks.max() ?? 1, 0.0001)
        return peaks.map { pow($0 / top, 0.7) }
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let progress: Double
    var onSeek: (Double) -> Void

    @State private var hover: Double?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let step = size.width / CGFloat(peaks.count)
                let bar = max(1, step * 0.55)
                for (index, peak) in peaks.enumerated() {
                    let x = CGFloat(index) * step
                    let height = max(2, CGFloat(peak) * size.height)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height)
                    let fraction = Double(index) / Double(peaks.count)
                    let color: Color = fraction < progress ? .accentColor
                        : (hover.map { fraction < $0 } ?? false) ? .accentColor.opacity(0.45) : .secondary.opacity(0.35)
                    context.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeek(min(max(0, value.location.x / geometry.size.width), 1))
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = min(max(0, point.x / geometry.size.width), 1)
                case .ended: hover = nil
                }
            }
        }
        .animation(.linear(duration: 0.05), value: progress)
    }
}

struct PlayerBar: View {
    @Bindable var player: PlayerModel
    let peaks: [Float]

    var body: some View {
        HStack(spacing: 14) {
            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .buttonStyle(.borderless)
                .help("Back 10 seconds")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [.option])
            .help("Play or pause (⌥Space)")
            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }
                .buttonStyle(.borderless)
                .help("Forward 10 seconds")

            Text(formatClock(player.time))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            WaveformView(peaks: peaks, progress: player.duration > 0 ? player.time / player.duration : 0) { fraction in
                player.seek(to: fraction * player.duration)
            }
            .frame(height: 30)
            Text(formatClock(player.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Button { player.cycleRate() } label: {
                Text(player.rate == 1 ? "1×" : String(format: "%g×", player.rate))
                    .font(.callout.monospacedDigit().weight(.medium))
                    .frame(minWidth: 36)
            }
            .buttonStyle(.borderless)
            .help("Playback speed")
            Toggle(isOn: $player.autoScroll) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Follow along in the transcript")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
