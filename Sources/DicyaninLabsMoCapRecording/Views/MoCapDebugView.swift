import Foundation
import simd

#if canImport(SwiftUI) && canImport(RealityKit)
import SwiftUI
import RealityKit

/// A self-contained debug view for `.arkitbodyanim` clips: a live 2D wireframe next to a
/// raw 3D skeleton rebuilt straight from the recorded joint positions (no rig required).
///
/// Works out of the box with the bundled sample:
/// ```swift
/// MoCapDebugView()
/// ```
/// Or pass your own clips:
/// ```swift
/// MoCapDebugView(animations: [myAnim, other])
/// ```
/// Optionally supply a rigged `ModelEntity` to also see the retarget drive it:
/// ```swift
/// MoCapDebugView(animations: clips) { await loadMyNurseModel() }
/// ```
@available(iOS 17.0, visionOS 1.0, macOS 15.0, *)
public struct MoCapDebugView: View {
    private let animations: [ARKitBodyAnim]
    private let modelProvider: (() async -> ModelEntity?)?

    @State private var index = 0
    @State private var retargetMode: RealityKitSkeletonDriver.Mode = .rotationTransfer

    public init(
        animations: [ARKitBodyAnim]? = nil,
        modelProvider: (() async -> ModelEntity?)? = nil
    ) {
        self.animations = animations ?? [ARKitBodyAnim.sample].compactMap { $0 }
        self.modelProvider = modelProvider
    }

    private var current: ARKitBodyAnim? {
        guard animations.indices.contains(index) else { return animations.first }
        return animations[index]
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("MoCap Debug")
                .font(.largeTitle.bold())

            if animations.isEmpty {
                ContentUnavailableView("No animations", systemImage: "figure.walk")
            } else {
                controls
                HStack(spacing: 16) {
                    labeled("Raw 3D Skeleton") {
                        rawSkeleton
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                    }
                    if modelProvider != nil {
                        labeled("Retargeted Rig") {
                            riggedView
                                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    labeled("2D Wireframe") {
                        if let anim = current {
                            MoCapWirePlayerView(anim: anim)
                                .padding(8)
                                .frame(width: 240)
                                .background(.black, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
                .frame(height: 440)

                if let anim = current {
                    Text("\(anim.frames.count) frames · \(String(format: "%.1f", anim.duration))s · \(Int(anim.frameRate)) fps")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 620)
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        HStack {
            if animations.count > 1 {
                Picker("Clip", selection: $index) {
                    ForEach(animations.indices, id: \.self) { i in
                        Text(animations[i].name).tag(i)
                    }
                }
                .pickerStyle(.menu)
            }
            if modelProvider != nil {
                Picker("Mode", selection: $retargetMode) {
                    Text("Rotation").tag(RealityKitSkeletonDriver.Mode.rotationTransfer)
                    Text("Direction").tag(RealityKitSkeletonDriver.Mode.directionMatch)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
    }

    // MARK: - Raw skeleton

    private var rawSkeleton: some View {
        RawSkeletonView(anim: current)
    }

    // MARK: - Rigged

    @ViewBuilder private var riggedView: some View {
        if let anim = current, let modelProvider {
            RiggedRetargetView(anim: anim, mode: retargetMode, modelProvider: modelProvider)
                .id("\(index)-\(retargetMode.rawValue)")
        }
    }
}

/// Renders the recorded skeleton as spheres + bones, driven by joint positions only.
@available(iOS 17.0, visionOS 1.0, macOS 15.0, *)
struct RawSkeletonView: View {
    let anim: ARKitBodyAnim?
    @State private var spheres: [ARKitBodyJoint: ModelEntity] = [:]
    @State private var bones: [ModelEntity] = []
    @State private var startDate = Date()

    var body: some View {
        RealityView { content in
            let container = Entity()
            container.scale = SIMD3<Float>(repeating: 0.35)
            content.add(container)
            var s: [ARKitBodyJoint: ModelEntity] = [:]
            let jm = SimpleMaterial(color: .cyan, isMetallic: false)
            for j in ARKitBodyJoint.allCases {
                let e = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [jm])
                container.addChild(e); s[j] = e
            }
            var b: [ModelEntity] = []
            let bm = SimpleMaterial(color: .white, isMetallic: false)
            for _ in ARKitBodyJoint.allCases {
                let e = ModelEntity(mesh: .generateBox(size: [0.012, 1, 0.012]), materials: [bm])
                container.addChild(e); b.append(e)
            }
            spheres = s; bones = b
        }
        .overlay {
            TimelineView(.animation) { timeline in
                Color.clear.onChange(of: timeline.date) { _, date in update(date) }
            }
            .allowsHitTesting(false)
        }
        .onAppear { startDate = Date() }
    }

    private func update(_ date: Date) {
        guard let anim, anim.duration > 0, !spheres.isEmpty else { return }
        let t = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: anim.duration)
        guard let frame = anim.frame(at: t) else { return }
        let positions = frame.jointWorldPositions()
        let hips = positions[.hips] ?? .zero
        for (j, e) in spheres {
            if let p = positions[j] { e.position = p - hips }
        }
        for (i, j) in ARKitBodyJoint.allCases.enumerated() where i < bones.count {
            let bone = bones[i]
            guard let parent = j.parent, let a = positions[j], let b = positions[parent] else {
                bone.isEnabled = false; continue
            }
            let pa = a - hips, pb = b - hips
            let dir = pb - pa
            let len = simd_length(dir)
            guard len > 1e-5 else { bone.isEnabled = false; continue }
            bone.isEnabled = true
            bone.position = (pa + pb) / 2
            bone.scale = SIMD3<Float>(1, len, 1)
            bone.orientation = RealityKitSkeletonDriver.rotation(from: SIMD3<Float>(0, 1, 0), to: dir / len)
        }
    }
}

/// Loads a caller-supplied rig and drives it with the retarget for side-by-side comparison.
@available(iOS 17.0, visionOS 1.0, macOS 15.0, *)
struct RiggedRetargetView: View {
    let anim: ARKitBodyAnim
    let mode: RealityKitSkeletonDriver.Mode
    let modelProvider: () async -> ModelEntity?

    @State private var player: MoCapPlayer?
    @State private var driver: RealityKitSkeletonDriver?
    @State private var startDate = Date()

    var body: some View {
        RealityView { content in
            let root = Entity()
            root.scale = SIMD3<Float>(repeating: 0.35)
            content.add(root)
            guard let model = await modelProvider() else { return }
            stopAll(model)
            model.position = SIMD3<Float>(0, -0.9, 0)
            root.addChild(model)

            let d = RealityKitSkeletonDriver(model: model,
                                             retargeter: MixamoRetargeter(applyRootTranslation: false))
            d.mode = mode
            if let ref = anim.frames.first?.localJoints ?? anim.restPose { d.setRestPose(ref) }
            let p = MoCapPlayer(anim: anim); p.play()
            driver = d; player = p
        }
        .overlay {
            TimelineView(.animation) { timeline in
                Color.clear.onChange(of: timeline.date) { _, date in
                    guard let player, let driver else { return }
                    player.advance(to: date)
                    if let f = player.currentFrame { driver.apply(f) }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func stopAll(_ e: Entity) {
        var stack = [e]
        while let x = stack.popLast() { x.stopAllAnimations(); stack.append(contentsOf: x.children) }
    }
}
#endif
