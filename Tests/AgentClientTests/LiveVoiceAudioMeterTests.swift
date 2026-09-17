import XCTest
@testable import AgentClient

final class LiveVoiceAudioMeterTests: XCTestCase {
    func testAudioLevelSeparatesInputAndOutputAndIgnoresNonAudio() {
        var meter = LiveVoiceAudioMeter()
        let result = meter.levels([
            .init(id: "mic", type: "media-source", values: ["kind": "audio" as NSString, "audioLevel": 0.3 as NSNumber]),
            .init(id: "speaker", type: "inbound-rtp", values: ["kind": "audio" as NSString, "audioLevel": 0.7 as NSNumber]),
            .init(id: "video", type: "inbound-rtp", values: ["kind": "video" as NSString, "audioLevel": 1 as NSNumber])
        ])
        XCTAssertEqual(result.input, 0.3)
        XCTAssertEqual(result.output, 0.7)
        XCTAssertEqual(meter.levels([]).output, 0)
    }

    func testEnergyFallbackUsesMeasuredDeltasAndNoPacketsMeansNoSpeech() {
        var meter = LiveVoiceAudioMeter()
        func sample(_ energy: Double, _ duration: Double, _ packets: Int) -> LiveVoiceAudioMeter.Sample {
            .init(id: "speaker", type: "inbound-rtp", values: ["kind": "audio" as NSString,
                "totalAudioEnergy": energy as NSNumber, "totalSamplesDuration": duration as NSNumber,
                "packetsReceived": packets as NSNumber])
        }
        XCTAssertEqual(meter.levels([sample(1, 1, 10)]).output, 0)
        XCTAssertEqual(meter.levels([sample(1.25, 2, 20)]).output, 0.5, accuracy: 0.0001)
        XCTAssertEqual(meter.levels([sample(1.25, 2, 20)]).output, 0)
    }

    func testStaleInboundLevelAndNonfiniteValuesAreZero() {
        var meter = LiveVoiceAudioMeter()
        let sample = LiveVoiceAudioMeter.Sample(id: "speaker", type: "inbound-rtp",
            values: ["kind": "audio" as NSString, "audioLevel": 0.8 as NSNumber, "packetsReceived": 10 as NSNumber])
        XCTAssertEqual(meter.levels([sample]).output, 0.8)
        XCTAssertEqual(meter.levels([sample]).output, 0)
        let invalid = LiveVoiceAudioMeter.Sample(id: "mic", type: "media-source",
            values: ["kind": "audio" as NSString, "audioLevel": Double.nan as NSNumber])
        XCTAssertEqual(meter.levels([invalid]).input, 0)
    }
}