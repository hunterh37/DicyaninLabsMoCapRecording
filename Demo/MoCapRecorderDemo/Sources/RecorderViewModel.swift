import Foundation
import Combine
import DicyaninLabsMoCapRecording

@MainActor
final class RecorderViewModel: ObservableObject {
    let recorder = MoCapRecorder(frameRate: 60)
    let capture: ARBodyCaptureSession

    @Published var isRecording = false
    @Published var frameCount = 0
    @Published var elapsed: TimeInterval = 0
    @Published var savedFiles: [URL] = []
    @Published var lastError: String?
    @Published var isBodyTrackingSupported = false
    @Published var liveBody: LiveBodySnapshot?
    @Published var bodyDetected = false
    @Published var leftHandDetected = false
    @Published var rightHandDetected = false
    @Published var liveLeftHand: LiveHandSnapshot?
    @Published var liveRightHand: LiveHandSnapshot?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        capture = ARBodyCaptureSession(recorder: recorder)
        isBodyTrackingSupported = capture.isSupported
        capture.onLiveBody = { [weak self] snapshot in
            Task { @MainActor in
                self?.liveBody = snapshot
                self?.bodyDetected = true
            }
        }
        capture.onLiveHands = { [weak self] left, right in
            Task { @MainActor in
                self?.leftHandDetected = left != nil
                self?.rightHandDetected = right != nil
                self?.liveLeftHand = left
                self?.liveRightHand = right
            }
        }
        recorder.$isRecording.receive(on: RunLoop.main).sink { [weak self] in self?.isRecording = $0 }.store(in: &cancellables)
        recorder.$frameCount.receive(on: RunLoop.main).sink { [weak self] in self?.frameCount = $0 }.store(in: &cancellables)
        recorder.$elapsed.receive(on: RunLoop.main).sink { [weak self] in self?.elapsed = $0 }.store(in: &cancellables)
        refreshSavedFiles()
    }

    func startSession() { capture.run() }
    func pauseSession() { capture.pause() }

    func toggleRecording() {
        if recorder.isRecording {
            let anim = recorder.stop()
            save(anim)
        } else {
            let stamp = Int(Date().timeIntervalSince1970)
            recorder.start(name: "take-\(stamp)")
        }
    }

    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func save(_ anim: ARKitBodyAnim) {
        let url = documentsDir.appendingPathComponent("\(anim.name).\(ARKitBodyAnim.fileExtension)")
        do {
            try anim.write(to: url)
            refreshSavedFiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshSavedFiles() {
        let ext = ARKitBodyAnim.fileExtension
        let files = (try? FileManager.default.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: nil)) ?? []
        savedFiles = files.filter { $0.pathExtension == ext }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshSavedFiles()
    }

    func loadAnim(_ url: URL) -> ARKitBodyAnim? {
        try? ARKitBodyAnim.read(from: url)
    }
}
