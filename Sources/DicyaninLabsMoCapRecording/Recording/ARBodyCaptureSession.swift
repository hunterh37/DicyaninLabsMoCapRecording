import Foundation
import simd

#if os(iOS) && canImport(ARKit)
import ARKit
#if canImport(Vision)
import Vision
#endif

/// iPhone-side ARKit body-tracking capture that feeds a ``MoCapRecorder``.
///
/// Usage:
/// ```swift
/// let capture = ARBodyCaptureSession(recorder: recorder)
/// capture.run()                 // starts ARBodyTrackingConfiguration
/// recorder.start(name: "take1")
/// // ...perform the movement...
/// let anim = recorder.stop()
/// try anim.write(to: url)
/// ```
/// A live skeleton snapshot for overlay rendering: world-space joint transforms plus
/// the camera needed to project them into screen space.
public struct LiveBodySnapshot: @unchecked Sendable {
    public let worldJoints: [ARKitBodyJoint: simd_float4x4]
    public let camera: ARCamera

    /// Project joints to screen points for a given viewport and interface orientation.
    public func projectedPoints(viewportSize: CGSize, orientation: UIInterfaceOrientation) -> [ARKitBodyJoint: CGPoint] {
        var out: [ARKitBodyJoint: CGPoint] = [:]
        for (joint, m) in worldJoints {
            let world = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let p = camera.projectPoint(world, orientation: orientation, viewportSize: viewportSize)
            out[joint] = p
        }
        return out
    }

    /// Parent/child bone pairs to stroke between projected points.
    public var bones: [(ARKitBodyJoint, ARKitBodyJoint)] {
        ARKitBodyJoint.allCases.compactMap { j in j.parent.map { (j, $0) } }
    }
}

/// A live hand snapshot for overlay rendering, mirroring ``LiveBodySnapshot``: world-space
/// joint transforms (already combined with the hand's root/anchor) plus the camera needed
/// to project them into screen space.
public struct LiveHandSnapshot: @unchecked Sendable {
    public let worldJoints: [ARKitHandJoint: simd_float4x4]
    public let camera: ARCamera

    public func projectedPoints(viewportSize: CGSize, orientation: UIInterfaceOrientation) -> [ARKitHandJoint: CGPoint] {
        var out: [ARKitHandJoint: CGPoint] = [:]
        for (joint, m) in worldJoints {
            let world = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            out[joint] = camera.projectPoint(world, orientation: orientation, viewportSize: viewportSize)
        }
        return out
    }

    public var bones: [(ARKitHandJoint, ARKitHandJoint)] {
        ARKitHandJoint.allCases.compactMap { j in j.parent.map { (j, $0) } }
    }
}

public final class ARBodyCaptureSession: NSObject, ARSessionDelegate {
    public let session = ARSession()
    private let recorder: MoCapRecorder

    /// Emitted on every body-anchor update (recording or not) for live overlay rendering.
    public var onLiveBody: ((LiveBodySnapshot) -> Void)?
    /// True while a body anchor is currently tracked.
    public private(set) var isBodyTracked = false

    #if canImport(Vision)
    /// iPhone has no ARKit hand-skeleton API (that's visionOS-only via `HandTrackingProvider`),
    /// but Vision's hand-pose detector runs on the same camera frames ARKit is already
    /// capturing, so finger tracking is still possible here.
    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private var frameSkipCounter = 0
    private var latestLeftHand: HandCapture?
    private var latestRightHand: HandCapture?
    /// Most recent body-skeleton world joint transforms, so Vision's hand detections (which
    /// have no depth/position of their own) can be anchored to the real arm position instead
    /// of floating at an arbitrary image-space location.
    private var latestBodyWorldJoints: [ARKitBodyJoint: simd_float4x4] = [:]
    #endif

    /// Emitted whenever Vision's hand detection updates (recording or not), independent
    /// of body tracking. Positions are already anchored + projectable, like ``onLiveBody``.
    public var onLiveHands: ((LiveHandSnapshot?, LiveHandSnapshot?) -> Void)?
    /// True while Vision currently detects a left/right hand in the camera frame.
    public private(set) var isLeftHandTracked = false
    public private(set) var isRightHandTracked = false

