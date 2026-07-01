import Foundation
import simd

/// A packed 4x4 column-major transform, JSON/binary friendly.
public struct AnimTransform: Codable, Sendable, Equatable {
    public var m: [Float] // 16 floats, column-major

    public init(_ matrix: simd_float4x4) {
        m = [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    public init(m: [Float]) { self.m = m }

    public var matrix: simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(m[0], m[1], m[2], m[3]),
            SIMD4<Float>(m[4], m[5], m[6], m[7]),
            SIMD4<Float>(m[8], m[9], m[10], m[11]),
            SIMD4<Float>(m[12], m[13], m[14], m[15])
        )
    }

    public var translation: SIMD3<Float> {
        SIMD3<Float>(m[12], m[13], m[14])
    }
}

/// A single captured pose at a point in time.
public struct ARKitBodyFrame: Codable, Sendable {
    /// Seconds since the start of the recording.
    public var time: TimeInterval
    /// World transform of the body anchor (hips origin) at capture time.
    public var rootTransform: AnimTransform
    /// Local (parent-relative) joint transforms keyed by joint raw name.
    public var localJoints: [String: AnimTransform]

    public init(time: TimeInterval, rootTransform: AnimTransform, localJoints: [String: AnimTransform]) {
        self.time = time
        self.rootTransform = rootTransform
        self.localJoints = localJoints
    }

    public func localTransform(_ joint: ARKitBodyJoint) -> simd_float4x4? {
        localJoints[joint.rawValue]?.matrix
    }
}

/// The full `.arkitbodyanim` document. Serialized as JSON (optionally gzip-wrapped by callers).
public struct ARKitBodyAnim: Codable, Sendable {
    public static let fileExtension = "arkitbodyanim"
    public static let currentVersion = 1
    public static let magic = "DICYANIN_ARKITBODYANIM"

    public var magic: String
    public var version: Int
    public var name: String
    public var createdAt: Date
    /// Nominal capture rate in frames per second.
    public var frameRate: Double
    /// Skeleton this recording targets, in joint raw-name order.
    public var jointOrder: [String]
    /// ARKit neutral (rest / T-pose) local joint transforms, keyed by joint raw name.
    /// Required for correct delta retargeting onto a differently-bound rig (e.g. Mixamo):
    /// the motion applied to the target rig is `current * rest⁻¹`, so a joint that isn't
    /// moving relative to the ARKit rest leaves the target rig at its own bind pose.
    /// Optional for backward compatibility with clips recorded before this was captured.
    public var restPose: [String: AnimTransform]?
    public var frames: [ARKitBodyFrame]

    public var duration: TimeInterval { frames.last?.time ?? 0 }

    public init(
        name: String,
        createdAt: Date = Date(),
        frameRate: Double = 60,
        jointOrder: [String] = ARKitBodyJoint.allCases.map(\.rawValue),
        restPose: [String: AnimTransform]? = nil,
        frames: [ARKitBodyFrame] = []
    ) {
        self.magic = Self.magic
        self.version = Self.currentVersion
        self.name = name
        self.createdAt = createdAt
        self.frameRate = frameRate
        self.jointOrder = jointOrder
        self.restPose = restPose
        self.frames = frames
    }
}

public enum ARKitBodyAnimError: Error, LocalizedError {
    case badMagic
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .badMagic: return "Not a valid .arkitbodyanim file."
        case .unsupportedVersion(let v): return "Unsupported .arkitbodyanim version \(v)."
        }
    }
}

public extension ARKitBodyAnim {
    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    static func decode(_ data: Data) throws -> ARKitBodyAnim {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let anim = try dec.decode(ARKitBodyAnim.self, from: data)
        guard anim.magic == Self.magic else { throw ARKitBodyAnimError.badMagic }
        guard anim.version <= Self.currentVersion else {
            throw ARKitBodyAnimError.unsupportedVersion(anim.version)
        }
        return anim
    }

    func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> ARKitBodyAnim {
        try decode(try Data(contentsOf: url))
    }

    /// Nearest-frame sample at a given playback time.
    func frame(at time: TimeInterval) -> ARKitBodyFrame? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        return frames[lo]
    }
}
