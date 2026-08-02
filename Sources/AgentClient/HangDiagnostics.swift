import Foundation

/// Main-thread hang detection with a breadcrumb trail.
///
/// A watchdog that only reports *that* the UI stalled isn't much use — you
/// still have to guess what was running. This keeps a rolling marker of the
/// last thing the main thread started, so when the stall is detected the log
/// names the phase and how long it had been running.
///
/// This is a cheap stand-in for a real stack capture. When you need the
/// exact frames, use Instruments' Time Profiler (the Hangs track) — it can
/// symbolicate the blocked main thread, which a watchdog inside the process
/// cannot do safely.
///
/// TEMPORARILY unconditional (not #if DEBUG): the app uses custom build
/// configuration names (Debug-Local etc.), and the SPM package can end up
/// compiled as release under them, silently stripping gated diagnostics.
/// Strip this file before the PR.
public enum HangDiagnostics {

    /// Threshold above which a stalled runloop is reported.
    private static let reportThresholdMs: Double = 300
    /// How often the watchdog checks in.
    private static let pollInterval: TimeInterval = 0.25
    /// A single frame's budget is ~16ms; anything above this is a visible
    /// stutter and worth naming.
    private static let slowWorkThresholdMs: Double = 50

    private static let lock = NSLock()
    private static var currentActivity = "idle"
    private static var activityStarted = CFAbsoluteTimeGetCurrent()
    private static var started = false

    /// Record what the main thread is about to do.
    ///
    /// Deliberately coarse — a handful of call sites around the expensive
    /// phases. Marking too finely costs more than it reveals.
    public static func mark(_ activity: @autoclosure () -> String) {
        let label = activity()
        lock.lock()
        currentActivity = label
        activityStarted = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Time a synchronous block and report it if it runs long.
    ///
    /// This is the part that actually attributes a freeze. The watchdog can
    /// only say "the main thread stopped and the last thing it started was
    /// X"; if X never finished, or the real cost is somewhere with no
    /// breadcrumb, that's misleading. Timing the work directly says
    /// "this took 340ms" with no inference.
    @discardableResult
    public static func measure<T>(_ label: @autoclosure () -> String,
                                  _ work: () -> T) -> T {
        let name = label()
        mark(name)
        let start = CFAbsoluteTimeGetCurrent()
        let result = work()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if ms > slowWorkThresholdMs {
            print(String(format: "[Hang] 🐢 %@ took %.0fms", name, ms))
        }
        return result
    }

    /// Begin watching. Safe to call repeatedly; only the first call starts
    /// the timer.
    public static func start() {
        lock.lock()
        let alreadyRunning = started
        started = true
        lock.unlock()
        guard !alreadyRunning else { return }

        print("[Hang] watchdog installed (v2 — reports DURING the stall)")

        let queue = DispatchQueue(label: "hang-diagnostics", qos: .utility)

        // Heartbeat design: the main thread stamps `lastBeat` every poll
        // interval; the background queue checks the stamp's age and does the
        // REPORTING itself. The v1 watchdog printed from the main queue,
        // which meant it could only report a freeze after the main thread
        // recovered — useless mid-hang, and silent if the app was killed
        // while frozen. Printing from the background thread works while the
        // main thread is wedged, and escalates as the stall drags on.
        let beatLock = NSLock()
        var lastBeat = CFAbsoluteTimeGetCurrent()
        var lastReportedMs: Double = 0

        // Main side: stamp the heartbeat.
        func beat() {
            DispatchQueue.main.async {
                beatLock.lock()
                lastBeat = CFAbsoluteTimeGetCurrent()
                beatLock.unlock()
                queue.asyncAfter(deadline: .now() + pollInterval) { beat() }
            }
        }
        beat()

        // Background side: check staleness and report. Re-reports roughly
        // once a second while the same stall continues, so a long freeze
        // shows up as an escalating series rather than one line you might
        // miss.
        func check() {
            beatLock.lock()
            let ageMs = (CFAbsoluteTimeGetCurrent() - lastBeat) * 1000
            beatLock.unlock()
            if ageMs > reportThresholdMs, ageMs - lastReportedMs > 1000 {
                lastReportedMs = ageMs
                lock.lock()
                let activity = currentActivity
                let heldFor = (CFAbsoluteTimeGetCurrent() - activityStarted) * 1000
                lock.unlock()
                print(String(
                    format: "[Hang] ⚠️ main thread UNRESPONSIVE for %.0fms — last activity: %@ (started %.0fms ago)",
                    ageMs, activity, heldFor
                ))
            } else if ageMs < reportThresholdMs {
                lastReportedMs = 0
            }
            queue.asyncAfter(deadline: .now() + pollInterval) { check() }
        }
        queue.async { check() }
    }
}
