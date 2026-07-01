import Foundation

/// Which hand a captured hand pose belongs to.
public enum ARKitHandChirality: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

/// The visionOS `HandSkeleton.JointName` set, as stable raw strings so recorded finger
/// data round-trips 1:1 back onto a live `HandSkeleton` and forward onto a hand rig.
/// Raw values match `HandSkeleton.JointName.description`.
public enum ARKitHandJoint: String, Codable, CaseIterable, Sendable {
    case wrist

    case thumbKnuckle
    case thumbIntermediateBase
    case thumbIntermediateTip
    case thumbTip

    case indexFingerMetacarpal
    case indexFingerKnuckle
    case indexFingerIntermediateBase
    case indexFingerIntermediateTip
    case indexFingerTip

    case middleFingerMetacarpal
    case middleFingerKnuckle
    case middleFingerIntermediateBase
    case middleFingerIntermediateTip
    case middleFingerTip

    case ringFingerMetacarpal
    case ringFingerKnuckle
    case ringFingerIntermediateBase
    case ringFingerIntermediateTip
    case ringFingerTip

    case littleFingerMetacarpal
    case littleFingerKnuckle
    case littleFingerIntermediateBase
    case littleFingerIntermediateTip
    case littleFingerTip

    case forearmWrist
    case forearmArm

    /// Parent joint used for wireframe bone rendering and hierarchy reconstruction.
    public var parent: ARKitHandJoint? {
        switch self {
        case .wrist: return nil
        case .forearmWrist: return .wrist
        case .forearmArm: return .forearmWrist

        case .thumbKnuckle: return .wrist
        case .thumbIntermediateBase: return .thumbKnuckle
        case .thumbIntermediateTip: return .thumbIntermediateBase
        case .thumbTip: return .thumbIntermediateTip

        case .indexFingerMetacarpal: return .wrist
        case .indexFingerKnuckle: return .indexFingerMetacarpal
        case .indexFingerIntermediateBase: return .indexFingerKnuckle
        case .indexFingerIntermediateTip: return .indexFingerIntermediateBase
        case .indexFingerTip: return .indexFingerIntermediateTip

        case .middleFingerMetacarpal: return .wrist
        case .middleFingerKnuckle: return .middleFingerMetacarpal
        case .middleFingerIntermediateBase: return .middleFingerKnuckle
        case .middleFingerIntermediateTip: return .middleFingerIntermediateBase
        case .middleFingerTip: return .middleFingerIntermediateTip

        case .ringFingerMetacarpal: return .wrist
        case .ringFingerKnuckle: return .ringFingerMetacarpal
        case .ringFingerIntermediateBase: return .ringFingerKnuckle
        case .ringFingerIntermediateTip: return .ringFingerIntermediateBase
        case .ringFingerTip: return .ringFingerIntermediateTip

        case .littleFingerMetacarpal: return .wrist
        case .littleFingerKnuckle: return .littleFingerMetacarpal
        case .littleFingerIntermediateBase: return .littleFingerKnuckle
        case .littleFingerIntermediateTip: return .littleFingerIntermediateBase
        case .littleFingerTip: return .littleFingerIntermediateTip
        }
    }
}
