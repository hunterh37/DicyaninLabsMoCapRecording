import Foundation
import simd

/// Records ARKit body-tracking frames into an ``ARKitBodyAnim`` document.
///
/// Platform note: live capture via `ARBodyTrackingConfiguration` is iOS-only. On other
/// platforms this recorder still assembles frames from externally supplied joint data,
/// which keeps the format usable inside the visionOS app for playback and testing.
@MainActor
public final class MoCapRecorder: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var frameCount = 0
    @Published public private(set) var elapsed: TimeInterval = 0

    public private(set) var frameRate: Double
    private var startTime: TimeInterval = 0
    private var frames: [ARKitBodyFrame] = []
    private var name: String = "Untitled"
    private var restPose: [String: AnimTransform]?

    public init(frameRate: Double = 60) {
        self.frameRate = frameRate
    }

    /// Records the ARKit neutral (rest) pose once. Safe to call every frame; only the
    /// first non-empty pose is kept. Needed for correct delta retargeting at playback.
    public func setRestPose(_ localJoints: [String: simd_float4x4]) {
        guard restPose == nil, !localJoints.isEmpty else { return }
        restPose = localJoints.mapValues(AnimTransform.init)
    }

    public func start(name: String) {
        self.name = name
        frames.removeAll(keepingCapacity: true)
        frameCount = 0
        elapsed = 0
        startTime = CACurrentMediaTimeSafe()
        isRecording = true
    }

    /// Append a captured pose. `localJoints` are parent-relative transforms keyed by
    /// ``ARKitBodyJoint`` raw name; `rootTransform` is the body anchor world transform.
    public func append(
        rootTransform: simd_float4x4,
        localJoints: [String: simd_float4x4],
        timestamp: TimeInterval? = nil
    ) {
        guard isRecording else { return }
        let t = (timestamp ?? CACurrentMediaTimeSafe()) - startTime
        let frame = ARKitBodyFrame(
            time: t,
            rootTransform: AnimTransform(rootTransform),
            localJoints: localJoints.mapValues(AnimTransform.init)
        )
        frames.append(frame)
        frameCount = frames.count
        elapsed = t
    }

    @discardableResult
    public func stop() -> ARKitBodyAnim {
        isRecording = false
        return ARKitBodyAnim(
            name: name,
            frameRate: frameRate,
            restPose: restPose,
            frames: frames
        )
    }
}

func CACurrentMediaTimeSafe() -> TimeInterval {
    #if canImport(QuartzCore)
    return CAMediaTime()
    #else
    return Date().timeIntervalSinceReferenceDate
    #endif
}

#if canImport(QuartzCore)
import QuartzCore
func CAMediaTime() -> TimeInterval { CACurrentMediaTime() }
#endif
