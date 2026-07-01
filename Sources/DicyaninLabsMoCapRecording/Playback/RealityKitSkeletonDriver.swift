import Foundation
import simd

private extension simd_quatf {
    static let id = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
}

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

    /// ARKit rest LOCAL (parent-relative) rotation per joint, from the recorded rest pose.
    /// Motion is computed in WORLD/model space (frame-independent) so per-bone local-axis
    /// differences between the ARKit and Mixamo rigs don't skew the direction of motion.
    private var arkitRestLocalRot: [ARKitBodyJoint: simd_quatf] = [:]
    /// Mixamo bind LOCAL rotation per joint (from the rig's bind pose).
    private var mixamoBindLocalRot: [ARKitBodyJoint: simd_quatf] = [:]
    /// Rig joint index per body joint, so we write back to the right transform slot.
    private var indexForJoint: [ARKitBodyJoint: Int] = [:]
    /// One primary ARKit joint per Mixamo bone, in parent-first order (the first joint
    /// mapping to each bone). ARKit's spine has more joints than Mixamo's, so collapsing
    /// to one-per-bone keeps the world accumulation consistent between the two rigs.
    private var primaryJoints: [ARKitBodyJoint] = []
    /// Each primary joint's parent primary (nearest ancestor with a different bone).
    private var parentPrimary: [ARKitBodyJoint: ARKitBodyJoint] = [:]

    public init(model: ModelEntity, retargeter: MixamoRetargeter = MixamoRetargeter()) {
        self.model = model
        self.retargeter = retargeter
        resolveJointNames()
    }

    /// Supplies the ARKit neutral (rest) pose to enable world-space delta retargeting.
    /// Keys are ARKit joint raw names. Requires the rig joints to be resolved first.
    public func setRestPose(_ restPose: [String: AnimTransform]) {
        var rest: [ARKitBodyJoint: simd_quatf] = [:]
        for joint in ARKitBodyJoint.allCases {
            guard let t = restPose[joint.rawValue] else { continue }
            rest[joint] = simd_quatf(t.matrix)
        }
        arkitRestLocalRot = rest
    }

    public var hasRestPose: Bool { !arkitRestLocalRot.isEmpty }

    private func resolveJointNames() {
        guard let model else { return }
        // ModelEntity exposes joint names via `jointNames`.
        let boneToJoint: [String: ARKitBodyJoint] = {
            var m: [String: ARKitBodyJoint] = [:]
            for j in ARKitBodyJoint.allCases { if let b = j.mixamoBoneName { m[b] = j } }
            return m
        }()
        for (i, name) in model.jointNames.enumerated() {
            let bone = Self.bareBoneName(name)
            indexToBone[i] = bone
            // Bind a joint to the FIRST rig index carrying its bone (Mixamo has one bone
            // per name; the spine collapse maps several joints to one bone, so pick the
            // primary joint per bone to avoid several joints fighting over one index).
            if let joint = boneToJoint[bone], indexForJoint[joint] == nil {
                indexForJoint[joint] = i
            }
        }
        bindTransforms = model.jointTransforms
        for (joint, index) in indexForJoint where index < bindTransforms.count {
            mixamoBindLocalRot[joint] = bindTransforms[index].rotation
        }

        // Primary joint per bone (first in allCases order), and its parent primary.
        var seenBone: Set<String> = []
        var primaryByBone: [String: ARKitBodyJoint] = [:]
        for joint in ARKitBodyJoint.allCases {
            guard let bone = joint.mixamoBoneName, indexForJoint[joint] != nil else { continue }
            if !seenBone.contains(bone) {
                seenBone.insert(bone)
                primaryJoints.append(joint)
                primaryByBone[bone] = joint
            }
        }
        for joint in primaryJoints {
            let myBone = joint.mixamoBoneName
            var p = joint.parent
            while let cur = p {
                if let curBone = cur.mixamoBoneName, curBone != myBone,
                   let prim = primaryByBone[curBone] {
                    parentPrimary[joint] = prim
                    break
                }
                p = cur.parent
            }
        }
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

        // World-space delta retarget. Motion is measured in model/world space (rotation
        // of the bone away from its ARKit rest), which is frame-independent, then applied
        // to the Mixamo bind world orientation. This avoids the ARKit-vs-Mixamo per-bone
        // local-axis difference that otherwise turns "arms forward" into "arms sideways".
        if hasRestPose {
            var arkitRestWorld: [ARKitBodyJoint: simd_quatf] = [:]
            var arkitCurWorld: [ARKitBodyJoint: simd_quatf] = [:]
            var mixamoBindWorld: [ARKitBodyJoint: simd_quatf] = [:]
            var mixamoTargetWorld: [ARKitBodyJoint: simd_quatf] = [:]

            for joint in primaryJoints {
                let restLocal = arkitRestLocalRot[joint] ?? .id
                let curLocal = frame.localTransform(joint).map { simd_quatf($0) } ?? restLocal
                let bindLocal = mixamoBindLocalRot[joint] ?? .id

                let parent = parentPrimary[joint]
                let parentRestW = parent.flatMap { arkitRestWorld[$0] } ?? .id
                let parentCurW = parent.flatMap { arkitCurWorld[$0] } ?? .id
                let parentBindW = parent.flatMap { mixamoBindWorld[$0] } ?? .id
                let parentTargetW = parent.flatMap { mixamoTargetWorld[$0] } ?? .id

                let restW = (parentRestW * restLocal).normalized
                let curW = (parentCurW * curLocal).normalized
                let bindW = (parentBindW * bindLocal).normalized
                arkitRestWorld[joint] = restW
                arkitCurWorld[joint] = curW
                mixamoBindWorld[joint] = bindW

                // Anatomical transfer: the source bone's deviation from its rest, measured
                // in the bone's OWN frame (`restW⁻¹ * curW`, right-multiply), applied onto
                // the Mixamo bind. This transfers joint angles and is inherently mirror-
                // correct, unlike a world-global motion (`curW*restW⁻¹ * bind`) which only
                // works when the two rigs' rest poses point the same way (true for the left
                // arm, false for the right — hence the right arm was over-rotating).
                let targetW = (bindW * restW.inverse * curW).normalized
                mixamoTargetWorld[joint] = targetW

                // Back to a parent-relative local rotation for the rig.
                let newLocal = (parentTargetW.inverse * targetW).normalized
                if let index = indexForJoint[joint], index < transforms.count,
                   index < bindTransforms.count {
                    var t = bindTransforms[index]
                    t.rotation = newLocal
                    transforms[index] = t
                }
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

    /// Side-by-side left vs right arm-chain dump replicating the full world-space
    /// pipeline for a given frame, so a divergence between the two sides is visible.
    public func debugArmChains(for frame: ARKitBodyFrame? = nil) -> String {
        guard model != nil else { return "no model" }
        // Rebuild the world accumulation exactly as `apply` does.
        var restW: [ARKitBodyJoint: simd_quatf] = [:]
        var curW: [ARKitBodyJoint: simd_quatf] = [:]
        var bindW: [ARKitBodyJoint: simd_quatf] = [:]
        var targetW: [ARKitBodyJoint: simd_quatf] = [:]
        for joint in primaryJoints {
            let restLocal = arkitRestLocalRot[joint] ?? .id
            let curLocal = frame?.localTransform(joint).map { simd_quatf($0) } ?? restLocal
            let bindLocal = mixamoBindLocalRot[joint] ?? .id
            let p = parentPrimary[joint]
            let prW = p.flatMap { restW[$0] } ?? .id
            let pcW = p.flatMap { curW[$0] } ?? .id
            let pbW = p.flatMap { bindW[$0] } ?? .id
            let ptW = p.flatMap { targetW[$0] } ?? .id
            let rW = (prW * restLocal).normalized
            let cW = (pcW * curLocal).normalized
            let bW = (pbW * bindLocal).normalized
            restW[joint] = rW; curW[joint] = cW; bindW[joint] = bW
            let tW = (bW * rW.inverse * cW).normalized
            targetW[joint] = tW
            _ = ptW
        }
        let pairs: [(String, [ARKitBodyJoint])] = [
            ("LEFT ", [.leftShoulder, .leftArm, .leftForearm, .leftHand]),
            ("RIGHT", [.rightShoulder, .rightArm, .rightForearm, .rightHand]),
        ]
        var lines = ["=== Arm Chain World Pipeline ==="]
        for (label, joints) in pairs {
            for joint in joints {
                let motion = (curW[joint].map { c in (c * (restW[joint] ?? .id).inverse).normalized }) ?? .id
                lines.append("\(label) \(joint.mixamoBoneName ?? "?"): bindW \(Self.q(bindW[joint] ?? .id)) motionW \(Self.q(motion)) targetW \(Self.q(targetW[joint] ?? .id))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func q(_ q: simd_quatf) -> String {
        String(format: "%.0f°(%.2f,%.2f,%.2f)", q.angle * 180 / .pi, q.axis.x, q.axis.y, q.axis.z)
    }
    private static func v(_ v: SIMD3<Float>) -> String {
        String(format: "%.2f,%.2f,%.2f", v.x, v.y, v.z)
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
