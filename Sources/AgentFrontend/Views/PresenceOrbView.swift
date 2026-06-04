import SwiftUI

/// A breathing, swirling sphere that signals agent presence. Recreates the
/// `clients/agent_presence_orb.svg` source in native SwiftUI so the
/// gradient bands can react to ``isSpeaking`` without bundling a SMIL
/// renderer (WKWebView).
///
/// Layout: the orb is anchored inside a square frame of side ``baseSize``.
/// In the default (hero) mode the orb scales up and centres when
/// ``isSpeaking`` is true, and drifts smaller when idle so the chat
/// content reads as the primary focus. In ``compact`` mode the silhouette
/// stays at a fixed size (suitable for use as a per-message avatar) and
/// the speaking signal is delivered as a soft outer halo that fades in.
public struct PresenceOrbView: View {
    /// Drives the speaking vs idle resting state. The transition is
    /// animated via `.animation(.easeInOut, value:)` so callers can flip
    /// the flag without wrapping each change in `withAnimation`.
    public let isSpeaking: Bool

    /// Pixel size of the orb container at rest. In hero mode the orb
    /// scales relative to this value (idle ≈ 0.62×, speaking ≈ 1.15×);
    /// in compact mode the orb fills the frame at 1.0× so the surrounding
    /// layout reserves a stable hit area.
    public let baseSize: CGFloat

    /// When `true`, the orb renders at a fixed 1.0× scale (no idle /
    /// speaking jiggle) and signals speaking via a soft halo rather
    /// than a size change. Intended for use as a per-message avatar
    /// where movement would feel busy in the scrollback. Default
    /// `false` to preserve existing hero-orb behaviour.
    public let compact: Bool

    public init(isSpeaking: Bool, baseSize: CGFloat = 64, compact: Bool = false) {
        self.isSpeaking = isSpeaking
        self.baseSize = baseSize
        self.compact = compact
    }

    public var body: some View {
        // Inner TimelineView drives the continuous gradient / rotation
        // animation. State-driven scale lives on the *outer* view so
        // SwiftUI's implicit animation tracks a stable identity (the
        // TimelineView rebuilds 30×/s, which would otherwise eat the
        // transition).
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
            orb(at: ctx.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: baseSize, height: baseSize)
        .scaleEffect(scale, anchor: .center)
        .background(speakingHalo)
        .animation(.easeInOut(duration: 0.55), value: isSpeaking)
        .accessibilityLabel(isSpeaking ? "Agent speaking" : "Agent idle")
    }

    /// Compact mode pins to 1.0 so the avatar silhouette never moves;
    /// hero mode keeps the original idle/speaking scale swap.
    private var scale: CGFloat {
        if compact { return 1.0 }
        return isSpeaking ? 1.15 : 0.62
    }

    /// Soft lavender halo that bleeds outside the silhouette when the
    /// agent is speaking in compact mode. Stationary (no scale change)
    /// so it reads as a glow rather than a pulse; the implicit
    /// `.animation` on `isSpeaking` cross-fades the opacity. Hero-mode
    /// callers don't need this because the silhouette itself grows.
    @ViewBuilder
    private var speakingHalo: some View {
        if compact {
            Circle()
                .fill(Color(red: 0.498, green: 0.467, blue: 0.867).opacity(isSpeaking ? 0.45 : 0))
                .frame(width: baseSize * 1.55, height: baseSize * 1.55)
                .blur(radius: baseSize * 0.18)
        }
    }

    /// Single composited frame, parameterised by elapsed time `t` seconds.
    /// The geometry mirrors the source SVG's 240×240 orb region (core
    /// radius 120 in a 680×420 canvas) normalised to ``baseSize``.
    private func orb(at t: TimeInterval) -> some View {
        ZStack {
            // 1) Outer breathing halo — the soft purple glow that sits
            //    just outside the core. SVG: r 155→168 over 4s, opacity
            //    0.7→1.0. We map onto baseSize so the halo can extend
            //    past the core circle.
            let haloPhase = breathe(t, period: 4.0)
            Circle()
                .fill(haloGradient)
                .frame(
                    width: baseSize * (1.0 + 0.05 * haloPhase),
                    height: baseSize * (1.0 + 0.05 * haloPhase)
                )
                .opacity(0.7 + 0.3 * (0.5 + 0.5 * haloPhase))
                .blur(radius: baseSize * 0.04)

            // 2) Core sphere — lavender→deep-purple radial gradient
            //    breathing at 3.2s.
            let corePhase = breathe(t, period: 3.2)
            Circle()
                .fill(coreGradient)
                .frame(
                    width: baseSize * 0.75 * (1.0 + 0.025 * corePhase),
                    height: baseSize * 0.75 * (1.0 + 0.025 * corePhase)
                )

            // 3) Swirling colour bands clipped to the core circle so
            //    they paint the surface rather than spill outside.
            ZStack {
                swirl(t: t, gradient: swirl1Gradient, rxBase: 1.0, ryBase: 0.4,
                      ryAmp: 0.16, ryPeriod: 5.0, rotateFrom: 0, rotateDur: 9.0,
                      opacity: 0.9)
                swirl(t: t, gradient: swirl2Gradient, rxBase: 0.97, ryBase: 0.36,
                      rxAmp: 0.08, rxPeriod: 6.0, rotateFrom: 120, rotateDur: -11.0,
                      opacity: 0.85)
                swirl(t: t, gradient: swirl1Gradient, rxBase: 0.93, ryBase: 0.28,
                      ryAmp: 0.15, ryPeriod: 7.0, rotateFrom: 220, rotateDur: 13.0,
                      opacity: 0.7)
                bloom(t: t)
            }
            .frame(width: baseSize * 0.75, height: baseSize * 0.75)
            .clipShape(Circle())

            // 4) Thin lavender rim — keeps the silhouette crisp even
            //    when the swirls fade toward the edge.
            Circle()
                .stroke(Color(red: 0.686, green: 0.663, blue: 0.925).opacity(0.4),
                        lineWidth: max(0.5, baseSize * 0.006))
                .frame(width: baseSize * 0.75, height: baseSize * 0.75)
        }
    }

