import SwiftUI
import UIKit
import DicyaninLabsMoCapRecording

/// Draws detected body-anchor joints and the bone lines used for the animation,
/// projected onto the live camera feed.
struct LiveSkeletonOverlay: View {
    let snapshot: LiveBodySnapshot?

    private func orientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
    }

    var body: some View {
        GeometryReader { geo in
            if let snapshot {
                let pts = snapshot.projectedPoints(viewportSize: geo.size, orientation: orientation())
                ZStack {
                    Path { path in
                        for (a, b) in snapshot.bones {
                            guard let pa = pts[a], let pb = pts[b],
                                  inside(pa, geo.size), inside(pb, geo.size) else { continue }
                            path.move(to: pa)
                            path.addLine(to: pb)
                        }
                    }
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .shadow(color: .black.opacity(0.5), radius: 1)

                    ForEach(Array(pts.keys), id: \.self) { joint in
                        if let p = pts[joint], inside(p, geo.size) {
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1))
                                .position(p)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    private func inside(_ p: CGPoint, _ size: CGSize) -> Bool {
        p.x.isFinite && p.y.isFinite &&
        p.x >= -50 && p.y >= -50 && p.x <= size.width + 50 && p.y <= size.height + 50
    }
}
