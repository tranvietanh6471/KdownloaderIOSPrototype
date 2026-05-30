import SwiftUI

struct DownloadTabView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var statusText: String
    @Binding var urlText: String
    @Binding var selectedPreset: DownloadPreset
    @Binding var downloadPlaylist: Bool
    @Binding var downloadSubtitles: Bool
    @Binding var embedThumbnail: Bool
    @Binding var subtitleLanguagePattern: String
    @Binding var customSubtitleLanguagePattern: String
    @Binding var useCookies: Bool
    @Binding var selectedCookieFileName: String
    let importedCookieFiles: [ImportedCookieFile]

    let isRunning: Bool
    let isPaused: Bool
    let progressText: String
    let downloadProgressItems: [DownloadProgressItem]
    let playlistProgress: PlaylistProgressSnapshot?
    let downloadErrorText: String?
    let onDownload: () -> Void
    let onPauseItem: (UUID) -> Void
    let onResumeItem: (UUID) -> Void
    let onCancelItem: (UUID) -> Void
    let onPastedURL: (String) -> Void
    let linkHistoryEnabled: Bool
    let historyEntries: [LinkHistoryEntry]
    let onSelectHistoryEntry: (LinkHistoryEntry) -> Void
    let onDeleteHistoryEntry: (LinkHistoryEntry) -> Void
    let onCopyHistoryLink: (String) -> Void
    @State private var showHistorySheet = false
    @State private var showDownloadOptions = false

    var body: some View {
        ZStack {
            backgroundGradient
            .ignoresSafeArea()

            VStack(spacing: 12) {
                ZStack {
                    VStack(spacing: 4) {
                        Image(logoImageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                        Text("app.name")
                            .font(.title.bold())
                            .foregroundStyle(primaryTextColor)
                    }

                    HStack {
                        Spacer()
                        if linkHistoryEnabled {
                            Button {
                                showHistorySheet = true
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(primaryTextColor)
                                        .frame(width: 40, height: 40)
                                        .background(cardElementBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    if !historyEntries.isEmpty {
                                        Text("\(historyEntries.count)")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.blue)
                                            .clipShape(Capsule())
                                            .offset(x: 8, y: -8)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("history.open")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)

                if isRunning || isPaused || !downloadProgressItems.isEmpty || shouldShowPlaylistProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        if let playlistProgress, playlistProgress.isPlaylist {
                            playlistProgressCard(playlistProgress)
                        }

                        if (isRunning || isPaused) && downloadProgressItems.isEmpty {
                            compactDownloadStatusBar
                        }

                        if !downloadProgressItems.isEmpty {
                            downloadProgressList
                        }

                        if isRunning || isPaused {
                            if downloadProgressItems.isEmpty {
                                Text(progressText)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(primaryTextColor)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(8)
                                    .background(cardElementBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }

                if let downloadErrorText, !downloadErrorText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("download.error.last_title")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)

                        Text(downloadErrorText)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(primaryTextColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(cardElementBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.45), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20)
                }

                compactDownloadControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            .padding(.vertical, 14)
        }
        .sheet(isPresented: $showHistorySheet) {
            historySheet
        }
        .onChange(of: isRunning) { _, running in
            guard running, showDownloadOptions else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                showDownloadOptions = false
            }
        }
    }

    private func handlePastedStrings(_ strings: [String]) {
        guard let paste = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines), !paste.isEmpty else { return }
        urlText = paste
        onPastedURL(paste)
    }

    private func clearURL() {
        urlText = ""
    }

    private var compactDownloadControls: some View {
        VStack(spacing: 7) {
            Picker("download.preset.title", selection: $selectedPreset) {
                ForEach(DownloadPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .font(.caption)
            .disabled(isRunning || isPaused)

            HStack(spacing: 6) {
                Button {
                    guard !(isRunning || isPaused) else { return }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showDownloadOptions.toggle()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(cardElementBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(isRunning || isPaused)
                .accessibilityLabel("download.options.title")

                TextField("download.url.placeholder", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
                    .foregroundStyle(primaryTextColor)
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .background(cardElementBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                pasteOrClearURLButton

                Button(action: {
                    if showDownloadOptions {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showDownloadOptions = false
                        }
                    }
                    onDownload()
                }) {
                    Image(systemName: isRunning || isPaused ? "plus.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 38, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if showDownloadOptions {
                VStack(alignment: .leading, spacing: 7) {
                    Text(downloadOptionsSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    downloadOptionToggle(
                        title: String(localized: "download.options.playlist.title"),
                        subtitle: String(localized: "download.options.playlist.help"),
                        isOn: $downloadPlaylist
                    )

                    subtitleDownloadOptionRow

                    downloadOptionToggle(
                        title: String(localized: "download.options.thumbnail.title"),
                        subtitle: String(localized: "download.options.thumbnail.help"),
                        isOn: $embedThumbnail
                    )

                    cookieSelectionRow
                }
                .padding(8)
                .background(cardElementBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                        removal: .opacity
                    )
                )
            }
        }
        .padding(8)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var pasteOrClearURLButton: some View {
        if urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            PasteButton(payloadType: String.self) { strings in
                handlePastedStrings(strings)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle(radius: 7))
            .frame(width: 34, height: 34)
            .disabled(isRunning || isPaused)
        } else {
            Button(action: clearURL) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(cardElementBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
    }

    private var compactDownloadStatusBar: some View {
        HStack(spacing: 8) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            Text(isPaused ? "Paused" : String(localized: "download.status.running"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(primaryTextColor)

            Spacer(minLength: 8)

            if isRunning {
                Button {
                    if let runningItem = downloadProgressItems.first(where: { $0.state == .running || $0.state == .processing }) {
                        onPauseItem(runningItem.id)
                    }
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)

                Button {
                    if let runningItem = downloadProgressItems.first(where: { $0.state == .running || $0.state == .processing }) {
                        onCancelItem(runningItem.id)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
            } else if isPaused {
                Button {
                    if let pausedItem = downloadProgressItems.first(where: { $0.state == .paused }) {
                        onResumeItem(pausedItem.id)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)

                Button {
                    if let pausedItem = downloadProgressItems.first(where: { $0.state == .paused }) {
                        onCancelItem(pausedItem.id)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(cardElementBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func downloadOptionToggle(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            guard !isRunning else { return }
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? .blue : primaryTextColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(primaryTextColor)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
    }

    private var subtitleDownloadOptionRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    guard !isRunning else { return }
                    downloadSubtitles.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: downloadSubtitles ? "checkmark.square.fill" : "square")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(downloadSubtitles ? .blue : primaryTextColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("download.options.subtitles.title")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(primaryTextColor)
                            Text("download.options.subtitles.help")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRunning)

                if downloadSubtitles {
                    Picker("download.options.subtitles.language", selection: $subtitleLanguagePattern) {
                        ForEach(SubtitleLanguageOption.allCases) { option in
                            Text(option.title).tag(option.subtitlePattern)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(isRunning)
                    .tint(.blue)
                }
            }

            if downloadSubtitles, subtitleLanguagePattern == SubtitleLanguageOption.custom.subtitlePattern {
                TextField("download.options.subtitles.pattern", text: normalizedCustomSubtitlePattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(primaryTextColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(isRunning)
            }
        }
    }

    private var cookieSelectionRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    guard !isRunning else { return }
                    useCookies.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: useCookies ? "checkmark.square.fill" : "square")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(useCookies ? .blue : primaryTextColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("download.options.cookies.title")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(primaryTextColor)
                            Text("download.options.cookies.help")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRunning)

                if useCookies {
                    Picker("download.options.cookies.picker", selection: $selectedCookieFileName) {
                        Text("common.none").tag("")
                        ForEach(importedCookieFiles) { cookieFile in
                            Text(cookieFile.displayName).tag(cookieFile.fileName)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(isRunning || importedCookieFiles.isEmpty)
                    .tint(.blue)
                }
            }

            if useCookies && importedCookieFiles.isEmpty {
                Text("download.options.cookies.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var selectedSubtitleOption: SubtitleLanguageOption? {
        SubtitleLanguageOption.allCases.first(where: { $0.subtitlePattern == subtitleLanguagePattern })
    }

    private var subtitleSummaryText: String {
        if subtitleLanguagePattern == SubtitleLanguageOption.custom.subtitlePattern {
            let trimmed = customSubtitleLanguagePattern.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? String(localized: "common.custom")
                : String(format: String(localized: "download.custom.value"), trimmed)
        }
        if let option = selectedSubtitleOption {
            return option.title
        }
        let trimmed = subtitleLanguagePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "common.custom")
            : String(format: String(localized: "download.custom.value"), trimmed)
    }

    private var normalizedCustomSubtitlePattern: Binding<String> {
        Binding(
            get: { customSubtitleLanguagePattern },
            set: { newValue in
                customSubtitleLanguagePattern = newValue
                if subtitleLanguagePattern != SubtitleLanguageOption.custom.subtitlePattern,
                   !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    subtitleLanguagePattern = SubtitleLanguageOption.custom.subtitlePattern
                }
            }
        )
    }

    private var downloadOptionsSummary: String {
        var parts: [String] = []
        if downloadPlaylist {
            parts.append(String(localized: "download.options.playlist.short"))
        }
        if downloadSubtitles {
            parts.append(String(format: String(localized: "download.options.subtitles.value"), subtitleSummaryText))
        }
        if embedThumbnail {
            parts.append(String(localized: "download.options.thumbnail.title"))
        }
        let selectedCookieName = selectedCookieFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if useCookies, !selectedCookieName.isEmpty {
            parts.append(String(format: String(localized: "download.options.cookies.value"), selectedCookieName))
        } else if useCookies {
            parts.append(String(localized: "download.options.cookies.title"))
        }
        return parts.isEmpty ? String(localized: "download.options.summary.default") : parts.joined(separator: " • ")
    }

    private var downloadProgressList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("Download List")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                Spacer()
                Text("\(downloadProgressItems.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(downloadProgressItems) { item in
                        downloadProgressCard(item)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(8)
        .background(cardElementBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxHeight: .infinity)
    }

    private func downloadProgressCard(_ item: DownloadProgressItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: progressIcon(for: item.state))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(progressColor(for: item.state))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                    Text(progressStatusText(for: item))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(progressPercentText(for: item))
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(primaryTextColor)

                downloadProgressCardControls(for: item)
            }

            ProgressView(value: min(max(item.percent ?? 0, 0), 100), total: 100)
                .tint(progressColor(for: item.state))
                .controlSize(.small)

            HStack(spacing: 5) {
                progressMetric(title: "Size", value: item.sizeText ?? "-")
                progressMetric(title: "Speed", value: item.speedText ?? "-")
                progressMetric(title: "ETA", value: item.etaText ?? "-")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func downloadProgressCardControls(for item: DownloadProgressItem) -> some View {
        HStack(spacing: 4) {
            switch item.state {
            case .running, .processing:
                downloadProgressIconButton(systemName: "pause.fill", tint: .orange) {
                    onPauseItem(item.id)
                }
                downloadProgressIconButton(systemName: "xmark", tint: .red) {
                    onCancelItem(item.id)
                }
            case .paused:
                downloadProgressIconButton(systemName: "play.fill", tint: .blue) {
                    onResumeItem(item.id)
                }
                downloadProgressIconButton(systemName: "xmark", tint: .red) {
                    onCancelItem(item.id)
                }
            case .queued:
                downloadProgressIconButton(systemName: "xmark", tint: .red) {
                    onCancelItem(item.id)
                }
            case .completed, .failed, .cancelled:
                downloadProgressIconButton(systemName: "xmark", tint: .secondary) {
                    onCancelItem(item.id)
                }
            }
        }
    }

    private func downloadProgressIconButton(
        systemName: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 27, height: 24)
                .background(tint, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func progressMetric(title: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressPercentText(for item: DownloadProgressItem) -> String {
        guard let percent = item.percent else { return "-" }
        return String(format: "%.1f%%", locale: .current, min(max(percent, 0), 100))
    }

    private func progressStatusText(for item: DownloadProgressItem) -> String {
        switch item.state {
        case .queued:
            return "Queued"
        case .running:
            return "Downloading"
        case .paused:
            return "Paused"
        case .processing:
            return "Processing"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    private func progressIcon(for state: DownloadProgressItem.State) -> String {
        switch state {
        case .queued:
            return "clock"
        case .running:
            return "arrow.down.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .processing:
            return "gearshape.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "stop.circle.fill"
        }
    }

    private func progressColor(for state: DownloadProgressItem.State) -> Color {
        switch state {
        case .queued:
            return .secondary
        case .running:
            return .blue
        case .paused:
            return .orange
        case .processing:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }

    private func playlistProgressCard(_ snapshot: PlaylistProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: playlistStatusIcon(for: snapshot))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(playlistStatusColor(for: snapshot))

                Text(playlistStatusText(for: snapshot))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(primaryTextColor)

                Spacer()
            }

            if let title = snapshot.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                playlistMetric(
                    label: String(localized: "download.playlist.total"),
                    value: snapshot.expectedCount.map(String.init) ?? "?"
                )
                playlistMetric(
                    label: String(localized: "download.playlist.completed"),
                    value: "\(snapshot.completedCount)"
                )
                playlistMetric(
                    label: String(localized: "download.playlist.failed"),
                    value: "\(snapshot.failedCount)"
                )
            }

            Text(playlistSummaryText(for: snapshot))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            if let currentLine = playlistCurrentLine(for: snapshot) {
                Text(currentLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(cardElementBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(playlistStatusColor(for: snapshot).opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func playlistMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(primaryTextColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var shouldShowPlaylistProgress: Bool {
        playlistProgress?.isPlaylist == true
    }

    private func playlistStatusText(for snapshot: PlaylistProgressSnapshot) -> String {
        switch snapshot.resultKind {
        case "partial":
            return String(localized: "download.status.partial")
        case "success":
            return String(localized: "download.status.complete")
        case "error":
            return String(localized: "download.status.failed")
        case "cancelled":
            return String(localized: "download.status.cancelled")
        default:
            return String(localized: "download.status.running")
        }
    }

    private func playlistStatusIcon(for snapshot: PlaylistProgressSnapshot) -> String {
        switch snapshot.resultKind {
        case "partial":
            return "exclamationmark.triangle.fill"
        case "success":
            return "checkmark.circle.fill"
        case "error":
            return "xmark.octagon.fill"
        case "cancelled":
            return "stop.circle.fill"
        default:
            return "arrow.down.circle.fill"
        }
    }

    private func playlistStatusColor(for snapshot: PlaylistProgressSnapshot) -> Color {
        switch snapshot.resultKind {
        case "partial":
            return .orange
        case "success":
            return .green
        case "error":
            return .red
        case "cancelled":
            return .secondary
        default:
            return .blue
        }
    }

    private func playlistSummaryText(for snapshot: PlaylistProgressSnapshot) -> String {
        let expectedCount = snapshot.expectedCount ?? max(snapshot.completedCount + snapshot.failedCount, 0)
        switch snapshot.resultKind {
        case "partial":
            return String(
                format: String(localized: "download.playlist.summary.partial"),
                snapshot.completedCount,
                expectedCount,
                snapshot.failedCount
            )
        case "success":
            return String(
                format: String(localized: "download.playlist.summary.success"),
                snapshot.completedCount,
                expectedCount
            )
        case "error":
            return String(
                format: String(localized: "download.playlist.summary.failed"),
                snapshot.failedCount,
                expectedCount
            )
        case "cancelled":
            return String(
                format: String(localized: "download.playlist.summary.cancelled"),
                snapshot.completedCount,
                expectedCount
            )
        default:
            return String(
                format: String(localized: "download.playlist.summary.running"),
                snapshot.completedCount,
                expectedCount,
                snapshot.failedCount
            )
        }
    }

    private func playlistCurrentLine(for snapshot: PlaylistProgressSnapshot) -> String? {
        guard snapshot.resultKind == "running" || snapshot.resultKind.isEmpty else { return nil }
        guard let currentItemIndex = snapshot.currentItemIndex else { return nil }
        if let currentItemTitle = snapshot.currentItemTitle, !currentItemTitle.isEmpty {
            return String(
                format: String(localized: "download.playlist.current.value"),
                currentItemIndex,
                currentItemTitle
            )
        }
        return String(
            format: String(localized: "download.playlist.current.index"),
            currentItemIndex
        )
    }

    @ViewBuilder
    private func historyRow(_ entry: LinkHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = entry.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(2)
            }

            Text(entry.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Text(entry.preset.title)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(presetColor(entry.preset).opacity(0.25))
                    .foregroundStyle(primaryTextColor)
                    .clipShape(Capsule())

                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var historySheet: some View {
        NavigationStack {
            Group {
                if historyEntries.isEmpty {
                    ContentUnavailableView(
                        "history.empty.title",
                        systemImage: "clock",
                        description: Text("history.empty.subtitle")
                    )
                } else {
                    List {
                        ForEach(historyEntries) { entry in
                            Button {
                                onSelectHistoryEntry(entry)
                                showHistorySheet = false
                            } label: {
                                historyRow(entry)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(listRowBackground)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    onCopyHistoryLink(entry.url)
                                } label: {
                                    Label("common.copy", systemImage: "doc.on.doc")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onDeleteHistoryEntry(entry)
                                } label: {
                                    Label("common.delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("history.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done") {
                        showHistorySheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var logoImageName: String {
        isDarkMode ? "palladium_dark" : "palladium_light"
    }

    private var backgroundGradient: LinearGradient {
        if isDarkMode {
            return LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.10, blue: 0.14)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.97, green: 0.98, blue: 1.0), Color(red: 0.91, green: 0.93, blue: 0.97)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var primaryTextColor: Color {
        isDarkMode ? .white : .primary
    }

    private var cardBackground: Color {
        isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var cardElementBackground: Color {
        isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    private var listRowBackground: Color {
        isDarkMode ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }

    private func presetColor(_ preset: DownloadPreset) -> Color {
        switch preset {
        case .audio:
            return .green
        case .mute:
            return .orange
        case .custom:
            return .indigo
        case .autoVideo:
            return .blue
        }
    }
}
