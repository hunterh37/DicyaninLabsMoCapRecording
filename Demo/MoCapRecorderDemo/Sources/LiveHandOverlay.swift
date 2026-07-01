import SwiftUI
import UIKit
import DicyaninLabsMoCapRecording

/// Draws Vision's live hand-pose points on top of the camera feed, projected through
/// ARKit's camera just like ``LiveSkeletonOverlay`` does for the body. The hand's root is
/// anchored to the body skeleton's real hand joint, so this projects to the right place on
/// the arm even though the exact finger shape is only an approximation (Vision has no
/// depth, so finger curl/orientation can't be fully recovered from a single 2D detection).
struct LiveHandOverlay: View {
    let left: LiveHandSnapshot?
    let right: LiveHandSnapshot?

    private func orientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let left {
                    HandLines(snapshot: left, viewportSize: geo.size, orientation: orientation(),
                              jointColor: .yellow, boneColor: .orange)
                }
                if let right {
                    HandLines(snapshot: right, viewportSize: geo.size, orientation: orientation(),
                              jointColor: .cyan, boneColor: .blue)
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

private struct HandLines: View {
    let snapshot: LiveHandSnapshot
    let viewportSize: CGSize
    let orientation: UIInterfaceOrientation
    let jointColor: Color
    let boneColor: Color

    var body: some View {
        let points = snapshot.projectedPoints(viewportSize: viewportSize, orientation: orientation)
        ZStack {
            Path { path in
                for (a, b) in snapshot.bones {
                    guard let pa = points[a], let pb = points[b],
                          inside(pa), inside(pb) else { continue }
                    path.move(to: pa)
                    path.addLine(to: pb)
                }
            }
            .stroke(boneColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .shadow(color: .black.opacity(0.5), radius: 1)

            ForEach(Array(points.keys), id: \.self) { joint in
                if let p = points[joint], inside(p) {
                    Circle()
                        .fill(jointColor)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.white, lineWidth: 0.5))
                        .position(p)
                }
            }
        }
    }

    private func inside(_ p: CGPoint) -> Bool {
        p.x.isFinite && p.y.isFinite &&
        p.x >= -50 && p.y >= -50 && p.x <= viewportSize.width + 50 && p.y <= viewportSize.height + 50
    }
}
