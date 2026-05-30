//
//  ContentView+DownloadFlow.swift
//  Palladium
//

import SwiftUI
import Foundation
import OSLog
import UIKit

extension ContentView {
    var shareSheetDefaultPreset: DownloadPreset {
        shareSheetDownloadMode.preset ?? .autoVideo
    }

    var shareSheetModePickerSheet: some View {
        VStack(spacing: 20) {
            Text("download.mode.sheet.title")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.top)

            Text("download.mode.sheet.subtitle")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 14) {
                shareSheetModeButton(
                    title: String(localized: "download.preset.video"),
                    subtitle: String(localized: "download.mode.video.help"),
                    icon: "wand.and.stars",
                    color: .blue,
                    preset: .autoVideo
                )
                shareSheetModeButton(
                    title: String(localized: "download.mode.audio.title"),
                    subtitle: String(localized: "download.mode.audio.help"),
                    icon: "music.note",
                    color: .green,
                    preset: .audio
                )
                shareSheetModeButton(
                    title: String(localized: "download.mode.mute.title"),
                    subtitle: String(localized: "download.mode.mute.help"),
                    icon: "speaker.slash",
                    color: .orange,
                    preset: .mute
                )
                shareSheetModeButton(
                    title: String(localized: "common.custom"),
                    subtitle: String(localized: "download.mode.custom.help"),
                    icon: "slider.horizontal.3",
                    color: .indigo,
                    preset: .custom
                )
            }
            .padding(.horizontal)

            Button(action: {
                showShareSheetDownloadPicker = false
                shareSheetURL = ""
            }) {
                Text("common.cancel")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }

