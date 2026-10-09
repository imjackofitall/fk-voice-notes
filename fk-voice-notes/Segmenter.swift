import Accelerate

/// Whistle takes at most 30 s per pass. Long audio is cut into windows of
/// `minSeconds...maxSeconds`, each cut placed at the quietest point in that
/// range so words aren't split across passes.
enum Segmenter {
    static func split(_ samples: [Float], minSeconds: Double = 18, maxSeconds: Double = 28) -> [Range<Int>] {
        let rate = WhistleEngine.sampleRate
        let maxLength = Int(maxSeconds * Double(rate))
        guard samples.count > maxLength else { return samples.isEmpty ? [] : [0..<samples.count] }

        // Energy per 10 ms frame, then a prefix sum so any window's energy is O(1).
        let frame = rate / 100
        let frameCount = samples.count / frame
        var energy = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { audio in
            for i in 0..<frameCount {
                vDSP_measqv(audio.baseAddress! + i * frame, 1, &energy[i], vDSP_Length(frame))
            }
        }
        var prefix = [Float](repeating: 0, count: frameCount + 1)
        for i in 0..<frameCount { prefix[i + 1] = prefix[i] + energy[i] }

        let half = 15 // 300 ms smoothing window
        func quietness(_ i: Int) -> Float {
            prefix[min(frameCount, i + half)] - prefix[max(0, i - half)]
        }

        let minFrames = Int(minSeconds * 100)
        let maxFrames = Int(maxSeconds * 100)
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLength {
            let first = start / frame + minFrames
            let last = min(frameCount - 1, start / frame + maxFrames)
            var best = last
            var bestEnergy = Float.greatestFiniteMagnitude
            for i in first...last {
                let value = quietness(i)
                if value < bestEnergy { bestEnergy = value; best = i }
            }
            let cut = best * frame
            ranges.append(start..<cut)
            start = cut
        }
        if samples.count - start > rate / 10 { ranges.append(start..<samples.count) }
        return ranges
    }
}
