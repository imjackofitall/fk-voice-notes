import AVFoundation

enum AudioLoaderError: LocalizedError {
    case noAudioTrack
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "No audio track in this file."
        case .unreadable(let reason): "Couldn't read the audio: \(reason)"
        }
    }
}

/// Decodes anything AVFoundation can open (wav, aiff, mp3, m4a, flac, caf, mov, mp4...)
/// straight to 16 kHz mono Float32, letting Core Audio do the downmix and resample.
enum AudioLoader {
    static func load(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioLoaderError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: WhistleEngine.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw AudioLoaderError.unreadable(reader.error?.localizedDescription ?? "unknown error")
        }

        var samples: [Float] = []
        if duration.isFinite, duration > 0 {
            samples.reserveCapacity(Int(duration * Double(WhistleEngine.sampleRate)) + 16_000)
        }
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        if reader.status == .failed {
            throw AudioLoaderError.unreadable(reader.error?.localizedDescription ?? "unknown error")
        }
        return samples
    }
}
