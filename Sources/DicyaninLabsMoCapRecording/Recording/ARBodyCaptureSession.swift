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
public final class ARBodyCaptureSession: NSObject, ARSessionDelegate {
    public let session = ARSession()
    private let recorder: MoCapRecorder

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
        let skeleton = body.skeleton
        let def = skeleton.definition

        var locals: [String: simd_float4x4] = [:]
        locals.reserveCapacity(def.jointNames.count)
        let localTransforms = skeleton.jointLocalTransforms
        for (index, name) in def.jointNames.enumerated() {
            // Only persist joints we model in ARKitBodyJoint.
            guard ARKitBodyJoint(rawValue: name) != nil else { continue }
            locals[name] = localTransforms[index]
        }

        let root = body.transform
        Task { @MainActor in
            recorder.append(
                rootTransform: root,
                localJoints: locals,
                timestamp: CACurrentMediaTime()
            )
        }
    }
}
#endif
