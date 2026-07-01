import SwiftUI
import DicyaninLabsMoCapRecording

struct RecorderRootView: View {
    @StateObject private var vm = RecorderViewModel()
    @State private var shareURL: URL?
    @State private var previewAnim: ARKitBodyAnim?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ARBodyPreview(session: vm.capture.session)
                    .ignoresSafeArea()

                if !vm.isBodyTrackingSupported {
                    Text("Body tracking not supported on this device.")
                        .font(.headline)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }

                controls
            }
            .navigationTitle("MoCap Recorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Library") { LibraryView(vm: vm, shareURL: $shareURL, previewAnim: $previewAnim) }
                }
            }
        }
        .onAppear { vm.startSession() }
        .onDisappear { vm.pauseSession() }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        .sheet(item: $previewAnim) { anim in
            NavigationStack {
                MoCapWirePlayerView(anim: anim)
                    .background(Color.black)
                    .navigationTitle(anim.name)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Label("\(vm.frameCount) frames", systemImage: "square.stack.3d.up")
                Spacer()
                Text(String(format: "%.1fs", vm.elapsed)).monospacedDigit()
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())

            Button(action: vm.toggleRecording) {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4).frame(width: 74, height: 74)
                    RoundedRectangle(cornerRadius: vm.isRecording ? 6 : 30)
                        .fill(.red)
                        .frame(width: vm.isRecording ? 32 : 58, height: vm.isRecording ? 32 : 58)
                        .animation(.easeInOut(duration: 0.2), value: vm.isRecording)
                }
            }
            .disabled(!vm.isBodyTrackingSupported)
        }
        .padding(.bottom, 24)
    }
}

struct LibraryView: View {
    @ObservedObject var vm: RecorderViewModel
    @Binding var shareURL: URL?
    @Binding var previewAnim: ARKitBodyAnim?

    var body: some View {
        List {
            if vm.savedFiles.isEmpty {
                Text("No recordings yet.").foregroundStyle(.secondary)
            }
            ForEach(vm.savedFiles, id: \.self) { url in
                HStack {
                    VStack(alignment: .leading) {
                        Text(url.deletingPathExtension().lastPathComponent)
                        Text(".\(url.pathExtension)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        previewAnim = vm.loadAnim(url)
                    } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    Button {
                        shareURL = url
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                }
                .swipeActions {
                    Button(role: .destructive) { vm.delete(url) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Library")
        .onAppear { vm.refreshSavedFiles() }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension URL: Identifiable { public var id: String { absoluteString } }
extension ARKitBodyAnim: Identifiable { public var id: String { name } }
