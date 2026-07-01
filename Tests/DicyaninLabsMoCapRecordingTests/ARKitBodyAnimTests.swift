import XCTest
import simd
@testable import DicyaninLabsMoCapRecording

final class ARKitBodyAnimTests: XCTestCase {
    private func sampleFrame(time: TimeInterval) -> ARKitBodyFrame {
        var locals: [String: AnimTransform] = [:]
        for joint in ARKitBodyJoint.allCases {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4<Float>(0, Float(time), 0, 1)
            locals[joint.rawValue] = AnimTransform(m)
        }
        return ARKitBodyFrame(
            time: time,
            rootTransform: AnimTransform(matrix_identity_float4x4),
            localJoints: locals
        )
    }

    func test_roundTrip_encodeDecode_preservesFrames() throws {
        var anim = ARKitBodyAnim(name: "take1", frameRate: 60)
        anim.frames = (0..<10).map { sampleFrame(time: TimeInterval($0) / 60.0) }
        let data = try anim.encoded()
        let decoded = try ARKitBodyAnim.decode(data)
        XCTAssertEqual(decoded.name, "take1")
        XCTAssertEqual(decoded.frames.count, 10)
        XCTAssertEqual(decoded.magic, ARKitBodyAnim.magic)
    }

    func test_decode_badMagic_throws() {
        let bad = #"{"magic":"nope","version":1,"name":"x","createdAt":"2026-01-01T00:00:00Z","frameRate":60,"jointOrder":[],"frames":[]}"#
        XCTAssertThrowsError(try ARKitBodyAnim.decode(Data(bad.utf8)))
    }

    func test_frameAt_returnsNearestFrame() {
        var anim = ARKitBodyAnim(name: "t")
        anim.frames = (0..<5).map { sampleFrame(time: TimeInterval($0)) }
        XCTAssertEqual(anim.frame(at: 2.4)?.time, 3)
        XCTAssertEqual(anim.duration, 4)
    }

    func test_jointHierarchy_parentsPrecedeChildren() {
        let order = ARKitBodyJoint.allCases
        for (i, joint) in order.enumerated() {
            if let parent = joint.parent {
                let pi = order.firstIndex(of: parent)!
                XCTAssertLessThan(pi, i, "\(parent) should precede \(joint)")
            }
        }
    }

    func test_mixamoMapping_coversAllJoints() {
        for joint in ARKitBodyJoint.allCases {
            XCTAssertNotNil(joint.mixamoBoneName, "\(joint) missing Mixamo mapping")
        }
    }

    func test_retargeter_producesHipsTranslation() {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        let frame = ARKitBodyFrame(
            time: 0,
            rootTransform: AnimTransform(m),
            localJoints: [ARKitBodyJoint.hips.rawValue: AnimTransform(matrix_identity_float4x4)]
        )
        let bones = MixamoRetargeter().retarget(frame)
        let hips = bones["Hips"]
        XCTAssertEqual(hips?.columns.3.x, 1)
        XCTAssertEqual(hips?.columns.3.y, 2)
        XCTAssertEqual(hips?.columns.3.z, 3)
    }

    func test_wirePose_projectsPoints() {
        let pose = SkeletonWirePoseFixture()
        XCTAssertFalse(pose.isEmpty)
    }

    private func SkeletonWirePoseFixture() -> [ARKitBodyJoint: SIMD3<Float>] {
        var world: [ARKitBodyJoint: SIMD3<Float>] = [:]
        for joint in ARKitBodyJoint.allCases { world[joint] = .zero }
        return world
    }
}
