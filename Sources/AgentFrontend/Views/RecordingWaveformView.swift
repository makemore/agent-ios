import SwiftUI

/// Live scrolling waveform shown in place of the text field while
/// dictation is active.
///
/// Driven by a single normalised `level` (0...1) pushed in by the
/// composer's mic tap. Each time the level changes we append it to a
/// rolling history and shift the older samples left, which reads as the
/// waveform scrolling as the user speaks.
///
/// Fills whatever width it is given: the bar count is derived from the
/// available width, so the waveform spans the whole field slot rather
/// than occupying a fixed strip at the leading edge.
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

    /// Height of the waveform row. Also used by the composer to clamp the
    /// hidden text field while dictating, so the two agree by
    /// construction — a field left free to grow would push the composer
    /// taller as the transcript arrives, even at zero opacity.
    static let preferredHeight: CGFloat = 24

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let minBarHeight: CGFloat = 3
    private var maxBarHeight: CGFloat { Self.preferredHeight }

    /// Upper bound on retained samples. Generously above any plausible
    /// on-screen bar count (an iPad-width composer is ~150 bars); the
    /// visible window is always the suffix sized to the current width.
    private let historyCap: Int = 400

    @State private var history: [CGFloat] = []

    var body: some View {
        GeometryReader { geo in
            let barCount = max(1, Int((geo.size.width + barSpacing) / (barWidth + barSpacing)))
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: height(for: sample(at: index, of: barCount)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: maxBarHeight)
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.08), value: history)
        .onChange(of: level) { newLevel in
            append(newLevel)
        }
        .accessibilityLabel("Recording")
    }

    /// Sample for bar `index` in a window of `count` bars: the most
    /// recent samples fill from the right, zero-padded at the front until
    /// enough history has accumulated.
    private func sample(at index: Int, of count: Int) -> CGFloat {
        let padding = max(0, count - history.count)
        guard index >= padding else { return 0 }
        let historyIndex = max(0, history.count - count) + (index - padding)
        return history[historyIndex]
    }

    private func append(_ sample: CGFloat) {
        history.append(max(0, min(1, sample)))
        if history.count > historyCap {
            history.removeFirst(history.count - historyCap)
        }
    }

    private func height(for sample: CGFloat) -> CGFloat {
        minBarHeight + (maxBarHeight - minBarHeight) * sample
    }
}
