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

    /// Retargeting strategy.
    public enum Mode: String, CaseIterable, Sendable {
        /// Aim limb bones along recorded joint-position directions (no roll). Robust but
        /// cannot reproduce forearm/wrist twist.
        case directionMatch
        /// Transfer full world orientation relative to the reference pose (aim + roll).
        /// Needs the reference to match the pose the actor actually started in.
        case rotationTransfer
    }
    public var mode: Mode = .rotationTransfer

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

    /// Bones aimed by direction matching, mapped to the child joint whose position
    /// defines the bone's forward direction.
    static let directionChild: [ARKitBodyJoint: ARKitBodyJoint] = [
        .leftShoulder: .leftArm, .leftArm: .leftForearm, .leftForearm: .leftHand,
        .rightShoulder: .rightArm, .rightArm: .rightForearm, .rightForearm: .rightHand,
        .leftUpLeg: .leftLeg, .leftLeg: .leftFoot,
        .rightUpLeg: .rightLeg, .rightLeg: .rightFoot,
    ]
    /// End bones (no child) that should inherit their parent bone's swing.
    static let directionEnd: [ARKitBodyJoint: ARKitBodyJoint] = [
        .leftForearm: .leftHand, .rightForearm: .rightHand,
        .leftLeg: .leftFoot, .rightLeg: .rightFoot,
    ]

    /// Shortest-arc rotation taking unit vector `a` onto unit vector `b`.
    public static func rotation(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let d = simd_dot(a, b)
        if d >= 0.99999 { return .id }
        if d <= -0.99999 {
            // 180°: pick any axis perpendicular to a.
            var axis = simd_cross(SIMD3<Float>(1, 0, 0), a)
            if simd_length(axis) < 1e-4 { axis = simd_cross(SIMD3<Float>(0, 1, 0), a) }
            return simd_quatf(angle: .pi, axis: simd_normalize(axis))
        }
        let axis = simd_normalize(simd_cross(a, b))
        return simd_quatf(angle: acos(min(1, max(-1, d))), axis: axis)
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

        // Retarget. Limb bones (arms/legs) use DIRECTION MATCHING: aim each Mixamo bone
        // along the world direction its ARKit counterpart points (derived from joint
        // POSITIONS, which are unambiguous and mirror-safe), instead of composing
        // rotations across two rigs whose per-bone roll axes disagree. Rotation-transfer
        // was fixing one arm and breaking the other precisely because those axes differ
        // between left and right. Torso/neck/head keep the world-global rotation delta,
        // which looked correct there.
        if hasRestPose {
            var arkitRestW: [ARKitBodyJoint: simd_quatf] = [:]
            var arkitCurW: [ARKitBodyJoint: simd_quatf] = [:]
            var bindW: [ARKitBodyJoint: simd_quatf] = [:]
            var targetW: [ARKitBodyJoint: simd_quatf] = [:]
            var arkitCurMat: [ARKitBodyJoint: simd_float4x4] = [:]
            var bindMat: [ARKitBodyJoint: simd_float4x4] = [:]

            // Pass A: accumulate world rotations + world matrices (for positions), and set
            // a default world-global target for every joint.
            for joint in primaryJoints {
                let parent = parentPrimary[joint]
                let restLocal = arkitRestLocalRot[joint] ?? .id
                let curMatLocal = frame.localTransform(joint) ?? simd_float4x4(restLocal)
                let bindLocalMat = (indexForJoint[joint].flatMap { $0 < bindTransforms.count ? bindTransforms[$0].matrix : nil }) ?? matrix_identity_float4x4

                let pRestW = parent.flatMap { arkitRestW[$0] } ?? .id
                let pCurW = parent.flatMap { arkitCurW[$0] } ?? .id
                let pBindW = parent.flatMap { bindW[$0] } ?? .id
                let pCurMat = parent.flatMap { arkitCurMat[$0] } ?? matrix_identity_float4x4
                let pBindMat = parent.flatMap { bindMat[$0] } ?? matrix_identity_float4x4

                let rW = (pRestW * restLocal).normalized
                let cW = (pCurW * simd_quatf(curMatLocal)).normalized
                let bW = (pBindW * (mixamoBindLocalRot[joint] ?? .id)).normalized
                arkitRestW[joint] = rW
                arkitCurW[joint] = cW
                bindW[joint] = bW
                arkitCurMat[joint] = pCurMat * curMatLocal
                bindMat[joint] = pBindMat * bindLocalMat

                // rotationTransfer: apply the actor's WORLD motion delta (curW * restW⁻¹)
                // to the Mixamo bind orientation. World-space (left) composition is axis
                // agnostic, so it is symmetric across the mirrored arms, unlike the
                // per-bone-local form bindW * restW⁻¹ * curW which reinterprets an ARKit
                // local-frame delta in the Mixamo frame and so flips one arm. No-op at the
                // reference frame (curW == restW leaves the joint at its own bind).
                targetW[joint] = (cW * rW.inverse * bW).normalized
            }

            // Pass B: in directionMatch mode, override limb chains with position-based aim.
            if mode == .directionMatch {
                func pos(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
                for (joint, child) in Self.directionChild {
                    guard let jMat = arkitCurMat[joint], let cMat = arkitCurMat[child],
                          let jb = bindMat[joint], let cb = bindMat[child],
                          let bW = bindW[joint] else { continue }
                    let targetDir = simd_normalize(pos(cMat) - pos(jMat))
                    let bindDir = simd_normalize(pos(cb) - pos(jb))
                    guard targetDir.x.isFinite, bindDir.x.isFinite else { continue }
                    let swing = Self.rotation(from: bindDir, to: targetDir)
                    targetW[joint] = (swing * bW).normalized
                    if let end = Self.directionEnd[joint], let endBind = bindW[end] {
                        targetW[end] = (swing * endBind).normalized
                    }
                }
            }

            // Pass C: write parent-relative local rotations, parent-first.
            for joint in primaryJoints {
                guard let index = indexForJoint[joint], index < transforms.count,
                      index < bindTransforms.count, let tW = targetW[joint] else { continue }
                let parentTW = parentPrimary[joint].flatMap { targetW[$0] } ?? .id
                var t = bindTransforms[index]
                t.rotation = (parentTW.inverse * tW).normalized
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
            let motion = (cW * rW.inverse).normalized
            let tW = (motion * bW).normalized
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
                let rW = restW[joint] ?? .id
                let cW = curW[joint] ?? .id
                let bW = bindW[joint] ?? .id
                // Per-bone alignment offset: how the nurse bind orientation relates to the
                // ARKit rest orientation in world. If left ≈ identity but right ≠, that's
                // the asymmetry driving the one-sided break.
                let align = (bW * rW.inverse).normalized
                lines.append("\(label) \(joint.mixamoBoneName ?? "?"): restW \(Self.q(rW)) curW \(Self.q(cW)) bindW \(Self.q(bW)) align \(Self.q(align))")
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
