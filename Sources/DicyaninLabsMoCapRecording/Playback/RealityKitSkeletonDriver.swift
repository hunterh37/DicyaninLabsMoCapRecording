import Foundation
import simd

#if canImport(RealityKit)
import RealityKit

/// Applies retargeted Mixamo transforms onto a rigged `ModelEntity`'s skeleton so
/// recorded body anims can drive the existing Mixamo nurse models.
@MainActor
public final class RealityKitSkeletonDriver {
    private weak var model: ModelEntity?
    private let retargeter: MixamoRetargeter
    /// Map of ModelEntity joint index -> bare Mixamo bone name, resolved from jointNames.
    private var indexToBone: [Int: String] = [:]
    /// The rig's bind-pose local joint transforms, captured once at init. Bone lengths
    /// (translations) and scales are taken from here so the retarget only rotates joints.
    private var bindTransforms: [Transform] = []
    /// Preserve each Mixamo bone's bind translation/scale and only apply retargeted
    /// rotation. Copying ARKit joint translations onto Mixamo bones stretches limbs
    /// because the two rigs have different bone lengths.
    public var rotationOnly: Bool = true

    /// ARKit neutral (rest) local rotation per bare Mixamo bone name, when available.
    /// When set, `apply` uses delta retargeting (`bindRot * restRot⁻¹ * currentRot`),
    /// which respects both rigs' bind poses. Without it, falls back to absolute rotation.
    private var restRotByBone: [String: simd_quatf] = [:]

    public init(model: ModelEntity, retargeter: MixamoRetargeter = MixamoRetargeter()) {
        self.model = model
        self.retargeter = retargeter
        resolveJointNames()
    }

    /// Which ARKit joint drives each Mixamo bone (last mapping wins, matching the
    /// retargeter's spine-chain collapse). Used to read the current raw rotation from
    /// the frame in the SAME ARKit local frame as the rest, so the delta is consistent.
    private var jointForBone: [String: ARKitBodyJoint] = [:]

    /// Supplies the ARKit neutral pose (from `ARKitBodyAnim.restPose`) to enable delta
    /// retargeting. Keys are ARKit joint raw names; the last joint mapping to each Mixamo
    /// bone wins (matches the retargeter's collapse of the spine chain).
    public func setRestPose(_ restPose: [String: AnimTransform]) {
        var map: [String: simd_quatf] = [:]
        var joints: [String: ARKitBodyJoint] = [:]
        for joint in ARKitBodyJoint.allCases {
            guard let bone = joint.mixamoBoneName,
                  let rest = restPose[joint.rawValue] else { continue }
            map[bone] = simd_quatf(rest.matrix)
            joints[bone] = joint
        }
        restRotByBone = map
        jointForBone = joints
    }

    public var hasRestPose: Bool { !restRotByBone.isEmpty }

    private func resolveJointNames() {
        guard let model else { return }
        // ModelEntity exposes joint names via `jointNames`.
        for (i, name) in model.jointNames.enumerated() {
            indexToBone[i] = Self.bareBoneName(name)
        }
        bindTransforms = model.jointTransforms
    }

    /// Normalizes a rig joint name to a bare Mixamo bone name. Handles hierarchical
    /// paths ("Root/Hips/Spine/...") and both Mixamo prefix styles emitted by
    /// different exporters: "mixamorig:LeftArm" and "mixamorig_LeftArm".
    public static func bareBoneName(_ name: String) -> String {
        var n = name
        if let slash = n.lastIndex(of: "/") { n = String(n[n.index(after: slash)...]) }
        if let colon = n.lastIndex(of: ":") { n = String(n[n.index(after: colon)...]) }
        for prefix in ["mixamorig_", "mixamorig:"] where n.hasPrefix(prefix) {
            n = String(n.dropFirst(prefix.count))
        }
        return n
    }

