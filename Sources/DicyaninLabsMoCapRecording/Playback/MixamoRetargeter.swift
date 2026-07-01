import Foundation
import simd

/// Maps recorded ARKit joint transforms onto a Mixamo humanoid skeleton.
///
/// The ARKit body rig and the Mixamo rig share the same humanoid topology, so the
/// local rotation of each ARKit joint can drive the corresponding Mixamo bone. A
/// per-joint rest-offset accounts for differing bind poses between the two rigs.
public struct MixamoRetargeter {
    /// Optional per-Mixamo-bone rotation offset (bind-pose correction), keyed by bare bone name.
    public var restOffsets: [String: simd_quatf]
    /// Whether to apply root translation from the recording to the Mixamo Hips bone.
    public var applyRootTranslation: Bool

    public init(restOffsets: [String: simd_quatf] = [:], applyRootTranslation: Bool = true) {
        self.restOffsets = restOffsets
        self.applyRootTranslation = applyRootTranslation
    }

    /// Produce Mixamo bone-name -> local transform for a single frame.
    /// Keys are bare Mixamo bone names (e.g. "LeftForeArm"); prefix with "mixamorig:" if needed.
    public func retarget(_ frame: ARKitBodyFrame) -> [String: simd_float4x4] {
        var out: [String: simd_float4x4] = [:]
        for joint in ARKitBodyJoint.allCases {
            guard let bone = joint.mixamoBoneName,
                  let local = frame.localTransform(joint) else { continue }

            var rotation = simd_quatf(local)
            if let offset = restOffsets[bone] {
                rotation = offset * rotation
            }

            var transform = simd_float4x4(rotation)
            if joint == .hips || joint == .root {
                if applyRootTranslation {
                    let t = frame.rootTransform.translation
                    transform.columns.3 = SIMD4<Float>(t, 1)
                } else {
                    transform.columns.3 = SIMD4<Float>(local.columns.3.x, local.columns.3.y, local.columns.3.z, 1)
                }
            } else {
                transform.columns.3 = local.columns.3
            }
            // Last-writer wins for many-to-one ARKit->Mixamo mappings (e.g. spine chain).
            out[bone] = transform
        }
        return out
    }
}