    public init(recorder: MoCapRecorder) {
        self.recorder = recorder
        super.init()
        session.delegate = self
    }

    public var isSupported: Bool { ARBodyTrackingConfiguration.isSupported }

    public func run() {
        guard ARBodyTrackingConfiguration.isSupported else { return }
        let config = ARBodyTrackingConfiguration()
        config.automaticSkeletonScaleEstimationEnabled = true
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    public func pause() { session.pause() }

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let body = anchors.compactMap({ $0 as? ARBodyAnchor }).first else { return }
        isBodyTracked = body.isTracked
        let skeleton = body.skeleton
        let def = skeleton.definition
        let root = body.transform

        var locals: [String: simd_float4x4] = [:]
        var world: [ARKitBodyJoint: simd_float4x4] = [:]
        locals.reserveCapacity(def.jointNames.count)
        let localTransforms = skeleton.jointLocalTransforms
        let modelTransforms = skeleton.jointModelTransforms
        for (index, name) in def.jointNames.enumerated() {
            // Only persist joints we model in ARKitBodyJoint.
            guard let joint = ARKitBodyJoint(rawValue: name) else { continue }
            locals[name] = localTransforms[index]
            // Model transforms are relative to the hips root; lift to world space.
            world[joint] = root * modelTransforms[index]
        }

        if let camera = session.currentFrame?.camera {
            onLiveBody?(LiveBodySnapshot(worldJoints: world, camera: camera))
        }
        #if canImport(Vision)
        latestBodyWorldJoints = world
        #endif

        // Capture the ARKit neutral (rest) pose once, so playback can delta-retarget.
        var restLocals: [String: simd_float4x4] = [:]
        let neutral = def.neutralBodySkeleton3D
        let neutralLocals = neutral?.jointLocalTransforms
        for (index, name) in def.jointNames.enumerated() {
            guard ARKitBodyJoint(rawValue: name) != nil,
                  let neutralLocals, index < neutralLocals.count else { continue }
            restLocals[name] = neutralLocals[index]
        }

        let recorder = self.recorder
        #if canImport(Vision)
        let leftHand = latestLeftHand
        let rightHand = latestRightHand
        #else
        let leftHand: HandCapture? = nil
        let rightHand: HandCapture? = nil
        #endif
        Task { @MainActor [restLocals, locals, root, leftHand, rightHand] in
            recorder.setRestPose(restLocals)
            recorder.append(
                rootTransform: root,
                localJoints: locals,
                leftHand: leftHand,
                rightHand: rightHand,
                timestamp: CACurrentMediaTime()
            )
        }
    }

    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        if anchors.contains(where: { $0 is ARBodyAnchor }) { isBodyTracked = false }
    }

    #if canImport(Vision)
    /// Runs on every camera frame (not just body-anchor updates), so hand detection works
    /// even before/without a body being tracked. Throttled to every other frame since
    /// Vision's hand-pose request is relatively expensive at 60fps.
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameSkipCounter += 1
        guard frameSkipCounter % 2 == 0 else { return }

        let pixelBuffer = frame.capturedImage
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([handPoseRequest])
        } catch {
            return
        }
        guard let observations = handPoseRequest.results, !observations.isEmpty else {
            latestLeftHand = nil
            latestRightHand = nil
            isLeftHandTracked = false
            isRightHandTracked = false
            onLiveHands?(nil, nil)
            return
        }

        let bodyWorldJoints = latestBodyWorldJoints
        var left: HandCapture?
        var right: HandCapture?
        for observation in observations {
            switch observation.chirality {
            case .left:
                left = Self.handCapture(from: observation, anchor: bodyWorldJoints[.leftHand])
            case .right:
                right = Self.handCapture(from: observation, anchor: bodyWorldJoints[.rightHand])
            default:
                break
            }
        }
        latestLeftHand = left
        latestRightHand = right
        isLeftHandTracked = left != nil
        isRightHandTracked = right != nil

        let camera = frame.camera
        onLiveHands?(Self.snapshot(left, camera: camera), Self.snapshot(right, camera: camera))
    }

    /// Maps Vision's flat hand-pose points onto our parent-relative ``ARKitHandJoint``
    /// hierarchy. Vision only reports a subset of the joints ARKit's visionOS skeleton has
    /// (no metacarpals besides the thumb, no forearm), so missing ancestors are treated as
    /// coincident with their own parent — which is exactly how
    /// `ARKitHandFrame.jointWorldTransforms()` already resolves a joint with no recorded
    /// local transform, so the two stay consistent.
    private static let visionJointMap: [VNHumanHandPoseObservation.JointName: ARKitHandJoint] = [
        .wrist: .wrist,
        .thumbCMC: .thumbKnuckle, .thumbMP: .thumbIntermediateBase, .thumbIP: .thumbIntermediateTip, .thumbTip: .thumbTip,
        .indexMCP: .indexFingerKnuckle, .indexPIP: .indexFingerIntermediateBase, .indexDIP: .indexFingerIntermediateTip, .indexTip: .indexFingerTip,
        .middleMCP: .middleFingerKnuckle, .middlePIP: .middleFingerIntermediateBase, .middleDIP: .middleFingerIntermediateTip, .middleTip: .middleFingerTip,
        .ringMCP: .ringFingerKnuckle, .ringPIP: .ringFingerIntermediateBase, .ringDIP: .ringFingerIntermediateTip, .ringTip: .ringFingerTip,
        .littleMCP: .littleFingerKnuckle, .littlePIP: .littleFingerIntermediateBase, .littleDIP: .littleFingerIntermediateTip, .littleTip: .littleFingerTip,
    ]

    /// Vision has no depth, so a raw 2D detection carries no usable position by itself.
    /// The hand's ROOT is anchored to the body skeleton's real 3D hand joint (the end of
    /// the tracked arm) instead, and only the finger SHAPE (relative offsets from the
    /// wrist) comes from Vision, scaled to a plausible hand size. That keeps recorded
    /// finger data in the same metric space as the body, anatomically attached to the arm,
    /// rather than floating at an arbitrary image-space location.
    private static let assumedHandSpanMeters: Float = 0.16

    private static func handCapture(from observation: VNHumanHandPoseObservation, anchor: simd_float4x4?) -> HandCapture? {
        guard let anchor else { return nil }

        var absolute2D: [ARKitHandJoint: SIMD3<Float>] = [:]
        for (visionName, joint) in visionJointMap {
            guard let point = try? observation.recognizedPoint(visionName), point.confidence > 0.3 else { continue }
            absolute2D[joint] = SIMD3<Float>(Float(point.location.x), Float(point.location.y), 0)
        }
        guard !absolute2D.isEmpty else { return nil }

        var resolved2D: [ARKitHandJoint: SIMD3<Float>] = [:]
        func position2D(_ joint: ARKitHandJoint) -> SIMD3<Float> {
            if let cached = resolved2D[joint] { return cached }
            let p: SIMD3<Float>
            if let known = absolute2D[joint] {
                p = known
            } else if let parent = joint.parent {
                p = position2D(parent)
            } else {
                p = .zero
            }
            resolved2D[joint] = p
            return p
        }

        var locals: [String: simd_float4x4] = [:]
        for joint in ARKitHandJoint.allCases {
            guard joint != .wrist else {
                // The wrist IS the anchor: keep it at the root's origin so every other
                // joint's scaled offset is relative to the real arm position, not to
                // wherever Vision happened to detect the wrist in the camera frame.
                locals[joint.rawValue] = matrix_identity_float4x4
                continue
            }
            let parentPos2D = joint.parent.map(position2D) ?? .zero
            let delta2D = position2D(joint) - parentPos2D
            let delta = delta2D * assumedHandSpanMeters
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4<Float>(delta.x, delta.y, delta.z, 1)
            locals[joint.rawValue] = m
        }
        return HandCapture(root: anchor, localJoints: locals)
    }

    /// Combines a capture's root anchor with its (wrist-relative) local hierarchy into
    /// world-space transforms for live overlay projection.
    private static func snapshot(_ capture: HandCapture?, camera: ARCamera) -> LiveHandSnapshot? {
        guard let capture else { return nil }
        var world: [ARKitHandJoint: simd_float4x4] = [:]
        for (joint, local) in capture.frame.jointWorldTransforms() {
            world[joint] = capture.root * local
        }
        return LiveHandSnapshot(worldJoints: world, camera: camera)
    }
    #endif
}
#endif
