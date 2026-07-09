import Foundation

/// The canonical ARKit body-tracking joints (subset of ARSkeletonDefinition.defaultBody3D).
/// Names match ARKit's `ARSkeleton.JointName` raw strings so recorded data maps 1:1 back
/// onto a live `ARSkeleton3D`, and forward onto a Mixamo humanoid rig via `mixamoBoneName`.
public enum ARKitBodyJoint: String, Codable, CaseIterable, Sendable {
    case root = "root"
    case hips = "hips_joint"
    case spine1 = "spine_1_joint"
    case spine2 = "spine_2_joint"
    case spine3 = "spine_3_joint"
    case spine4 = "spine_4_joint"
    case spine5 = "spine_5_joint"
    case spine6 = "spine_6_joint"
    case spine7 = "spine_7_joint"
    case neck1 = "neck_1_joint"
    case neck2 = "neck_2_joint"
    case neck3 = "neck_3_joint"
    case neck4 = "neck_4_joint"
    case head = "head_joint"

    case leftShoulder = "left_shoulder_1_joint"
    case leftArm = "left_arm_joint"
    case leftForearm = "left_forearm_joint"
    case leftHand = "left_hand_joint"

    case rightShoulder = "right_shoulder_1_joint"
    case rightArm = "right_arm_joint"
    case rightForearm = "right_forearm_joint"
    case rightHand = "right_hand_joint"

    case leftUpLeg = "left_upLeg_joint"
    case leftLeg = "left_leg_joint"
    case leftFoot = "left_foot_joint"
    case leftToes = "left_toes_joint"

    case rightUpLeg = "right_upLeg_joint"
    case rightLeg = "right_leg_joint"
    case rightFoot = "right_foot_joint"
    case rightToes = "right_toes_joint"

    /// Parent joint used for wireframe bone rendering and hierarchy reconstruction.
    public var parent: ARKitBodyJoint? {
        switch self {
        case .root: return nil
        case .hips: return .root
        case .spine1: return .hips
        case .spine2: return .spine1
        case .spine3: return .spine2
        case .spine4: return .spine3
        case .spine5: return .spine4
        case .spine6: return .spine5
        case .spine7: return .spine6
        case .neck1: return .spine7
        case .neck2: return .neck1
        case .neck3: return .neck2
        case .neck4: return .neck3
        case .head: return .neck4
        case .leftShoulder: return .spine7
        case .leftArm: return .leftShoulder
        case .leftForearm: return .leftArm
        case .leftHand: return .leftForearm
        case .rightShoulder: return .spine7
        case .rightArm: return .rightShoulder
        case .rightForearm: return .rightArm
        case .rightHand: return .rightForearm
        case .leftUpLeg: return .hips
        case .leftLeg: return .leftUpLeg
        case .leftFoot: return .leftLeg
        case .leftToes: return .leftFoot
        case .rightUpLeg: return .hips
        case .rightLeg: return .rightUpLeg
        case .rightFoot: return .rightLeg
        case .rightToes: return .rightFoot
        }
    }

    /// Corresponding Mixamo humanoid bone name (without the `mixamorig:` prefix).
    /// Used to drive existing Mixamo-rigged nurse animations from recorded body data.
    public var mixamoBoneName: String? {
        switch self {
        // `root` is intentionally unmapped: it is always identity in recordings, and
        // mapping it to "Hips" made it the PRIMARY joint for the Hips bone in the
        // skeleton driver, which silently discarded the real `hips_joint` motion
        // (the pelvis never leaned forward on playback).
        case .root: return nil
        case .hips: return "Hips"
        case .spine1, .spine2: return "Spine"
        case .spine3, .spine4: return "Spine1"
        case .spine5, .spine6, .spine7: return "Spine2"
        case .neck1, .neck2, .neck3, .neck4: return "Neck"
        case .head: return "Head"
        case .leftShoulder: return "LeftShoulder"
        case .leftArm: return "LeftArm"
        case .leftForearm: return "LeftForeArm"
        case .leftHand: return "LeftHand"
        case .rightShoulder: return "RightShoulder"
        case .rightArm: return "RightArm"
        case .rightForearm: return "RightForeArm"
        case .rightHand: return "RightHand"
        case .leftUpLeg: return "LeftUpLeg"
        case .leftLeg: return "LeftLeg"
        case .leftFoot: return "LeftFoot"
        case .leftToes: return "LeftToeBase"
        case .rightUpLeg: return "RightUpLeg"
        case .rightLeg: return "RightLeg"
        case .rightFoot: return "RightFoot"
        case .rightToes: return "RightToeBase"
        }
    }

    /// Full Mixamo bone path as emitted by Mixamo FBX exports.
    public var mixamoRigName: String? {
        mixamoBoneName.map { "mixamorig:\($0)" }
    }
}
