import Foundation
import simd

#if os(iOS) && canImport(ARKit)
import ARKit

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

public final class ARBodyCaptureSession: NSObject, ARSessionDelegate {
    public let session = ARSession()
    private let recorder: MoCapRecorder

    /// Emitted on every body-anchor update (recording or not) for live overlay rendering.
    public var onLiveBody: ((LiveBodySnapshot) -> Void)?
    /// True while a body anchor is currently tracked.
    public private(set) var isBodyTracked = false

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

        Task { @MainActor in
            recorder.append(
                rootTransform: root,
                localJoints: locals,
                timestamp: CACurrentMediaTime()
            )
        }
    }

    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        if anchors.contains(where: { $0 is ARBodyAnchor }) { isBodyTracked = false }
    }
}
#endif
