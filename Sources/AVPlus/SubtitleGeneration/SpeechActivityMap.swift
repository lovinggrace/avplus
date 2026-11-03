import Foundation
import Synchronization

/// A loudness envelope (10 ms frames, dBFS) of the audio fed to the transcriber.
///
/// `SpeechTranscriber` reports accurate word timings inside a result, but the first word of a
/// result absorbs the silence before it (e.g. "Welcome" spanning 0.84–2.34 s when speech starts at
/// 1.9 s). The envelope lets cue starts snap to where the voice actually begins. Ends are left
/// alone; a cue lingering briefly is harmless.
final class SpeechActivityMap: Sendable {
    static let frameDuration: TimeInterval = 0.01

    private let levels = Mutex<[Float]>([])
    private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    private var samplesPerFrame: Int { max(1, Int(sampleRate * Self.frameDuration)) }

    /// Records the loudness of `samples`, which start at `startSample` on the media timeline.
    func append(_ samples: [Float], startSample: Int64) {
        let frameSize = samplesPerFrame
        var frames: [(index: Int, level: Float)] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + frameSize, samples.count)
            var energy: Float = 0
            for index in offset..<end { energy += samples[index] * samples[index] }
            let rms = (energy / Float(end - offset)).squareRoot()
            frames.append((Int((startSample + Int64(offset)) / Int64(frameSize)), 20 * log10(max(rms, 1e-6))))
            offset = end
        }
        levels.withLock { levels in
            for (index, level) in frames {
                if index >= levels.count {
                    levels.append(contentsOf: repeatElement(-120, count: index - levels.count + 1))
                }
                levels[index] = level
            }
        }
    }

    /// The first time in `start...end` that is clearly louder than the surrounding noise floor.
    func firstActiveTime(from start: TimeInterval, to end: TimeInterval) -> TimeInterval? {
        let first = max(0, Int(start / Self.frameDuration))
        let last = Int(end / Self.frameDuration)
        return levels.withLock { levels -> TimeInterval? in
            guard first < levels.count, first <= last else { return nil }
            // Local floor: the quietest tenth of the surrounding two seconds.
            let windowStart = max(0, first - 200)
            let window = levels[windowStart...min(levels.count - 1, last)].sorted()
            let floor = window[window.count / 10]
            let threshold = max(-50, floor + 15)
            for index in first...min(last, levels.count - 1) where levels[index] > threshold {
                return Double(index) * Self.frameDuration
            }
            return nil
        }
    }

    /// Moves segment starts forward to the voice onset inside each segment.
    func refine(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { segment in
            guard let start = segment.start, let end = segment.end, end > start,
                  let onset = firstActiveTime(from: start, to: end)
            else { return segment }
            var refined = segment
            // A little lead-in so the cue appears just before the first syllable.
            refined.start = min(max(start, onset - 0.05), end)
            return refined
        }
    }
}
