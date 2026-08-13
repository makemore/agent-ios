import SwiftUI

/// Live scrolling waveform shown in place of the text field while
/// dictation is active.
///
/// Driven by a single normalised `level` (0...1) pushed in by the
/// composer's mic tap. Each time the level changes we append it to a
/// rolling history and shift the older samples left, which reads as the
/// waveform scrolling as the user speaks.
///
/// Deliberately dumb: no audio work happens here. The composer already
/// taps the input node for speech recognition, so it computes RMS from
/// the buffer it is receiving anyway and hands the result over. That
/// keeps a single tap on the input node — installing a second one
/// throws at runtime.
struct RecordingWaveformView: View {
    /// Latest normalised audio level, 0...1.
    let level: CGFloat
    let color: Color

    /// Number of bars drawn. Sized so the row still looks like a
    /// waveform rather than a bar chart on a narrow phone.
    private let barCount: Int = 28
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let minBarHeight: CGFloat = 3
    private let maxBarHeight: CGFloat = 24

    @State private var history: [CGFloat] = []

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: height(for: sample))
            }
        }
        .frame(height: maxBarHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.linear(duration: 0.08), value: history)
        .onChange(of: level) { newLevel in
            append(newLevel)
        }
        .accessibilityLabel("Recording")
    }

    /// History padded at the front so the bars fill from the right on
    /// the first few samples rather than stretching across the row.
    private var padded: [CGFloat] {
        if history.count >= barCount { return Array(history.suffix(barCount)) }
        return Array(repeating: 0, count: barCount - history.count) + history
    }

    private func append(_ sample: CGFloat) {
        history.append(max(0, min(1, sample)))
        if history.count > barCount {
            history.removeFirst(history.count - barCount)
        }
    }

    private func height(for sample: CGFloat) -> CGFloat {
        minBarHeight + (maxBarHeight - minBarHeight) * sample
    }
}
