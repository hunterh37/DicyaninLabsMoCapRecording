import Foundation
import simd

#if canImport(SwiftUI)
import SwiftUI

/// Computes 2D projected joint positions from a frame by walking the joint hierarchy
/// to accumulate world-space positions, then orthographically projecting onto a plane.
public enum WireProjection: Sendable {
    case frontXY   // project world X,Y (facing camera)
    case sideZY    // project world Z,Y (profile)
}

public struct SkeletonWirePose {
    public var points: [ARKitBodyJoint: CGPoint]
    public var bones: [(ARKitBodyJoint, ARKitBodyJoint)]

    public init(frame: ARKitBodyFrame, projection: WireProjection = .frontXY) {
        var world: [ARKitBodyJoint: simd_float4x4] = [:]
        // Joints are ordered so parents precede children in ARKitBodyJoint.allCases.
        for joint in ARKitBodyJoint.allCases {
            let local = frame.localTransform(joint) ?? matrix_identity_float4x4
            if let parent = joint.parent, let parentWorld = world[parent] {
                world[joint] = parentWorld * local
            } else {
                world[joint] = local
            }
        }
        var pts: [ARKitBodyJoint: CGPoint] = [:]
        for (joint, m) in world {
            let p = m.columns.3
            switch projection {
            case .frontXY: pts[joint] = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
            case .sideZY:  pts[joint] = CGPoint(x: CGFloat(p.z), y: CGFloat(p.y))
            }
        }
        self.points = pts
        self.bones = ARKitBodyJoint.allCases.compactMap { j in
            j.parent.map { (j, $0) }
        }
    }
}

/// A 2D wireframe skeleton view that animates a recorded body anim.
public struct SkeletonWireView: View {
    public var frame: ARKitBodyFrame
    public var projection: WireProjection
    public var jointColor: Color
    public var boneColor: Color

    public init(
        frame: ARKitBodyFrame,
        projection: WireProjection = .frontXY,
        jointColor: Color = .green,
        boneColor: Color = .white
    ) {
        self.frame = frame
        self.projection = projection
        self.jointColor = jointColor
        self.boneColor = boneColor
    }

    public var body: some View {
        GeometryReader { geo in
            let pose = SkeletonWirePose(frame: frame, projection: projection)
            let mapped = Self.fit(pose.points, in: geo.size)
            ZStack {
                Path { path in
                    for (a, b) in pose.bones {
                        guard let pa = mapped[a], let pb = mapped[b] else { continue }
                        path.move(to: pa)
                        path.addLine(to: pb)
                    }
                }
                .stroke(boneColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                ForEach(Array(mapped.keys), id: \.self) { joint in
                    if let p = mapped[joint] {
                        Circle()
                            .fill(jointColor)
                            .frame(width: 7, height: 7)
                            .position(p)
                    }
                }
            }
        }
    }

    /// Fit projected points into the view bounds with a margin, flipping Y for screen space.
    static func fit(_ points: [ARKitBodyJoint: CGPoint], in size: CGSize) -> [ARKitBodyJoint: CGPoint] {
        guard !points.isEmpty else { return [:] }
        let xs = points.values.map(\.x)
        let ys = points.values.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        let spanX = max(maxX - minX, 0.001)
        let spanY = max(maxY - minY, 0.001)
        let margin: CGFloat = 24
        let w = size.width - margin * 2
        let h = size.height - margin * 2
        let scale = min(w / spanX, h / spanY)
        let offsetX = margin + (w - spanX * scale) / 2
        let offsetY = margin + (h - spanY * scale) / 2
        var out: [ARKitBodyJoint: CGPoint] = [:]
        for (j, p) in points {
            let x = offsetX + (p.x - minX) * scale
            // Flip Y so +Y (up in world) maps to up on screen.
            let y = offsetY + (maxY - p.y) * scale
            out[j] = CGPoint(x: x, y: y)
        }
        return out
    }
}

/// A self-contained player view: ticks a ``MoCapPlayer`` and renders the wireframe.
public struct MoCapWirePlayerView: View {
    @StateObject private var player: MoCapPlayer
    public var projection: WireProjection

    public init(anim: ARKitBodyAnim, projection: WireProjection = .frontXY) {
        _player = StateObject(wrappedValue: MoCapPlayer(anim: anim))
        self.projection = projection
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let _ = player.advance(to: timeline.date)
            Group {
                if let frame = player.currentFrame {
                    SkeletonWireView(frame: frame, projection: projection)
                } else {
                    Text("No frames")
                }
            }
        }
        .onAppear { player.play() }
    }
}
#endif
