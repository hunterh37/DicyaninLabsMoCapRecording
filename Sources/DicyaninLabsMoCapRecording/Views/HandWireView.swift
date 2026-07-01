import Foundation
import simd

#if canImport(SwiftUI)
import SwiftUI

/// 2D wireframe pose for a single recorded hand, projected the same way as
/// ``SkeletonWirePose`` but walking the finger hierarchy instead of the body.
public struct HandWirePose {
    public var points: [ARKitHandJoint: CGPoint]
    public var bones: [(ARKitHandJoint, ARKitHandJoint)]

    public init(handFrame: ARKitHandFrame, projection: WireProjection = .frontXY) {
        let world = handFrame.jointWorldTransforms()
        var pts: [ARKitHandJoint: CGPoint] = [:]
        for (joint, m) in world {
            let p = m.columns.3
            switch projection {
            case .frontXY: pts[joint] = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
            case .sideZY:  pts[joint] = CGPoint(x: CGFloat(p.z), y: CGFloat(p.y))
            }
        }
        self.points = pts
        self.bones = ARKitHandJoint.allCases.compactMap { j in j.parent.map { (j, $0) } }
    }
}

/// A 2D wireframe view of a single recorded hand pose. Fits itself into the view bounds
/// independently, so it's usable standalone or layered alongside ``SkeletonWireView``.
public struct HandWireView: View {
    public var handFrame: ARKitHandFrame
    public var projection: WireProjection
    public var jointColor: Color
    public var boneColor: Color

    public init(
        handFrame: ARKitHandFrame,
        projection: WireProjection = .frontXY,
        jointColor: Color = .yellow,
        boneColor: Color = .orange
    ) {
        self.handFrame = handFrame
        self.projection = projection
        self.jointColor = jointColor
        self.boneColor = boneColor
    }

    public var body: some View {
        GeometryReader { geo in
            let pose = HandWirePose(handFrame: handFrame, projection: projection)
            let mapped = Self.fit(pose.points, in: geo.size)
            ZStack {
                Path { path in
                    for (a, b) in pose.bones {
                        guard let pa = mapped[a], let pb = mapped[b] else { continue }
                        path.move(to: pa)
                        path.addLine(to: pb)
                    }
                }
                .stroke(boneColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                ForEach(Array(mapped.keys), id: \.self) { joint in
                    if let p = mapped[joint] {
                        Circle()
                            .fill(jointColor)
                            .frame(width: 5, height: 5)
                            .position(p)
                    }
                }
            }
        }
    }

    static func fit(_ points: [ARKitHandJoint: CGPoint], in size: CGSize) -> [ARKitHandJoint: CGPoint] {
        guard !points.isEmpty else { return [:] }
        let xs = points.values.map(\.x)
        let ys = points.values.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        let spanX = max(maxX - minX, 0.001)
        let spanY = max(maxY - minY, 0.001)
        let margin: CGFloat = 12
        let w = size.width - margin * 2
        let h = size.height - margin * 2
        let scale = min(w / spanX, h / spanY)
        let offsetX = margin + (w - spanX * scale) / 2
        let offsetY = margin + (h - spanY * scale) / 2
        var out: [ARKitHandJoint: CGPoint] = [:]
        for (j, p) in points {
            let x = offsetX + (p.x - minX) * scale
            let y = offsetY + (maxY - p.y) * scale
            out[j] = CGPoint(x: x, y: y)
        }
        return out
    }
}

/// Self-contained player: samples an ``ARKitBodyAnim`` off the animation clock and renders
/// the body wireframe with any recorded hand data overlaid in the corners, so clips that
/// carry finger data show it the same way body-only clips show the skeleton.
public struct MoCapHandsWirePlayerView: View {
    public let anim: ARKitBodyAnim
    public var projection: WireProjection
    @State private var startDate = Date()

    public init(anim: ARKitBodyAnim, projection: WireProjection = .frontXY) {
        self.anim = anim
        self.projection = projection
    }

    public var body: some View {
        Group {
            if anim.frames.isEmpty || anim.duration <= 0 {
                staticOrEmpty
            } else {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSince(startDate)
                        .truncatingRemainder(dividingBy: anim.duration)
                    if let frame = anim.frame(at: t) {
                        content(for: frame)
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .onAppear { startDate = Date() }
    }

    @ViewBuilder private var staticOrEmpty: some View {
        if let frame = anim.frames.first {
            content(for: frame)
        } else {
            Text("No frames")
        }
    }

    @ViewBuilder private func content(for frame: ARKitBodyFrame) -> some View {
        ZStack {
            SkeletonWireView(frame: frame, projection: projection)
            if let left = frame.leftHand {
                HandWireView(handFrame: left, jointColor: .yellow, boneColor: .orange)
                    .frame(width: 90, height: 90)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
            }
            if let right = frame.rightHand {
                HandWireView(handFrame: right, jointColor: .yellow, boneColor: .orange)
                    .frame(width: 90, height: 90)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
            }
        }
    }
}
#endif
