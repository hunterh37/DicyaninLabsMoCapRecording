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

    public init(model: ModelEntity, retargeter: MixamoRetargeter = MixamoRetargeter()) {
        self.model = model
        self.retargeter = retargeter
        resolveJointNames()
    }

    private func resolveJointNames() {
        guard let model else { return }
        // ModelEntity exposes joint names via `jointNames`.
        for (i, name) in model.jointNames.enumerated() {
            let bare = name.components(separatedBy: ":").last ?? name
            indexToBone[i] = bare
        }
    }

    /// Apply a recorded frame to the model's joints.
    public func apply(_ frame: ARKitBodyFrame) {
        guard let model else { return }
        let bones = retargeter.retarget(frame)
        var transforms = model.jointTransforms
        guard !transforms.isEmpty else { return }
        for (index, bone) in indexToBone {
            guard index < transforms.count, let m = bones[bone] else { continue }
            transforms[index] = Transform(matrix: m)
        }
        model.jointTransforms = transforms
    }
}
#endif
