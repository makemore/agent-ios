import Foundation

/// Normalizes actual WebRTC stats; missing stats are zero, never inferred from
/// captions. Energy/duration is a measured RMS fallback when audioLevel is absent.
struct LiveVoiceAudioMeter {
    struct Sample {
        let id: String
        let type: String
        let values: [String: NSObject]
    }
    private struct Previous { let energy: Double?; let duration: Double?; let packets: Double? }
    private var previous: [String: Previous] = [:]

    mutating func levels(_ samples: [Sample]) -> (input: Double, output: Double) {
        var input = 0.0
        var output = 0.0
        var next: [String: Previous] = [:]
        for sample in samples {
            let values = sample.values
            guard (values["kind"] as? String ?? values["mediaType"] as? String) == "audio",
                  sample.type == "media-source" || sample.type == "inbound-rtp" else { continue }
            let energy = (values["totalAudioEnergy"] as? NSNumber)?.doubleValue
            let duration = (values["totalSamplesDuration"] as? NSNumber)?.doubleValue
            let packets = (values["packetsReceived"] as? NSNumber)?.doubleValue
            let prior = previous[sample.id]
            next[sample.id] = Previous(energy: energy, duration: duration, packets: packets)
            var level = (values["audioLevel"] as? NSNumber)?.doubleValue
            if let packets, let old = prior?.packets, packets <= old {
                level = 0
            } else if level == nil, let energy, let duration,
                      let oldEnergy = prior?.energy, let oldDuration = prior?.duration,
                      duration > oldDuration, energy >= oldEnergy {
                level = sqrt((energy - oldEnergy) / (duration - oldDuration))
            }
            let raw = level ?? 0
            let normalized = raw.isFinite ? max(0, min(1, raw)) : 0
            if sample.type == "media-source" { input = max(input, normalized) }
            else { output = max(output, normalized) }
        }
        previous = next
        return (input, output)
    }
}