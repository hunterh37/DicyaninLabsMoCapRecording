import Foundation
import simd

/// Externally-supplied hand pose for a single capture, before packing into a frame.
/// `root` is the hand anchor world transform (`originFromAnchorTransform`);
/// `localJoints` are parent-relative transforms keyed by ``ARKitHandJoint`` raw name.
public struct HandCapture: Sendable {
    public var root: simd_float4x4
    public var localJoints: [String: simd_float4x4]

    public init(root: simd_float4x4, localJoints: [String: simd_float4x4]) {
        self.root = root
        self.localJoints = localJoints
    }

    public var frame: ARKitHandFrame {
        ARKitHandFrame(rootTransform: AnimTransform(root), localJoints: localJoints.mapValues(AnimTransform.init))
    }
}

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
        leftHand: HandCapture? = nil,
        rightHand: HandCapture? = nil,
        timestamp: TimeInterval? = nil
    ) {
        guard isRecording else { return }
        let t = (timestamp ?? CACurrentMediaTimeSafe()) - startTime
        let frame = ARKitBodyFrame(
            time: t,
            rootTransform: AnimTransform(rootTransform),
            localJoints: localJoints.mapValues(AnimTransform.init),
            leftHand: leftHand?.frame,
            rightHand: rightHand?.frame
        )
        frames.append(frame)
        frameCount = frames.count
        elapsed = t
    }

    /// Append a hands-only pose (visionOS, where there is no ARKit body anchor). The body
    /// root is identity and body joints are empty; hand finger data drives the frame.
    public func appendHands(
        leftHand: HandCapture? = nil,
        rightHand: HandCapture? = nil,
        timestamp: TimeInterval? = nil
    ) {
        append(
            rootTransform: matrix_identity_float4x4,
            localJoints: [:],
            leftHand: leftHand,
            rightHand: rightHand,
            timestamp: timestamp
        )
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
