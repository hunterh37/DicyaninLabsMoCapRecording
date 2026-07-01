import Foundation
import simd

/// Drives playback of an ``ARKitBodyAnim`` on a clock, emitting the current frame.
@MainActor
public final class MoCapPlayer: ObservableObject {
    @Published public private(set) var currentFrame: ARKitBodyFrame?
    @Published public private(set) var time: TimeInterval = 0
    @Published public private(set) var isPlaying = false

    public var anim: ARKitBodyAnim
    public var loops: Bool = true
    /// Called on every tick with the interpolated/nearest frame.
    public var onFrame: ((ARKitBodyFrame) -> Void)?

    public init(anim: ARKitBodyAnim) {
        self.anim = anim
        self.currentFrame = anim.frames.first
    }

    public func play() { isPlaying = true }
    public func pause() { isPlaying = false }
    public func seek(to t: TimeInterval) {
        time = t
        emit()
    }

    private var lastTickDate: Date?

    /// Advance the playhead using wall-clock dates (for `TimelineView(.animation)`).
    public func advance(to date: Date) {
        defer { lastTickDate = date }
        guard let last = lastTickDate else { return }
        tick(delta: date.timeIntervalSince(last))
    }

    /// Advance the playhead by `delta` seconds. Call from a display link / RealityKit update loop.
    public func tick(delta: TimeInterval) {
        guard isPlaying, anim.duration > 0 else { return }
        time += delta
        if time > anim.duration {
            if loops { time = time.truncatingRemainder(dividingBy: anim.duration) }
            else { time = anim.duration; isPlaying = false }
        }
        emit()
    }

    private func emit() {
        guard let frame = anim.frame(at: time) else { return }
        currentFrame = frame
        onFrame?(frame)
    }
}
