import SwiftUI
import AVKit
import QuickLook
import Photos
import UIKit

struct FileBrowserTabView: View {
    @State private var rootURL: URL?
    @State private var currentURL: URL?
    @State private var items: [KdownloaderFileItem] = []
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showCreateFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: KdownloaderFileItem?
    @State private var renameText = ""
    @State private var moveTarget: KdownloaderFileItem?
    @State private var playerURL: KdownloaderIdentifiedURL?
    @State private var previewURL: KdownloaderIdentifiedURL?
    @State private var sharePayload: SharePayload?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "folder", description: Text("Downloaded files will appear here."))
                } else {
                    List(items) { item in
                        fileRow(item)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(currentURL?.lastPathComponent ?? "Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        openParentFolder()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(!canOpenParent)

                    Button {
                        currentURL = rootURL
                        refresh()
                    } label: {
                        Image(systemName: "house")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button {
                        newFolderName = ""
                        showCreateFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .onAppear(perform: setupIfNeeded)
            .sheet(isPresented: $showCreateFolder) {
                folderNameSheet(
                    title: "New Folder",
                    text: $newFolderName,
                    actionTitle: "Create",
                    action: createFolder
                )
            }
            .sheet(item: $renameTarget) { item in
                folderNameSheet(
                    title: "Rename",
                    text: $renameText,
                    actionTitle: "Save",
                    action: { rename(item) }
                )
            }
            .sheet(item: $moveTarget) { item in
                MoveDestinationPicker(rootURL: rootURL, excludedURL: item.url) { destination in
                    move(item, to: destination)
                }
            }
            .sheet(item: $playerURL) { item in
                NavigationStack {
                    VideoPlayer(player: AVPlayer(url: item.url))
                        .ignoresSafeArea()
                        .navigationTitle(item.url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                Button {
                                    share(item.url)
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }

                                if canSaveToPhotos(item.url) {
                                    Button {
                                        saveFileToPhotos(item.url)
                                    } label: {
                                        Image(systemName: "photo.badge.plus")
                                    }
                                }
                            }
                        }
                }
            }
            .sheet(item: $previewURL) { item in
                QuickLookPreview(url: item.url)
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(activityItems: payload.activityItems)
            }
            .alert("Files", isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    private func fileRow(_ item: KdownloaderFileItem) -> some View {
        HStack(spacing: 8) {
            Button {
                open(item)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.iconName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(item.isDirectory ? .blue : .secondary)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(item.detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: item.isDirectory ? "chevron.right" : "play.circle")
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                fileActions(for: item)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
        }
        .contextMenu {
            fileActions(for: item)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label("Delete", systemImage: "xmark")
            }
            .tint(.red)
        }
    }

    @ViewBuilder
    private func fileActions(for item: KdownloaderFileItem) -> some View {
        if !item.isDirectory, item.isPlayable {
            Button {
                playerURL = KdownloaderIdentifiedURL(url: item.url)
            } label: {
                Label("Play", systemImage: "play.circle")
            }
        }

        Button {
            share(item.url)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        if !item.isDirectory, item.canSaveToPhotos {
            Button {
                saveFileToPhotos(item.url)
            } label: {
                Label("Save to Photos", systemImage: "photo.badge.plus")
            }
        }

        Button {
            renameText = item.name
            renameTarget = item
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            moveTarget = item
        } label: {
            Label("Move", systemImage: "folder")
        }

        Button(role: .destructive) {
            delete(item)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func share(_ url: URL) {
        sharePayload = SharePayload(activityItems: [url])
    }

    private func canSaveToPhotos(_ url: URL) -> Bool {
        KdownloaderFileItem(url: url).canSaveToPhotos
    }

    private var canOpenParent: Bool {
        guard let rootURL, let currentURL else { return false }
        return currentURL.standardizedFileURL.path != rootURL.standardizedFileURL.path
    }

    private func setupIfNeeded() {
        guard rootURL == nil else {
            refresh()
            return
        }

        do {
            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try FileManager.default.createDirectory(at: documentsURL.appendingPathComponent("Saved", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: documentsURL.appendingPathComponent("Temp", isDirectory: true), withIntermediateDirectories: true)
            rootURL = documentsURL
            currentURL = documentsURL
            refresh()
        } catch {
            present(error)
        }
    }

    private func refresh() {
        guard let currentURL else { return }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            items = urls
                .map(KdownloaderFileItem.init)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory && !rhs.isDirectory
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        } catch {
            present(error)
        }
    }

    private func open(_ item: KdownloaderFileItem) {
        if item.isDirectory {
            currentURL = item.url
            refresh()
            return
        }

        if item.isPlayable {
            playerURL = KdownloaderIdentifiedURL(url: item.url)
        } else {
            previewURL = KdownloaderIdentifiedURL(url: item.url)
        }
    }

    private func openParentFolder() {
        guard canOpenParent, let currentURL else { return }
        self.currentURL = currentURL.deletingLastPathComponent()
        refresh()
    }

    private func createFolder() {
        guard let currentURL else { return }
        do {
            let name = try validatedFileName(newFolderName)
            let destination = uniqueDestination(for: currentURL.appendingPathComponent(name, isDirectory: true))
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            showCreateFolder = false
            refresh()
        } catch {
            present(error)
        }
    }

    private func rename(_ item: KdownloaderFileItem) {
        do {
            let name = try validatedFileName(renameText)
            let destination = uniqueDestination(for: item.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: item.isDirectory))
            try FileManager.default.moveItem(at: item.url, to: destination)
            renameTarget = nil
            refresh()
        } catch {
            present(error)
        }
    }

    private func move(_ item: KdownloaderFileItem, to destinationFolder: URL) {
        do {
            let destination = uniqueDestination(for: destinationFolder.appendingPathComponent(item.name, isDirectory: item.isDirectory))
            try FileManager.default.moveItem(at: item.url, to: destination)
            moveTarget = nil
            refresh()
        } catch {
            present(error)
        }
    }

    private func delete(_ item: KdownloaderFileItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
            refresh()
        } catch {
            present(error)
        }
    }

    private func saveFileToPhotos(_ url: URL) {
        Task {
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else {
                await presentMessage("Photo library permission was not granted.")
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let item = KdownloaderFileItem(url: url)
                    if item.isPhotoVideo {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    } else if item.isPhotoImage {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }
                }
                await presentMessage("Saved to Photos.")
            } catch {
                await presentMessage("Could not save to Photos: \(error.localizedDescription)")
            }
        }
    }

    private func validatedFileName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
            throw NSError(domain: "Kdownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid file name."])
        }
        return name
    }

    private func uniqueDestination(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for index in 1...999 {
            let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
    }

    private func folderNameSheet(title: String, text: Binding<String>, actionTitle: String, action: @escaping () -> Void) -> some View {
        NavigationStack {
            Form {
                TextField("Name", text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showCreateFolder = false
                        renameTarget = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, action: action)
                }
            }
        }
        .presentationDetents([.height(180)])
    }

    private func present(_ error: Error) {
        alertMessage = error.localizedDescription
        showAlert = true
    }

    @MainActor
    private func presentMessage(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

struct KdownloaderFileItem: Identifiable {
    let url: URL
    let id: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    init(url: URL) {
        self.url = url
        self.id = url.path
        self.name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        self.isDirectory = values?.isDirectory == true
        self.size = Int64(values?.fileSize ?? 0)
        self.modified = values?.contentModificationDate
    }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        if isPlayable { return "play.rectangle.fill" }
        return "doc.fill"
    }

    var detailText: String {
        if isDirectory {
            return "Folder"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var isPlayable: Bool {
        let playableExtensions: Set<String> = ["mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "webm", "mkv"]
        return playableExtensions.contains(url.pathExtension.lowercased())
    }

    var isPhotoImage: Bool {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heif", "heic"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    var isPhotoVideo: Bool {
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    var canSaveToPhotos: Bool {
        !isDirectory && (isPhotoImage || isPhotoVideo)
    }
}

struct KdownloaderIdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MoveDestinationPicker: View {
    let rootURL: URL?
    let excludedURL: URL
    let onMove: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folders: [URL] = []

    var body: some View {
        NavigationStack {
            List(folders, id: \.path) { folder in
                Button {
                    onMove(folder)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(folderDisplayName(folder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .navigationTitle("Move To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear(perform: loadFolders)
        }
    }

    private func loadFolders() {
        guard let rootURL else { return }
        var result = [rootURL]
        if let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                guard !isExcluded(url) else { continue }
                result.append(url)
            }
        }
        folders = result
    }

    private func isExcluded(_ url: URL) -> Bool {
        let candidatePath = url.standardizedFileURL.path
        let excludedPath = excludedURL.standardizedFileURL.path
        return candidatePath == excludedPath || candidatePath.hasPrefix(excludedPath + "/")
    }

    private func folderDisplayName(_ folder: URL) -> String {
        guard let rootURL else { return folder.lastPathComponent }
        let rootPath = rootURL.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        if path == rootPath {
            return "Documents"
        }
        return path.replacingOccurrences(of: rootPath + "/", with: "")
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