    /// Apply a recorded frame to the model's joints.
    public func apply(_ frame: ARKitBodyFrame) {
        guard let model else { return }
        var transforms = model.jointTransforms
        guard !transforms.isEmpty else { return }

        // Delta path reads current rotation from the RAW frame, in the identical ARKit
        // local frame the rest was captured in — so `restRot⁻¹ * currentRot` is a pure
        // motion delta with no frame mismatch. Applied onto the Mixamo bind pose.
        if !restRotByBone.isEmpty {
            for (index, bone) in indexToBone {
                guard index < transforms.count, index < bindTransforms.count,
                      let restRot = restRotByBone[bone],
                      let joint = jointForBone[bone],
                      let currentLocal = frame.localTransform(joint) else { continue }
                let currentRot = simd_quatf(currentLocal)
                let motion = restRot.inverse * currentRot
                var t = bindTransforms[index]
                t.rotation = (t.rotation * motion).normalized
                transforms[index] = t
            }
            model.jointTransforms = transforms
            return
        }

        // No rest pose: absolute fallback via the retargeter.
        let bones = retargeter.retarget(frame)
        for (index, bone) in indexToBone {
            guard index < transforms.count, let m = bones[bone] else { continue }
            if rotationOnly, index < bindTransforms.count {
                var t = bindTransforms[index]
                t.rotation = simd_quatf(m)
                transforms[index] = t
            } else {
                transforms[index] = Transform(matrix: m)
            }
        }
        model.jointTransforms = transforms
    }

    // MARK: - Diagnostics

    /// Bare Mixamo bone names exposed by the rig, in joint index order.
    public var rigBoneNames: [String] {
        indexToBone.sorted { $0.key < $1.key }.map(\.value)
    }

    /// A high-signal comparison dump: which ARKit joints the clip provides, which
    /// Mixamo bones the rig exposes, how they overlap, and per-bone bind vs retargeted
    /// rotation/translation for the key joints. Useful for diagnosing a mangled pose.
    public func debugReport(for frame: ARKitBodyFrame) -> String {
        let bones = retargeter.retarget(frame)
        let rigNames = Set(indexToBone.values)
        let mapped = Set(bones.keys)

        var lines: [String] = []
        lines.append("=== MoCap Retarget Debug ===")
        lines.append("rig joints: \(indexToBone.count)  retargeted bones: \(bones.count)")
        lines.append("clip joints in frame: \(frame.localJoints.count)")

        let driven = rigNames.intersection(mapped).sorted()
        let undriven = rigNames.subtracting(mapped).sorted()
        let unmatched = mapped.subtracting(rigNames).sorted()
        lines.append("DRIVEN rig bones (\(driven.count)): \(driven.joined(separator: ", "))")
        lines.append("UNDRIVEN rig bones (\(undriven.count)): \(undriven.joined(separator: ", "))")
        lines.append("retarget bones NOT on rig (\(unmatched.count)): \(unmatched.joined(separator: ", "))")

        let keyBones = ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head",
                        "LeftArm", "LeftForeArm", "LeftHand",
                        "RightArm", "RightForeArm", "RightHand",
                        "LeftUpLeg", "LeftLeg", "RightUpLeg", "RightLeg"]
        lines.append("--- per-bone bind vs retargeted (rotation as axis*angle°, translation) ---")
        for (index, bone) in indexToBone.sorted(by: { $0.key < $1.key }) {
            guard keyBones.contains(bone) else { continue }
            let bindT = index < bindTransforms.count ? bindTransforms[index] : Transform()
            let bindRot = Self.fmtQuat(bindT.rotation)
            let bindTr = Self.fmtVec(bindT.translation)
            if let m = bones[bone] {
                let rot = Self.fmtQuat(simd_quatf(m))
                let tr = Self.fmtVec(SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z))
                lines.append("[\(index)] \(bone): bindRot \(bindRot) -> animRot \(rot) | bindT \(bindTr) animT \(tr)")
            } else {
                lines.append("[\(index)] \(bone): NOT DRIVEN (bindRot \(bindRot) bindT \(bindTr))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func fmtQuat(_ q: simd_quatf) -> String {
        let angle = q.angle * 180 / .pi
        let a = q.axis
        return String(format: "%.0f° (%.2f,%.2f,%.2f)", angle, a.x, a.y, a.z)
    }
    private static func fmtVec(_ v: SIMD3<Float>) -> String {
        String(format: "(%.3f,%.3f,%.3f)", v.x, v.y, v.z)
    }
}
#endif