    // MARK: - Swirl primitives

    private func swirl(t: TimeInterval, gradient: RadialGradient,
                       rxBase: CGFloat, ryBase: CGFloat,
                       rxAmp: CGFloat = 0, rxPeriod: TimeInterval = 0,
                       ryAmp: CGFloat = 0, ryPeriod: TimeInterval = 0,
                       rotateFrom: Double, rotateDur: TimeInterval,
                       opacity: Double) -> some View {
        let rxScale = rxBase + (rxPeriod > 0 ? rxAmp * CGFloat(breathe(t, period: rxPeriod)) : 0)
        let ryScale = ryBase + (ryPeriod > 0 ? ryAmp * CGFloat(breathe(t, period: ryPeriod)) : 0)
        let angle = rotateFrom + (rotateDur == 0 ? 0 : (t / rotateDur) * 360.0)
        return Ellipse()
            .fill(gradient)
            .frame(width: baseSize * rxScale, height: baseSize * ryScale)
            .rotationEffect(.degrees(angle))
            .opacity(opacity)
    }

    private func bloom(t: TimeInterval) -> some View {
        // Orange-pink bloom drifts off-centre to mimic specular hot-spot.
        let cx = sin(t * 2 * .pi / 6.0) * baseSize * 0.06
        let cy = cos(t * 2 * .pi / 5.5) * baseSize * 0.06
        let rPhase = breathe(t, period: 4.5)
        let size = baseSize * 0.62 + CGFloat(rPhase) * baseSize * 0.08
        return Ellipse()
            .fill(bloomGradient)
            .frame(width: size, height: size)
            .offset(x: cx, y: cy)
    }

    /// Returns a value in [-1, 1] that sweeps smoothly with the given period.
    private func breathe(_ t: TimeInterval, period: TimeInterval) -> Double {
        sin(t * 2 * .pi / period)
    }

    // MARK: - Gradients (mirror the SVG `<radialGradient>` stops)

    private var coreGradient: RadialGradient {
        RadialGradient(gradient: Gradient(stops: [
            .init(color: Color(red: 0.686, green: 0.663, blue: 0.925), location: 0.0),
            .init(color: Color(red: 0.498, green: 0.467, blue: 0.867), location: 0.45),
            .init(color: Color(red: 0.325, green: 0.290, blue: 0.718), location: 0.85),
            .init(color: Color(red: 0.235, green: 0.204, blue: 0.537), location: 1.0),
        ]), center: .center, startRadius: 0, endRadius: baseSize * 0.4)
    }

    private var bloomGradient: RadialGradient {
        RadialGradient(gradient: Gradient(stops: [
            .init(color: Color(red: 0.941, green: 0.600, blue: 0.482).opacity(0.85), location: 0.0),
            .init(color: Color(red: 0.831, green: 0.325, blue: 0.494).opacity(0.35), location: 0.6),
            .init(color: Color(red: 0.831, green: 0.325, blue: 0.494).opacity(0.0), location: 1.0),
        ]), center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: baseSize * 0.32)
    }

    private var swirl1Gradient: RadialGradient {
        RadialGradient(gradient: Gradient(stops: [
            .init(color: Color(red: 0.365, green: 0.792, blue: 0.647).opacity(0.0), location: 0.0),
            .init(color: Color(red: 0.365, green: 0.792, blue: 0.647).opacity(0.55), location: 0.55),
            .init(color: Color(red: 0.114, green: 0.620, blue: 0.459).opacity(0.0), location: 1.0),
        ]), center: .center, startRadius: 0, endRadius: baseSize * 0.5)
    }

    private var swirl2Gradient: RadialGradient {
        RadialGradient(gradient: Gradient(stops: [
            .init(color: Color(red: 0.522, green: 0.718, blue: 0.922).opacity(0.0), location: 0.0),
            .init(color: Color(red: 0.216, green: 0.541, blue: 0.867).opacity(0.5), location: 0.5),
            .init(color: Color(red: 0.094, green: 0.373, blue: 0.647).opacity(0.0), location: 1.0),
        ]), center: .center, startRadius: 0, endRadius: baseSize * 0.5)
    }

    private var haloGradient: RadialGradient {
        RadialGradient(gradient: Gradient(stops: [
            .init(color: Color(red: 0.498, green: 0.467, blue: 0.867).opacity(0.0), location: 0.70),
            .init(color: Color(red: 0.498, green: 0.467, blue: 0.867).opacity(0.18), location: 0.88),
            .init(color: Color(red: 0.498, green: 0.467, blue: 0.867).opacity(0.0), location: 1.0),
        ]), center: .center, startRadius: 0, endRadius: baseSize * 0.5)
    }
}
