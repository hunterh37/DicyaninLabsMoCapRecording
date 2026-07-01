import Foundation
import simd

#if os(visionOS)
import ARKit

/// visionOS hand-tracking capture that feeds a ``MoCapRecorder``. Runs alongside
/// ``ARBodyCaptureSession`` (iOS-only) or standalone, since visionOS has no
/// `ARBodyTrackingConfiguration`: this session supplies finger data, and the caller
/// is responsible for calling `recorder.append`/`appendHands` with the latest hands.
@MainActor
public final class ARHandCaptureSession {
    private let session = ARKitSession()
    private let provider = HandTrackingProvider()
    private weak var recorder: MoCapRecorder?

    /// Latest captures, updated on every hand-anchor update.
    public private(set) var latestLeft: HandCapture?
    public private(set) var latestRight: HandCapture?

    /// Emitted on every update for live overlay rendering, independent of recording state.
    public var onLiveHands: ((HandCapture?, HandCapture?) -> Void)?

    public init(recorder: MoCapRecorder? = nil) {
        self.recorder = recorder
    }

    public var isSupported: Bool { HandTrackingProvider.isSupported }

    public func run() async throws {
        guard HandTrackingProvider.isSupported else { return }
        try await session.run([provider])
        Task { await consumeUpdates() }
    }

    public func stop() { session.stop() }

    private func consumeUpdates() async {
        for await update in provider.anchorUpdates {
            let anchor = update.anchor
            guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
                switch anchor.chirality {
                case .left: latestLeft = nil
                case .right: latestRight = nil
                @unknown default: break
                }
                onLiveHands?(latestLeft, latestRight)
                continue
            }

            var locals: [String: simd_float4x4] = [:]
            locals.reserveCapacity(ARKitHandJoint.allCases.count)
            for joint in ARKitHandJoint.allCases {
                guard let name = Self.jointName(joint) else { continue }
                let jointTransform = skeleton.joint(name)
                locals[joint.rawValue] = jointTransform.anchorFromJointTransform
            }

            let capture = HandCapture(root: anchor.originFromAnchorTransform, localJoints: locals)
            switch anchor.chirality {
            case .left: latestLeft = capture
            case .right: latestRight = capture
            @unknown default: break
            }
            onLiveHands?(latestLeft, latestRight)

            if let recorder, recorder.isRecording {
                recorder.appendHands(leftHand: latestLeft, rightHand: latestRight)
            }
        }
    }

    /// Maps our stable joint enum onto ARKit's `HandSkeleton.JointName`.
    private static func jointName(_ joint: ARKitHandJoint) -> HandSkeleton.JointName? {
        switch joint {
        case .wrist: return .wrist
        case .thumbKnuckle: return .thumbKnuckle
        case .thumbIntermediateBase: return .thumbIntermediateBase
        case .thumbIntermediateTip: return .thumbIntermediateTip
        case .thumbTip: return .thumbTip
        case .indexFingerMetacarpal: return .indexFingerMetacarpal
        case .indexFingerKnuckle: return .indexFingerKnuckle
        case .indexFingerIntermediateBase: return .indexFingerIntermediateBase
        case .indexFingerIntermediateTip: return .indexFingerIntermediateTip
        case .indexFingerTip: return .indexFingerTip
        case .middleFingerMetacarpal: return .middleFingerMetacarpal
        case .middleFingerKnuckle: return .middleFingerKnuckle
        case .middleFingerIntermediateBase: return .middleFingerIntermediateBase
        case .middleFingerIntermediateTip: return .middleFingerIntermediateTip
        case .middleFingerTip: return .middleFingerTip
        case .ringFingerMetacarpal: return .ringFingerMetacarpal
        case .ringFingerKnuckle: return .ringFingerKnuckle
        case .ringFingerIntermediateBase: return .ringFingerIntermediateBase
        case .ringFingerIntermediateTip: return .ringFingerIntermediateTip
        case .ringFingerTip: return .ringFingerTip
        case .littleFingerMetacarpal: return .littleFingerMetacarpal
        case .littleFingerKnuckle: return .littleFingerKnuckle
        case .littleFingerIntermediateBase: return .littleFingerIntermediateBase
        case .littleFingerIntermediateTip: return .littleFingerIntermediateTip
        case .littleFingerTip: return .littleFingerTip
        case .forearmWrist: return .forearmWrist
        case .forearmArm: return .forearmArm
        }
    }
}
#endif