    func shareSheetModeButton(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        preset: DownloadPreset
    ) -> some View {
        Button(action: {
            handleShareSheetModeSelection(preset)
        }) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(shareSheetDefaultPreset == preset ? color.opacity(0.55) : .clear, lineWidth: 1)
            )
            .cornerRadius(10)
        }
    }

    func handleShareSheetModeSelection(_ preset: DownloadPreset) {
        let sharedLink = shareSheetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        showShareSheetDownloadPicker = false
        shareSheetURL = ""
        guard !sharedLink.isEmpty else { return }
        startDownloadFromSharedURL(sharedLink, preset: preset)
    }

    func startDownloadFromSharedURL(_ sharedLink: String, preset: DownloadPreset) {
        selectedTab = .download
        urlText = sharedLink
        appendConsoleText("[palladium] starting shared-link download preset=\(preset.rawValue)\n")
        runDownloadFlow(urlOverride: sharedLink, presetOverride: preset)
    }

    func handlePastedURL(_ pastedURL: String) {
        guard autoDownloadOnPaste else { return }
        if isRunning {
            appendConsoleText("[palladium] paste detected while download is already running; queued\n")
            enqueueDownloadRequest(
                url: pastedURL,
                preset: selectedPreset,
                afterDownloadBehavior: afterDownloadBehavior,
                outputTitleHint: nil
            )
            return
        }
        appendConsoleText("[palladium] auto download started from pasted url\n")
        runDownloadFlow(urlOverride: pastedURL, presetOverride: selectedPreset)
    }

    func enqueueDownloadRequest(
        url: String,
        preset: DownloadPreset,
        afterDownloadBehavior: AfterDownloadBehavior,
        outputTitleHint: String?
    ) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        let progressItemID = UUID()
        let displayName = queuedDownloadDisplayName(url: trimmedURL, titleHint: outputTitleHint)
        queuedDownloadRequests.append(
            QueuedDownloadRequest(
                progressItemID: progressItemID,
                url: trimmedURL,
                preset: preset,
                afterDownloadBehavior: afterDownloadBehavior,
                outputTitleHint: outputTitleHint
            )
        )
        downloadProgressItems.append(
            DownloadProgressItem(
                id: progressItemID,
                fileName: displayName,
                detailText: "Waiting",
                state: .queued
            )
        )
        selectedTab = .download
        statusText = isRunning ? "running" : "queued"
        progressText = "Queued \(queuedDownloadRequests.count) download(s)"
        appendConsoleText("[palladium] queued download: \(trimmedURL)\n")
        persistDownloadSessionState()
        startNextQueuedDownloadIfPossible()
    }

    func startNextQueuedDownloadIfPossible() {
        guard !isRunning, !isPackageRunning, !isDownloadPaused else { return }
        guard !showDownloadActionSheet, !showAlert, !reopenDownloadActionAfterAlert else { return }
        guard !queuedDownloadRequests.isEmpty else { return }
        let next = queuedDownloadRequests.removeFirst()
        appendConsoleText("[palladium] starting queued download: \(next.url)\n")
        runDownloadFlow(
            urlOverride: next.url,
            presetOverride: next.preset,
            afterDownloadOverride: next.afterDownloadBehavior,
            outputTitleHint: next.outputTitleHint,
            queuedProgressItemID: next.progressItemID
        )
    }

    private func queuedDownloadDisplayName(url: String, titleHint: String?) -> String {
        if let titleHint {
            let trimmedTitle = titleHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }
        }
        guard let parsedURL = URL(string: url) else { return url }
        if !parsedURL.lastPathComponent.isEmpty {
            return parsedURL.lastPathComponent
        }
        return parsedURL.host ?? url
    }

    func runDownloadFlow(
        urlOverride: String? = nil,
        presetOverride: DownloadPreset? = nil,
        afterDownloadOverride: AfterDownloadBehavior? = nil,
        outputTitleHint: String? = nil,
        resumeContext: DownloadResumeContext? = nil,
        queuedProgressItemID: UUID? = nil
    ) {
        let targetURL = (resumeContext?.url ?? urlOverride ?? urlText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetURL.isEmpty else { return }
        let isResumeRun = resumeContext != nil
        let isQueuedRun = queuedProgressItemID != nil
        if (isRunning || isPackageRunning || isDownloadPaused), !isResumeRun, !isQueuedRun {
            enqueueDownloadRequest(
                url: targetURL,
                preset: presetOverride ?? selectedPreset,
                afterDownloadBehavior: afterDownloadOverride ?? afterDownloadBehavior,
                outputTitleHint: outputTitleHint
            )
            return
        }
        guard !isRunning, !isPackageRunning else { return }

        if !isResumeRun && !isQueuedRun {
            consoleLogStore.clearAll()
        }
        downloadErrorText = nil
        completedDownloadResult = nil
        playlistProgress = nil
        if !isResumeRun && !isQueuedRun {
            downloadProgressItems = []
            activeDownloadProgressItemID = nil
            pausedDownloadContext = nil
        }
        isDownloadPaused = false

        if !isResumeRun && !isQueuedRun {
            do {
                let removedCount = try clearDownloadsDirectoryContents()
                appendConsoleText("[palladium] cleared downloads folder entries: \(removedCount)\n")
            } catch {
                appendConsoleText("[palladium] failed to clear downloads folder: \(error.localizedDescription)\n")
            }
        }

        let runOutputURL: URL
        do {
            if let resumeContext {
                runOutputURL = resumeContext.runOutputURL
                try FileManager.default.createDirectory(at: runOutputURL, withIntermediateDirectories: true)
                appendConsoleText("[palladium] resuming in folder: \(runOutputURL.lastPathComponent)\n")
            } else {
                runOutputURL = try makeDownloadRunDirectory()
                appendConsoleText("[palladium] run output folder: \(runOutputURL.lastPathComponent)\n")
            }
        } catch {
            appendConsoleText("[palladium] failed to create run output folder: \(error.localizedDescription)\n")
            downloadErrorText = String(localized: "download.error.prepare_folder")
            progressText = String(localized: "download.status.failed")
            return
        }

        isRunning = true
        syncIdleTimerDisabled()
        statusText = "running"
        progressText = String(localized: "download.status.running")
        downloadCancelRequested = false
        downloadPauseRequested = false
        lastDownloadProgressPercent = nil
        ffmpegProgressDurationSeconds = nil
        pendingDownloadProgressLine = ""
        isInstallingPackagesDuringDownload = false

        let logPipe = Pipe()
        let readHandle = logPipe.fileHandleForReading
        let writeFD = logPipe.fileHandleForWriting.fileDescriptor
        let liveLogFD: Int32? = writeFD
        let presetAtStartValue = resumeContext?.preset ?? presetOverride ?? selectedPreset
        let presetAtStart = presetAtStartValue.pythonValue
        let extraArgsAtStart = resolvedExtraArgsTextForDownload()
        if cloudflareModeEnabled {
            appendConsoleText("[palladium] cloudflare mode enabled: using generic impersonation\n")
        }
        let outputTitleHintAtStart = (resumeContext?.outputTitleHint ?? outputTitleHint)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let presetArgsJSONAtStart = buildPresetArgumentsJSON()
        let selectedAfterDownloadBehavior = resumeContext?.afterDownloadBehavior ?? afterDownloadOverride ?? afterDownloadBehavior
        let afterDownloadBehaviorAtStart: AfterDownloadBehavior = isQueuedRun && selectedAfterDownloadBehavior == .ask
            ? .saveToApplicationFolder
            : selectedAfterDownloadBehavior
        activeDownloadContext = DownloadResumeContext(
            url: targetURL,
            preset: presetAtStartValue,
            afterDownloadBehavior: afterDownloadBehaviorAtStart,
            outputTitleHint: outputTitleHintAtStart,
            runOutputURL: runOutputURL
        )
        persistDownloadSessionState()
        if let queuedProgressItemID {
            activeDownloadProgressItemID = queuedProgressItemID
            updateDownloadProgressItem(id: queuedProgressItemID) { item in
                item.state = .running
                item.detailText = String(localized: "download.status.running")
            }
            persistDownloadSessionState()
        }
        let linkHistoryEnabledAtStart = linkHistoryEnabled
        let downloadPlaylistAtStart = downloadPlaylist
        let downloadSubtitlesAtStart = downloadSubtitles
        let embedThumbnailAtStart = embedThumbnail
        let autoRetryFailedDownloadsAtStart = autoRetryFailedDownloads
        let downloadSpeedModeAtStart = downloadSpeedMode
        let subtitleLanguagePatternAtStart = resolvedSubtitleLanguagePattern
        let useCookiesAtStart = useCookies
        let cookieFilePathAtStart = useCookiesAtStart ? resolvedSelectedCookieFilePath() : nil
        var receivedPythonLiveOutput = false
        let liveLogDecoder = StreamingUTF8Decoder()
        let cancelMarker = makeCancelMarkerURL()
        cancelMarkerURL = cancelMarker
        FFmpegBridgeControl.setLiveLogFD(liveLogFD)
        if let cancelMarker {
            setenv("PALLADIUM_CANCEL_FILE", cancelMarker.path, 1)
            try? FileManager.default.removeItem(at: cancelMarker)
        } else {
            unsetenv("PALLADIUM_CANCEL_FILE")
        }

        readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            processLiveLogData(data, decoder: liveLogDecoder, didReceiveLiveOutput: &receivedPythonLiveOutput)
        }

        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Palladium download") {
            Task { @MainActor in
                appendConsoleText("[palladium] background time expired; pausing download for resume\n")
                downloadPauseRequested = true
                downloadCancelRequested = false
                progressText = "Pausing for background resume..."
                statusText = "pausing"
                requestActiveOperationCancellation()
                currentDownloadTask?.cancel()
                pendingDownloadProgressLine = ""
                ffmpegProgressDurationSeconds = nil
                isInstallingPackagesDuringDownload = false
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }
        }
        if backgroundTaskID != .invalid {
            appendConsoleText("[palladium] background download time requested\n")
        }

        let task = Task {
            let outcome = await PythonFlowRunner.executeDownloadFlow(
                url: targetURL,
                preset: presetAtStart,
                presetArgsJSON: presetArgsJSONAtStart,
                extraArgs: extraArgsAtStart,
                outputTitleHint: outputTitleHintAtStart ?? "",
                allowResume: isResumeRun,
                downloadPlaylist: downloadPlaylistAtStart,
                downloadSubtitles: downloadSubtitlesAtStart,
                embedThumbnail: embedThumbnailAtStart,
                autoRetryFailedDownloads: autoRetryFailedDownloadsAtStart,
                concurrentFragments: downloadSpeedModeAtStart.fragmentCount,
                httpChunkSize: downloadSpeedModeAtStart.httpChunkSize,
                subtitleLanguagePattern: subtitleLanguagePatternAtStart,
                cookieFilePath: cookieFilePathAtStart,
                runOutputDir: runOutputURL.path,
                liveLogFD: liveLogFD
            )

            FFmpegBridgeControl.setLiveLogFD(nil)
            unsetenv("PALLADIUM_CANCEL_FILE")
            readHandle.readabilityHandler = nil
            try? logPipe.fileHandleForWriting.close()
            drainLiveLogPipe(readHandle, decoder: liveLogDecoder, didReceiveLiveOutput: &receivedPythonLiveOutput)
            try? readHandle.close()
            let trailingChunk = liveLogDecoder.finish()
            await MainActor.run {
                if !trailingChunk.isEmpty {
                    receivedPythonLiveOutput = true
                    enqueueConsoleChunk(trailingChunk, trackProgress: true)
                }
                flushConsoleChunks()
            }
            if let cancelMarkerURL {
                try? FileManager.default.removeItem(at: cancelMarkerURL)
            }
            self.cancelMarkerURL = nil
            self.currentDownloadTask = nil

            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }

            let cancelWasRequested = downloadCancelRequested
            let pauseWasRequested = downloadPauseRequested
            isRunning = false
            syncIdleTimerDisabled()
            downloadCancelRequested = false
            downloadPauseRequested = false
            lastDownloadProgressPercent = nil
            ffmpegProgressDurationSeconds = nil
            pendingDownloadProgressLine = ""
            isInstallingPackagesDuringDownload = false

            if restoreDownloadDefaults {
                downloadPlaylist = defaultDownloadPlaylist
                downloadSubtitles = defaultDownloadSubtitles
                embedThumbnail = defaultEmbedThumbnail
                useCookies = defaultUseCookies
            }

            let finalResultKind = cancelWasRequested ? "cancelled" : (outcome.resultKind ?? outcome.statusText)
            statusText = finalResultKind
            playlistProgress = outcome.playlistProgress ?? playlistProgress
            if pauseWasRequested && finalResultKind == "cancelled" {
                isDownloadPaused = true
                pausedDownloadContext = activeDownloadContext
                progressText = "Paused"
                statusText = "paused"
                markUnfinishedDownloadProgressItems(.paused)
                showDownloadActionSheet = false
                completedDownloadResult = nil
                completedPhotosCompatibility = .checking
                reopenDownloadActionAfterAlert = false
                persistDownloadSessionState()
                return
            } else if finalResultKind == "cancelled" {
                progressText = String(localized: "download.status.cancelled")
                markDownloadProgressItems(.cancelled)
                activeDownloadContext = nil
                pausedDownloadContext = nil
                showDownloadActionSheet = false
                completedDownloadResult = nil
                completedPhotosCompatibility = .checking
                reopenDownloadActionAfterAlert = false
                persistDownloadSessionState()
            } else if finalResultKind == "partial" {
                progressText = String(localized: "download.status.partial")
                markUnfinishedDownloadProgressItems(.failed)
                persistDownloadSessionState()
            } else {
                progressText = finalResultKind == "success"
                    ? String(localized: "download.status.complete")
                    : String(localized: "download.status.failed")
                if finalResultKind == "success" {
                    markDownloadProgressItems(.completed)
                    activeDownloadContext = nil
                    pausedDownloadContext = nil
                } else {
                    markUnfinishedDownloadProgressItems(.failed)
                }
                persistDownloadSessionState()
            }
            if finalResultKind == "error" {
                downloadErrorText = downloadErrorDetails(from: outcome)
            } else {
                downloadErrorText = nil
            }
            appendBufferedConsoleOutputIfNeeded(outcome.outputText, receivedLiveOutput: receivedPythonLiveOutput)
            appendConsoleText("\n\(outcome.summaryText)\n")
            Self.logger.info("yt-dlp flow finished with status: \(finalResultKind, privacy: .public)")

            if (finalResultKind == "success" || finalResultKind == "partial"), !outcome.downloadedPaths.isEmpty {
                let resultTitle = extractHistoryTitle(
                    playlistTitle: outcome.playlistProgress?.title,
                    downloadedPaths: outcome.downloadedPaths,
                    primaryDownloadedPath: outcome.primaryDownloadedPath,
                    outputText: outcome.outputText
                )
                let result = CompletedDownloadResult(
                    items: outcome.downloadedPaths.map { URL(fileURLWithPath: $0) },
                    primaryMediaURL: outcome.primaryDownloadedPath.map { URL(fileURLWithPath: $0) },
                    folderURL: runOutputURL,
                    titleHint: resultTitle
                )
                if linkHistoryEnabledAtStart {
                    addLinkHistoryEntry(
                        url: targetURL,
                        presetRawValue: presetAtStart,
                        playlistTitle: outcome.playlistProgress?.title,
                        downloadedPaths: outcome.downloadedPaths,
                        primaryDownloadedPath: outcome.primaryDownloadedPath,
                        outputText: outcome.outputText
                    )
                }
                completedDownloadResult = result
                downloadErrorText = nil
                if let notificationTarget = result.notificationTargetURL {
                    notifyDownloadCompletionIfNeeded(fileURL: notificationTarget)
                }

                let needsPhotosCompatibilityCheck = afterDownloadBehaviorAtStart == .ask
                    || afterDownloadBehaviorAtStart.postDownloadAction == .saveToPhotos
                if needsPhotosCompatibilityCheck, let photosCandidateURL = result.photosCandidateURL {
                    completedPhotosCompatibility = .checking
                    completedPhotosCompatibility = await evaluatePhotosCompatibility(for: photosCandidateURL)
                } else {
                    completedPhotosCompatibility = .incompatible(String(localized: "photos.error.single_only"))
                }

                if afterDownloadBehaviorAtStart == .ask {
                    showDownloadActionSheet = true
                } else if afterDownloadBehaviorAtStart.postDownloadAction == .saveToPhotos {
                    if completedPhotosCompatibility.isCompatible {
                        handlePostDownloadAction(.saveToPhotos, for: result)
                    } else {
                        showDownloadActionSheet = true
                    }
                } else if let action = afterDownloadBehaviorAtStart.postDownloadAction {
                    handlePostDownloadAction(action, for: result)
                }
            } else if finalResultKind == "success" || finalResultKind == "partial" {
                downloadErrorText = String(localized: "download.error.no_files_found")
            }
            startNextQueuedDownloadIfPossible()
        }
        currentDownloadTask = task
    }

    func consumePendingShortcutDownloadRequestIfNeeded() {
        ShortcutDownloadRequestStore.clearStaleRequest()

        guard let request = ShortcutDownloadRequestStore.consumePendingRequest() else {
            return
        }
        guard lastConsumedShortcutRequestID != request.id else {
            return
        }

        lastConsumedShortcutRequestID = request.id
        runShortcutDownload(request)
    }

    func runShortcutDownload(_ request: PendingShortcutDownloadRequest) {
        let trimmedURL = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            appendConsoleText("[palladium] shortcut request ignored because url was empty\n")
            return
        }

        let preset = request.preset.downloadPreset
        let destinationBehavior: AfterDownloadBehavior = switch request.destination {
        case .appFolder:
            .saveToApplicationFolder
        case .photos:
            .saveToPhotos
        }

        selectedTab = .download
        urlText = trimmedURL
        selectedPreset = preset

        if isRunning || isPackageRunning {
            appendConsoleText("[palladium] shortcut request received while another operation is running; queued\n")
            enqueueDownloadRequest(
                url: trimmedURL,
                preset: preset,
                afterDownloadBehavior: destinationBehavior,
                outputTitleHint: nil
            )
            showTemporaryToast(String(localized: "shortcuts.toast.received"))
            return
        }

        appendConsoleText(
            "[palladium] running shortcut download preset=\(preset.rawValue) destination=\(request.destination.rawValue)\n"
        )
        runDownloadFlow(
            urlOverride: trimmedURL,
            presetOverride: preset,
            afterDownloadOverride: destinationBehavior
        )
    }

    func handleIncomingDownloadURL(_ incomingURL: URL) {
        guard ["palladium", "kdownloader"].contains(incomingURL.scheme?.lowercased() ?? ""),
              incomingURL.host?.lowercased() == "download" else {
            return
        }

        guard let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let linkItem = queryItems.first(where: { $0.name == "url" }),
              let sharedLink = linkItem.value,
              !sharedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendConsoleText("[palladium] url scheme received but missing url query param\n")
            return
        }

        selectedTab = .download
        urlText = sharedLink
        appendConsoleText("[palladium] app opened via url scheme. link: \(sharedLink)\n")

        if shareSheetDownloadMode == .ask {
            if isRunning || isPackageRunning || isDownloadPaused {
                enqueueDownloadRequest(
                    url: sharedLink,
                    preset: selectedPreset,
                    afterDownloadBehavior: afterDownloadBehavior,
                    outputTitleHint: nil
                )
                return
            }
            shareSheetURL = sharedLink
            showShareSheetDownloadPicker = true
            return
        }

        let presetToUse = shareSheetDownloadMode.preset ?? .autoVideo
        startDownloadFromSharedURL(sharedLink, preset: presetToUse)
    }

    func cancelDownloadFlow() {
        if isDownloadPaused {
            isDownloadPaused = false
            pausedDownloadContext = nil
            activeDownloadContext = nil
            markUnfinishedDownloadProgressItems(.cancelled)
            progressText = String(localized: "download.status.cancelled")
            statusText = "cancelled"
            persistDownloadSessionState()
            startNextQueuedDownloadIfPossible()
            return
        }
        guard isRunning else { return }
        downloadCancelRequested = true
        downloadPauseRequested = false
        requestActiveOperationCancellation()
        currentDownloadTask?.cancel()
        pendingDownloadProgressLine = ""
        ffmpegProgressDurationSeconds = nil
        isInstallingPackagesDuringDownload = false
        progressText = String(localized: "download.status.cancelling")
    }

    func pauseDownloadProgressItem(_ id: UUID) {
        guard activeDownloadProgressItemID == id else { return }
        pauseDownloadFlow()
    }

    func resumeDownloadProgressItem(_ id: UUID) {
        guard activeDownloadProgressItemID == id else { return }
        resumeDownloadFlow()
    }

    func cancelDownloadProgressItem(_ id: UUID) {
        if let item = downloadProgressItems.first(where: { $0.id == id }),
           item.state == .completed || item.state == .failed || item.state == .cancelled {
            downloadProgressItems.removeAll { $0.id == id }
            if activeDownloadProgressItemID == id {
                activeDownloadProgressItemID = nil
                activeDownloadContext = nil
            }
            persistDownloadSessionState()
            return
        }

        if let queuedIndex = queuedDownloadRequests.firstIndex(where: { $0.progressItemID == id }) {
            queuedDownloadRequests.remove(at: queuedIndex)
            downloadProgressItems.removeAll { $0.id == id }
            persistDownloadSessionState()
            return
        }

        guard activeDownloadProgressItemID == id else {
            downloadProgressItems.removeAll { $0.id == id }
            persistDownloadSessionState()
            return
        }

        cancelDownloadFlow()
    }

    func pauseDownloadFlow() {
        guard isRunning else { return }
        downloadPauseRequested = true
        downloadCancelRequested = false
        requestActiveOperationCancellation()
        currentDownloadTask?.cancel()
        pendingDownloadProgressLine = ""
        ffmpegProgressDurationSeconds = nil
        isInstallingPackagesDuringDownload = false
        progressText = "Pausing..."
        persistDownloadSessionState()
    }

    func resumeDownloadFlow() {
        guard isDownloadPaused, let pausedDownloadContext else { return }
        isDownloadPaused = false
        markUnfinishedDownloadProgressItems(.running)
        persistDownloadSessionState()
        runDownloadFlow(
            urlOverride: pausedDownloadContext.url,
            presetOverride: pausedDownloadContext.preset,
            afterDownloadOverride: pausedDownloadContext.afterDownloadBehavior,
            outputTitleHint: pausedDownloadContext.outputTitleHint,
            resumeContext: pausedDownloadContext
        )
    }

    private func resolvedExtraArgsTextForDownload() -> String {
        let trimmedExtraArgs = extraArgsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cloudflareModeEnabled else { return trimmedExtraArgs }
        let cloudflareArgs = #"--extractor-args "generic:impersonate""#
        guard !trimmedExtraArgs.isEmpty else { return cloudflareArgs }
        if trimmedExtraArgs.contains("generic:impersonate") {
            return trimmedExtraArgs
        }
        return "\(trimmedExtraArgs) \(cloudflareArgs)"
    }

    func updateProgress(from chunk: String) {
        let normalized = chunk
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let combined = pendingDownloadProgressLine + normalized
        guard !combined.isEmpty else { return }

        var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if combined.hasSuffix("\n") {
            pendingDownloadProgressLine = ""
        } else {
            pendingDownloadProgressLine = lines.popLast() ?? ""
        }

        for line in lines {
            updateProgressLine(line)
        }
    }

    func updateProgressLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !downloadCancelRequested else { return }

        if handlePlaylistProgressMarkerLine(trimmed) {
            return
        }

        if handlePackageInstallProgressLine(trimmed) {
            return
        }

        if trimmed.hasPrefix("[palladium][ffmpeg-progress] duration=") {
            ffmpegProgressDurationSeconds = parseFFmpegDuration(from: trimmed)
        } else if trimmed.hasPrefix("[palladium][ffmpeg-progress] time=") {
            updateActiveDownloadProgressForProcessing(trimmed)
            if let update = parseFFmpegProgressUpdate(from: trimmed) {
                if let progressPercent = update.percent {
                    lastDownloadProgressPercent = progressPercent
                    let clampedPercent = min(max(progressPercent, 0), 100)
                    let baseProcessingText = String(localized: "download.status.processing")
                    let percentText = String(format: "%.1f%%", locale: .current, clampedPercent)
                    if let speedText = update.speedText {
                        progressText = "\(baseProcessingText) \(percentText) (\(speedText))"
                    } else {
                        progressText = "\(baseProcessingText) \(percentText)"
                    }
                } else {
                    progressText = String(localized: "download.status.processing")
                }
            }
        } else if detailedProgressEnabled, shouldShowDetailedProgressLine(trimmed) {
            progressText = trimmed
        } else if trimmed.contains("[download]") {
            updateDownloadProgressList(from: trimmed)
            guard shouldAcceptDownloadProgressLine(trimmed) else { return }
            progressText = trimmed
        } else if trimmed.contains("[Merger]") {
            updateActiveDownloadProgressForProcessing(trimmed)
            progressText = trimmed
        } else if trimmed.contains("[VideoRemuxer]") {
            updateActiveDownloadProgressForProcessing(trimmed)
            if trimmed.localizedCaseInsensitiveContains("already is in target format") {
                progressText = String(localized: "download.status.merge_finished")
            } else {
                progressText = trimmed
            }
        } else if trimmed.contains("[palladium] downloaded files detected:")
            || trimmed.contains("[palladium] primary downloaded file:") {
            progressText = String(localized: "download.status.complete")
        } else if trimmed.contains("[palladium] downloaded file:") {
            progressText = String(localized: "download.status.complete")
        } else if trimmed.hasPrefix("[ExtractAudio]") {
            updateActiveDownloadProgressForProcessing(trimmed)
            progressText = trimmed
        } else if trimmed.hasPrefix("[palladium] running yt-dlp") {
            isInstallingPackagesDuringDownload = false
            progressText = String(localized: "download.status.running")
            lastDownloadProgressPercent = nil
        }
    }

    private func updateDownloadProgressList(from line: String) {
        if let destination = parseDownloadDestination(from: line) {
            let fileName = URL(fileURLWithPath: destination).lastPathComponent
            upsertActiveDownloadProgressItem(
                fileName: fileName.isEmpty ? destination : fileName,
                percent: nil,
                sizeText: nil,
                speedText: nil,
                etaText: nil,
                detailText: String(localized: "download.status.running"),
                state: .running
            )
            return
        }

        guard let percent = extractDownloadPercent(from: line) else {
            if line.localizedCaseInsensitiveContains("has already been downloaded") {
                updateActiveDownloadProgressItem { item in
                    item.percent = 100
                    item.state = .completed
                    item.detailText = String(localized: "download.status.complete")
                }
            }
            return
        }

        let metrics = parseDownloadMetrics(from: line)
        if activeDownloadProgressItemID == nil {
            upsertActiveDownloadProgressItem(
                fileName: fallbackActiveDownloadName(),
                percent: percent,
                sizeText: metrics.size,
                speedText: metrics.speed,
                etaText: metrics.eta,
                detailText: line,
                state: percent >= 100 ? .completed : .running
            )
            return
        }

        updateActiveDownloadProgressItem { item in
            item.percent = min(max(percent, 0), 100)
            if let size = metrics.size { item.sizeText = size }
            if let speed = metrics.speed { item.speedText = speed }
            if let eta = metrics.eta { item.etaText = eta }
            item.detailText = line
            item.state = percent >= 100 ? .completed : .running
        }
    }

    private func updateActiveDownloadProgressForProcessing(_ line: String) {
        guard activeDownloadProgressItemID != nil else { return }
        updateActiveDownloadProgressItem { item in
            if item.state != .completed {
                item.state = .processing
                item.detailText = line
            }
        }
    }

    private func upsertActiveDownloadProgressItem(
        fileName: String,
        percent: Double?,
        sizeText: String?,
        speedText: String?,
        etaText: String?,
        detailText: String?,
        state: DownloadProgressItem.State
    ) {
        if let existingIndex = downloadProgressItems.firstIndex(where: { $0.fileName == fileName }) {
            activeDownloadProgressItemID = downloadProgressItems[existingIndex].id
            updateActiveDownloadProgressItem { item in
                item.percent = percent ?? item.percent
                item.sizeText = sizeText ?? item.sizeText
                item.speedText = speedText ?? item.speedText
                item.etaText = etaText ?? item.etaText
                item.detailText = detailText ?? item.detailText
                item.state = state
            }
            return
        }

        if let activeDownloadProgressItemID,
           let activeIndex = downloadProgressItems.firstIndex(where: { $0.id == activeDownloadProgressItemID }),
           downloadProgressItems[activeIndex].percent == nil,
           downloadProgressItems[activeIndex].sizeText == nil,
           downloadProgressItems[activeIndex].speedText == nil,
           downloadProgressItems[activeIndex].etaText == nil,
           downloadProgressItems[activeIndex].state != .completed {
            downloadProgressItems[activeIndex].fileName = fileName
            updateActiveDownloadProgressItem { item in
                item.percent = percent ?? item.percent
                item.sizeText = sizeText ?? item.sizeText
                item.speedText = speedText ?? item.speedText
                item.etaText = etaText ?? item.etaText
                item.detailText = detailText ?? item.detailText
                item.state = state
            }
            return
        }

        let item = DownloadProgressItem(
            fileName: fileName,
            percent: percent,
            sizeText: sizeText,
            speedText: speedText,
            etaText: etaText,
            detailText: detailText,
            state: state
        )
        downloadProgressItems.append(item)
        activeDownloadProgressItemID = item.id
    }

    private func updateActiveDownloadProgressItem(_ update: (inout DownloadProgressItem) -> Void) {
        guard let activeDownloadProgressItemID,
              let index = downloadProgressItems.firstIndex(where: { $0.id == activeDownloadProgressItemID }) else {
            return
        }
        update(&downloadProgressItems[index])
    }

    private func updateDownloadProgressItem(id: UUID, _ update: (inout DownloadProgressItem) -> Void) {
        guard let index = downloadProgressItems.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&downloadProgressItems[index])
    }

    private func markDownloadProgressItems(_ state: DownloadProgressItem.State) {
        for index in downloadProgressItems.indices {
            let currentState = downloadProgressItems[index].state
            if currentState == .queued || currentState == .failed || currentState == .cancelled {
                continue
            }
            if currentState == .completed && state != .completed {
                continue
            }
            downloadProgressItems[index].state = state
            if state == .completed {
                downloadProgressItems[index].percent = 100
                downloadProgressItems[index].etaText = nil
                downloadProgressItems[index].detailText = String(localized: "download.status.complete")
            }
        }
    }

    private func markUnfinishedDownloadProgressItems(_ state: DownloadProgressItem.State) {
        for index in downloadProgressItems.indices {
            let currentState = downloadProgressItems[index].state
            guard currentState != .completed else { continue }
            guard currentState != .queued else { continue }
            guard currentState != .failed else { continue }
            guard currentState != .cancelled else { continue }
            downloadProgressItems[index].state = state
            switch state {
            case .paused:
                downloadProgressItems[index].detailText = "Paused"
            case .failed:
                downloadProgressItems[index].detailText = String(localized: "download.status.failed")
            case .cancelled:
                downloadProgressItems[index].detailText = String(localized: "download.status.cancelled")
            default:
                break
            }
        }
    }

    func removeCompletedDownloadProgressItems() {
        downloadProgressItems.removeAll { $0.state == .completed }
        persistDownloadSessionState()
    }

    private func parseDownloadDestination(from line: String) -> String? {
        let patterns = [
            #"^\[download\]\s+Destination:\s+(.+)$"#,
            #"^\[download\]\s+(.+)\s+has already been downloaded$"#,
            #"^\[download\]\s+(.+)\s+has already been downloaded and merged$"#
        ]
        for pattern in patterns {
            if let value = firstRegexCapture(in: line, pattern: pattern) {
                return value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            }
        }
        return nil
    }

    private func parseDownloadMetrics(from line: String) -> (size: String?, speed: String?, eta: String?) {
        let size = firstRegexCapture(in: line, pattern: #"\bof\s+~?\s*([0-9.]+\s*[KMGTPE]?i?B)(?:\s|$)"#)
            ?? firstRegexCapture(in: line, pattern: #"\bof\s+~?\s*(Unknown size)"#)
        let speed = firstRegexCapture(in: line, pattern: #"\bat\s+([^\s]+/s)"#)
        let eta = firstRegexCapture(in: line, pattern: #"\bETA\s+([0-9:]+|Unknown)"#)
        return (size, speed, eta)
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private func fallbackActiveDownloadName() -> String {
        let trimmedURL = (activeDownloadContext?.url ?? urlText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL) else {
            return String(localized: "download.fallback_title")
        }
        let lastPathComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastPathComponent.isEmpty {
            return lastPathComponent
        }
        return url.host ?? String(localized: "download.fallback_title")
    }

    private func handlePackageInstallProgressLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let missingPackage = line.hasPrefix("[palladium]") && lower.contains("package missing")
        let activeInstallStep = lower.contains("before pip install")
            || lower.hasPrefix("collecting ")
            || lower.hasPrefix("downloading ")
            || lower.hasPrefix("installing collected packages")
        let installFinished = lower.hasPrefix("successfully installed ")
            || lower.contains("pip installed into target")
            || lower.contains("pip exit code")
            || lower.contains("after install")
        let verbosePackageLine = line.hasPrefix("[palladium]") && (
            lower.contains("package install target")
                || lower.contains("checking yt-dlp package metadata")
                || lower.contains("checking yt-dlp-apple-webkit-jsi package metadata")
                || lower.contains("already installed")
                || lower.contains("pip module missing")
                || lower.contains("ensurepip")
        )

        if missingPackage || activeInstallStep {
            isInstallingPackagesDuringDownload = true
            progressText = line
            return true
        }

        if installFinished {
            if isInstallingPackagesDuringDownload || detailedProgressEnabled {
                progressText = line
            }
            return true
        }

        if verbosePackageLine || lower.hasPrefix("requirement already satisfied:") {
            if detailedProgressEnabled {
                progressText = line
                return true
            }
        }

        return false
    }

    private func shouldShowDetailedProgressLine(_ line: String) -> Bool {
        if line.hasPrefix("[palladium][ffmpeg-progress]")
            || line.hasPrefix("[palladium][playlist-progress]") {
            return false
        }
        return true
    }

    private func handlePlaylistProgressMarkerLine(_ line: String) -> Bool {
        let prefix = "[palladium][playlist-progress] "
        guard line.hasPrefix(prefix) else { return false }
        let payload = String(line.dropFirst(prefix.count))
        guard let data = payload.data(using: .utf8),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let snapshot = playlistProgressSnapshot(from: raw, fallbackResultKind: playlistProgress?.resultKind ?? "running") else {
            return true
        }

        playlistProgress = snapshot
        return true
    }

    private func playlistProgressSnapshot(
        from raw: [String: Any],
        fallbackResultKind: String
    ) -> PlaylistProgressSnapshot? {
        let title = normalizedOptionalString(raw["playlist_title"])
        let expectedCount = raw["playlist_expected_count"] as? Int
        let completedCount = raw["playlist_completed_count"] as? Int ?? 0
        let failedCount = raw["playlist_failed_count"] as? Int ?? 0
        let failedItems = (raw["playlist_failed_items"] as? [String]) ?? []
        let currentItemIndex = raw["current_item_index"] as? Int
        let currentItemTitle = normalizedOptionalString(raw["current_item_title"])
        let resultKind = normalizedOptionalString(raw["result_kind"]) ?? fallbackResultKind

        let hasPlaylistData = title != nil
            || expectedCount != nil
            || completedCount > 0
            || failedCount > 0
            || currentItemIndex != nil
            || !failedItems.isEmpty

        guard hasPlaylistData else { return nil }

        return PlaylistProgressSnapshot(
            title: title,
            expectedCount: expectedCount,
            completedCount: completedCount,
            failedCount: failedCount,
            failedItems: failedItems,
            currentItemIndex: currentItemIndex,
            currentItemTitle: currentItemTitle,
            resultKind: resultKind
        )
    }

    private func normalizedOptionalString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func downloadErrorDetails(from outcome: PythonFlowOutcome) -> String? {
        var lines: [String] = []

        let errorLines = outcome.outputText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("ERROR:") }
        if let lastErrorLine = errorLines.last {
            lines.append(lastErrorLine)
        }

        if let ytDlpExitCode = outcome.ytDlpExitCode {
            lines.append("yt-dlp exit code: \(ytDlpExitCode)")
        }
        if let pipExitCode = outcome.pipExitCode, pipExitCode != 0 {
            lines.append("pip exit code: \(pipExitCode)")
        }

        if lines.isEmpty {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    func enqueueConsoleChunk(_ chunk: String, trackProgress: Bool) {
        if trackProgress {
            updateProgress(from: chunk)
        }
        guard !chunk.isEmpty else { return }
        pendingConsoleChunks.append(chunk)
        guard !isConsoleFlushScheduled else { return }
        isConsoleFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            flushConsoleChunks()
        }
    }

    func flushConsoleChunks() {
        isConsoleFlushScheduled = false
        guard !pendingConsoleChunks.isEmpty else { return }
        appendConsoleText(pendingConsoleChunks)
        pendingConsoleChunks = ""
    }

    private func processLiveLogData(
        _ data: Data,
        decoder: StreamingUTF8Decoder,
        didReceiveLiveOutput: inout Bool
    ) {
        let chunk = decoder.append(data)
        guard !chunk.isEmpty else { return }
        didReceiveLiveOutput = true
        Task { @MainActor in
            enqueueConsoleChunk(chunk, trackProgress: true)
        }
    }

    private func drainLiveLogPipe(
        _ readHandle: FileHandle,
        decoder: StreamingUTF8Decoder,
        didReceiveLiveOutput: inout Bool
    ) {
        while true {
            let data = readHandle.availableData
            guard !data.isEmpty else { return }
            processLiveLogData(data, decoder: decoder, didReceiveLiveOutput: &didReceiveLiveOutput)
        }
    }

    private func appendBufferedConsoleOutputIfNeeded(_ outputText: String, receivedLiveOutput: Bool) {
        let bufferedLines = outputText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !bufferedLines.isEmpty else { return }

        if !receivedLiveOutput {
            appendConsoleText(
                "[palladium] live python log stream produced no decodable chunks; using buffered output fallback\n",
                source: .app
            )
            appendConsoleText(bufferedLines.joined(separator: "\n") + "\n")
            return
        }

        let streamedLines = consoleLogStore.entries
            .filter { $0.source != .ffmpeg }
            .map(\.text)

        var matchedPrefixCount = 0
        while matchedPrefixCount < streamedLines.count,
              matchedPrefixCount < bufferedLines.count,
              streamedLines[matchedPrefixCount] == bufferedLines[matchedPrefixCount] {
            matchedPrefixCount += 1
        }

        guard matchedPrefixCount < bufferedLines.count else { return }

        let missingLines = bufferedLines.dropFirst(matchedPrefixCount)
        appendConsoleText(missingLines.joined(separator: "\n") + "\n")
    }

    private func shouldAcceptDownloadProgressLine(_ line: String) -> Bool {
        guard let newPercent = extractDownloadPercent(from: line) else {
            return true
        }

        guard let lastPercent = lastDownloadProgressPercent else {
            lastDownloadProgressPercent = newPercent
            return true
        }

        if newPercent + 0.05 >= lastPercent {
            lastDownloadProgressPercent = newPercent
            return true
        }

        if lastPercent >= 99.5 && newPercent <= 5 {
            lastDownloadProgressPercent = newPercent
            return true
        }

        return false
    }

    private func parseFFmpegDuration(from line: String) -> Double? {
        guard let value = line.split(separator: "=", maxSplits: 1).last else {
            return nil
        }
        return parseFFmpegTimestamp(String(value))
    }

    private func parseFFmpegProgressUpdate(from line: String) -> (percent: Double?, speedText: String?)? {
        let payload = line.replacingOccurrences(of: "[palladium][ffmpeg-progress] ", with: "")
        let fields = payload.split(separator: " ").map(String.init)
        var currentTimeText: String?
        var speedText: String?

        for field in fields {
            if field.hasPrefix("time=") {
                currentTimeText = String(field.dropFirst(5))
            } else if field.hasPrefix("speed=") {
                speedText = String(field.dropFirst(6))
            }
        }

        guard let currentTimeText else {
            return nil
        }

        let currentTimeSeconds = parseFFmpegTimestamp(currentTimeText)
        let percent: Double?
        if let currentTimeSeconds,
           let durationSeconds = ffmpegProgressDurationSeconds,
           durationSeconds > 0 {
            percent = (currentTimeSeconds / durationSeconds) * 100
        } else {
            percent = nil
        }

        return (percent, speedText)
    }

    private func parseFFmpegTimestamp(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return (hours * 3600) + (minutes * 60) + seconds
    }

    private func extractDownloadPercent(from line: String) -> Double? {
        guard let range = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) else {
            return nil
        }
        let rawValue = line[range].dropLast()
        return Double(rawValue)
    }
}
