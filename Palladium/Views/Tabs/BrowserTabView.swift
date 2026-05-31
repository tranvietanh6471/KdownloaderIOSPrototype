import SwiftUI
import WebKit
import Combine

struct BrowserTabView: View {
    let isRunning: Bool
    let onDownloadURL: (String, String?) -> Void

    @StateObject private var controller = BrowserController()
    @State private var addressText = "https://www.google.com"
    @State private var detectedVideoURL = ""
    @State private var detectedTitleHint = ""
    @State private var detectedVideoSource = ""
    @State private var detectedVideos: [DetectedVideoCandidate] = []
    @State private var showDetectedVideos = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                browserAddressBar

                ZStack(alignment: .bottom) {
                    BrowserWebView(
                        controller: controller,
                        detectedVideoURL: $detectedVideoURL,
                        detectedTitleHint: $detectedTitleHint,
                        detectedVideoSource: $detectedVideoSource,
                        detectedVideos: $detectedVideos,
                        addressText: $addressText
                    )
                    .ignoresSafeArea(edges: .bottom)

                    if !browserDownloadURL.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 16, weight: .semibold))

                            Text(browserDownloadLabel)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 8)

                            if detectedVideos.count > 1 {
                                Button {
                                    showDetectedVideos = true
                                } label: {
                                    Image(systemName: "list.bullet")
                                        .font(.footnote.weight(.bold))
                                }
                                .buttonStyle(.bordered)
                            }

                            Button {
                                onDownloadURL(browserDownloadURL, detectedTitleHint)
                            } label: {
                                Label(browserDownloadButtonTitle, systemImage: "arrow.down.circle.fill")
                                    .font(.footnote.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(browserDownloadURL.isEmpty)
                        }
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 8)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDetectedVideos) {
                detectedVideosSheet
            }
        }
    }

    private var browserAddressBar: some View {
        HStack(spacing: 5) {
            browserToolbarButton(systemName: "chevron.left", isEnabled: controller.canGoBack) {
                controller.goBack()
            }

            browserToolbarButton(systemName: "chevron.right", isEnabled: controller.canGoForward) {
                controller.goForward()
            }

            HStack(spacing: 5) {
                TextField("Search or URL", text: $addressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.footnote)
                    .onSubmit {
                        controller.load(addressText)
                    }

                if !addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        addressText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear URL")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
            .frame(minWidth: 220, maxWidth: 520)

            browserToolbarButton(systemName: "arrow.clockwise") {
                controller.reload()
            }

            browserToolbarButton(systemName: "house") {
                controller.load("https://www.google.com")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            Color.blue.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.20), lineWidth: 1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(Color(.systemGroupedBackground))
    }

    private func browserToolbarButton(
        systemName: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.35)
    }

    private var browserDownloadURL: String {
        let detectedURL = detectedVideoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDirectMediaURL(detectedURL) {
            return detectedURL
        }

        let pageURL = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isYouTubeVideoPage(pageURL) {
            return pageURL
        }
        return ""
    }

    private var browserDownloadLabel: String {
        let downloadURL = browserDownloadURL
        if isDirectMediaURL(downloadURL) {
            return mediaDownloadLabel(for: downloadURL)
        }
        if isYouTubeVideoPage(downloadURL) {
            return "YouTube page"
        }
        if isXHamsterVideoPage(downloadURL) {
            return "xHamster page"
        }
        if isGenz3XVideoPage(downloadURL) {
            return "Genz3X page"
        }
        if isSextop1VideoPage(downloadURL) {
            return "Sextop1 page"
        }
        if isAvpleVideoPage(downloadURL) {
            return "Avple page"
        }
        if isKubHDVideoPage(downloadURL) {
            return "KUBHD page"
        }
        if isAnime108VideoPage(downloadURL) {
            return "Anime108 page"
        }
        guard let url = URL(string: downloadURL) else {
            return downloadURL
        }
        return url.lastPathComponent.isEmpty ? (url.host ?? downloadURL) : url.lastPathComponent
    }

    private var browserDownloadButtonTitle: String {
        if isRunning {
            return "Queue"
        }
        if isDirectMediaURL(browserDownloadURL) {
            return "Download"
        }
        return "Analyze"
    }

    private func mediaDownloadLabel(for value: String) -> String {
        guard let url = URL(string: value) else { return "Detected media" }
        let host = url.host ?? "media"
        let path = url.lastPathComponent
        if path.isEmpty {
            return "Media: \(host)"
        }
        return "Media: \(path)"
    }

    private func isDirectMediaURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let mediaExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov", "webm", "mpd", "ts"]
        if mediaExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        return value.range(
            of: "\\.(m3u8|mp4|m4v|mov|webm|mpd|ts)(\\?|#|/|$)",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isYouTubeVideoPage(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let rawHost = url.host?.lowercased() else {
            return false
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        if host == "youtu.be" {
            return url.pathComponents.filter { $0 != "/" }.isEmpty == false
        }
        guard host == "youtube.com" || host == "m.youtube.com" || host == "music.youtube.com" else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" }
        if components.first == "watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains(where: { $0.name == "v" && ($0.value?.isEmpty == false) }) == true
        }
        if let first = components.first, ["shorts", "live", "embed"].contains(first) {
            return components.count >= 2
        }
        return false
    }

    private func isXHamsterVideoPage(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let rawHost = url.host?.lowercased() else {
            return false
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let knownHosts = ["xhamster.com", "xhamster.desi", "xhamster.xxx"]
        guard knownHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
            return false
        }
        return url.path.lowercased().contains("/videos/")
    }

    private func isGenz3XVideoPage(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let rawHost = url.host?.lowercased() else {
            return false
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let knownHosts = ["genz3x.com", "clipphimsex3x.net", "clipsexsub3x.net"]
        guard knownHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return false }
        return Int(components.last ?? "") != nil
    }

    private func isSextop1VideoPage(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let rawHost = url.host?.lowercased() else {
            return false
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard host == "sextop1.cl" || host.hasSuffix(".sextop1.cl") else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" }
        return components.count == 1 && !components[0].isEmpty
    }

    private func isAvpleVideoPage(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let rawHost = url.host?.lowercased() else {
            return false
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard host == "avple.tv" || host.hasSuffix(".avple.tv") else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" }
        return components.count == 2 && components[0] == "video" && !components[1].isEmpty
    }

    private func isKubHDVideoPage(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let rawHost = url.host?.lowercased() else {
            return false
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard host == "kubhd24.net" || host.hasSuffix(".kubhd24.net") else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let section = components.first else { return false }
        return components.count >= 2 && (section == "movie" || section == "series")
    }

    private func isAnime108VideoPage(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let rawHost = url.host?.lowercased() else {
            return false
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard host == "anime108.com" || host.hasSuffix(".anime108.com") else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1, let slug = components.first else { return false }
        let categorySlugs = [
            "the-movie",
            "top-imdb",
            "fillter-year",
            "author",
            "category",
            "tag",
            "page"
        ]
        return !categorySlugs.contains(slug)
    }

    private var detectedVideosSheet: some View {
        NavigationStack {
            List(detectedVideos) { candidate in
                Button {
                    detectedVideoURL = candidate.url
                    detectedTitleHint = candidate.pageTitle
                    detectedVideoSource = candidate.source
                    showDetectedVideos = false
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(candidate.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(candidate.sourceLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(candidate.isDirectMedia ? Color.green : Color.orange)
                    }
                }
            }
            .navigationTitle("Detected Videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showDetectedVideos = false
                    }
                }
            }
        }
    }
}

struct DetectedVideoCandidate: Identifiable, Equatable {
    let id: String
    let url: String
    let pageTitle: String
    let source: String
    let score: Int

    init(url: String, pageTitle: String, source: String, score: Int) {
        self.id = url
        self.url = url
        self.pageTitle = pageTitle
        self.source = source
        self.score = score
    }

    var displayName: String {
        guard let parsedURL = URL(string: url) else { return url }
        return parsedURL.lastPathComponent.isEmpty ? (parsedURL.host ?? url) : parsedURL.lastPathComponent
    }

    var isDirectMedia: Bool {
        guard let parsedURL = URL(string: url) else { return false }
        let mediaExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov", "webm", "mpd", "ts"]
        if mediaExtensions.contains(parsedURL.pathExtension.lowercased()) {
            return true
        }
        return url.range(
            of: "\\.(m3u8|mp4|m4v|mov|webm|mpd|ts)(\\?|#|/|$)",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    var sourceLabel: String {
        isDirectMedia ? "Detected media - \(source)" : "Page only - \(source)"
    }
}

@MainActor
final class BrowserController: ObservableObject {
    weak var webView: WKWebView?
    @Published var canGoBack = false
    @Published var canGoForward = false

    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url: URL?
        if trimmed.localizedCaseInsensitiveContains("://") {
            url = URL(string: trimmed)
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            url = URL(string: "https://\(trimmed)")
        } else {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            url = components?.url
        }

        guard let url else { return }
        webView?.load(URLRequest(url: url))
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    func updateNavigationState() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
    }
}

private struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var controller: BrowserController
    @Binding var detectedVideoURL: String
    @Binding var detectedTitleHint: String
    @Binding var detectedVideoSource: String
    @Binding var detectedVideos: [DetectedVideoCandidate]
    @Binding var addressText: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "kdownloaderVideo")
        contentController.addUserScript(WKUserScript(
            source: Self.videoDetectionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "kdownloaderContentBlocker",
            encodedContentRuleList: Self.contentBlockerRules
        ) { contentRuleList, _ in
            guard let contentRuleList else { return }
            contentController.add(contentRuleList)
        }
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        controller.webView = webView
        webView.load(URLRequest(url: URL(string: "https://www.google.com")!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        controller.webView = uiView
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "kdownloaderVideo")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let parent: BrowserWebView

        init(_ parent: BrowserWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.controller.updateNavigationState()
            parent.addressText = webView.url?.absoluteString ?? parent.addressText
            webView.evaluateJavaScript("window.kdownloaderScanVideos && window.kdownloaderScanVideos();")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.controller.updateNavigationState()
            parent.addressText = webView.url?.absoluteString ?? parent.addressText
            parent.detectedVideoURL = ""
            parent.detectedTitleHint = ""
            parent.detectedVideoSource = ""
            parent.detectedVideos = []
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "kdownloaderVideo" else { return }
            if let url = message.body as? String, !url.isEmpty {
                parent.detectedVideoURL = url
                parent.detectedVideoSource = "legacy"
            } else if let payload = message.body as? [String: Any],
                      let url = payload["url"] as? String,
                      !url.isEmpty {
                let title = (payload["pageTitle"] as? String) ?? ""
                let source = (payload["source"] as? String) ?? ""
                let score = (payload["score"] as? NSNumber)?.intValue ?? (payload["score"] as? Int) ?? 0
                parent.detectedVideoURL = url
                parent.detectedTitleHint = title
                parent.detectedVideoSource = source
                let candidate = DetectedVideoCandidate(
                    url: url,
                    pageTitle: title,
                    source: source,
                    score: score
                )
                parent.detectedVideos.removeAll { $0.url == url }
                parent.detectedVideos.insert(candidate, at: 0)
                if parent.detectedVideos.count > 12 {
                    parent.detectedVideos.removeLast(parent.detectedVideos.count - 12)
                }
            }
        }
    }

    private static let videoDetectionScript = """
    (() => {
      if (window.kdownloaderInstalled) { return; }
      window.kdownloaderInstalled = true;
      var lastURL = "";
      var emitTimer = null;
      const pageStartedAt = Date.now();
      const candidates = new Map();
      const videoPattern = /\\.(m3u8|mp4|m4v|mov|webm|mpd|ts)(\\?|#|$)/i;
      const adHostPattern = /(^|\\.)(doubleclick\\.net|googlesyndication\\.com|googleadservices\\.com|adservice\\.google\\.|adnxs\\.com|adsrvr\\.org|pubmatic\\.com|rubiconproject\\.com|openx\\.net|criteo\\.com|taboola\\.com|outbrain\\.com|scorecardresearch\\.com|moatads\\.com|imasdk\\.googleapis\\.com)$/i;
      const adPathPattern = /(^|[\\/_\\-.?&=])(ad|ads|advert|advertising|vast|vpaid|prebid|preroll|pre-roll|midroll|mid-roll|postroll|post-roll|instream|bumper|ima|beacon|pixel|tracking|analytics|sponsor|promo)([\\/_\\-.?&=]|$)/i;

      function absoluteURL(value) {
        if (!value || typeof value !== "string") { return ""; }
        try { return new URL(value, location.href).href; } catch (_) { return value; }
      }

      function normalizeMediaText(value) {
        return String(value || "")
          .replace(/\\\\\\//g, "/")
          .replace(/\\\\u002[fF]/g, "/")
          .replace(/&amp;/g, "&");
      }

      function emitTextMediaURLs(text, source) {
        const normalized = normalizeMediaText(text);
        if (!videoPattern.test(normalized)) { return; }
        videoPattern.lastIndex = 0;

        const absoluteMatches = normalized.match(/(?:https?:)?\\/\\/[^"'<>\\s]+?\\.(?:m3u8|mp4|m4v|mov|webm|mpd|ts)(?:\\?[^"'<>\\s]+)?/ig) || [];
        absoluteMatches.forEach(raw => {
          const url = raw.startsWith("//") ? `${location.protocol}${raw}` : raw;
          emit(url, source);
        });

        const relativePattern = /["'=:(,\\s]([^"'<>\\s]+?\\.(?:m3u8|mp4|m4v|mov|webm|mpd|ts)(?:\\?[^"'<>\\s]+)?)/ig;
        let match = null;
        while ((match = relativePattern.exec(normalized)) !== null) {
          emit(match[1], source);
        }
      }

      function isLikelyAd(url) {
        try {
          const parsed = new URL(url, location.href);
          const host = parsed.hostname || "";
          const path = `${parsed.pathname || ""}?${parsed.search || ""}`;
          return adHostPattern.test(host) || adPathPattern.test(path);
        } catch (_) {
          return adPathPattern.test(url);
        }
      }

      function mediaExtensionScore(url) {
        if (/\\.(m3u8|mpd)(\\?|#|$)/i.test(url)) { return 45; }
        if (/\\.(mp4|m4v|mov|webm)(\\?|#|$)/i.test(url)) { return 30; }
        if (/\\.ts(\\?|#|$)/i.test(url)) { return -15; }
        return 0;
      }

      function videoElementScore(video) {
        if (!video) { return 0; }
        const rect = video.getBoundingClientRect ? video.getBoundingClientRect() : { width: 0, height: 0 };
        const area = Math.max(0, rect.width || 0) * Math.max(0, rect.height || 0);
        const duration = Number(video.duration || 0);
        let score = 0;
        if (area > 160000) { score += 45; }
        else if (area > 50000) { score += 25; }
        else if (area > 8000) { score += 8; }
        else { score -= 30; }
        if (Number.isFinite(duration) && duration > 0) {
          if (duration <= 75 && Date.now() - pageStartedAt < 18000) { score -= 90; }
          else if (duration > 180) { score += 35; }
          else if (duration > 75) { score += 15; }
        }
        if (!video.paused) { score += 8; }
        return score;
      }

      function isCandidate(value, source, entry, video) {
        const url = absoluteURL(value);
        if (!url || isLikelyAd(url) || !videoPattern.test(url)) { return false; }
        if (video) {
          const duration = Number(video.duration || 0);
          if (
            Number.isFinite(duration)
            && duration > 0
            && duration <= 75
            && Date.now() - pageStartedAt < 18000
            && video.currentTime < Math.max(3, duration - 3)
          ) {
            return false;
          }
        }
        if (source === "resource") {
          const size = Number(entry && (entry.transferSize || entry.encodedBodySize || entry.decodedBodySize) || 0);
          if (!/\\.(m3u8|mpd)(\\?|#|$)/i.test(url) && size > 0 && size < 524288) {
            return false;
          }
        }
        return true;
      }

      function cleanTitle() {
        const raw = (document.title || "").replace(/\\s+/g, " ").trim();
        if (raw) { return raw; }
        try { return new URL(location.href).hostname || "Video"; } catch (_) { return "Video"; }
      }

      function supportedPageLabel(url) {
        try {
          const parsed = new URL(url, location.href);
          const host = (parsed.hostname || "").replace(/^www\\./i, "").toLowerCase();
          const path = parsed.pathname || "";
          const parts = path.split("/").filter(Boolean);
          if (host === "youtu.be" && parts.length >= 1) { return "YouTube page"; }
          if ((host === "youtube.com" || host === "m.youtube.com" || host === "music.youtube.com")
            && ((parts[0] === "watch" && parsed.searchParams.get("v")) || ["shorts", "live", "embed"].includes(parts[0]))) {
            return "YouTube page";
          }
          if ((host === "xhamster.com" || host.endsWith(".xhamster.com") || host === "xhamster.desi" || host.endsWith(".xhamster.desi") || host === "xhamster.xxx" || host.endsWith(".xhamster.xxx"))
            && path.toLowerCase().includes("/videos/")) { return "xHamster page"; }
          if ((host === "genz3x.com" || host.endsWith(".genz3x.com") || host === "clipphimsex3x.net" || host.endsWith(".clipphimsex3x.net") || host === "clipsexsub3x.net" || host.endsWith(".clipsexsub3x.net"))
            && /^\\/.+\\/\\d+\\/?$/i.test(path)) { return "Genz3X page"; }
          if ((host === "sextop1.cl" || host.endsWith(".sextop1.cl")) && parts.length === 1) { return "Sextop1 page"; }
          if ((host === "avple.tv" || host.endsWith(".avple.tv")) && parts.length === 2 && parts[0] === "video") { return "Avple page"; }
          if ((host === "kubhd24.net" || host.endsWith(".kubhd24.net")) && parts.length >= 2 && (parts[0] === "movie" || parts[0] === "series")) { return "KUBHD page"; }
          if ((host === "anime108.com" || host.endsWith(".anime108.com")) && parts.length === 1 && !["the-movie", "top-imdb", "fillter-year", "author", "category", "tag", "page"].includes(parts[0])) { return "Anime108 page"; }
          if (host === "main.108player.com" || host.endsWith(".main.108player.com")) { return "Anime108 player"; }
        } catch (_) {}
        return "";
      }

      function emitSupportedPageURL() {
        const pageURL = location.href;
        const label = supportedPageLabel(pageURL);
        if (!label || pageURL === lastURL) { return; }
        lastURL = pageURL;
        window.webkit.messageHandlers.kdownloaderVideo.postMessage({
          url: pageURL,
          pageTitle: cleanTitle(),
          pageURL: pageURL,
          source: "page",
          score: 120
        });
      }

      function removeKnownAdNodes() {
        document.querySelectorAll("iframe, script, img, source").forEach(node => {
          const url = node.src || node.href || "";
          if (url && isLikelyAd(url)) {
            node.remove();
          }
        });
      }

      function scanNodeAttributes(root) {
        const attributeNames = [
          "src",
          "href",
          "data-src",
          "data-file",
          "data-video",
          "data-hls",
          "data-url",
          "data-play",
          "data-embed",
          "poster"
        ];
        const nodes = root && root.querySelectorAll ? root.querySelectorAll("*") : [];
        nodes.forEach(node => {
          attributeNames.forEach(name => {
            const value = node.getAttribute && node.getAttribute(name);
            if (value) { emit(value, `attr:${name}`); }
          });
        });
      }

      function scanInlineScripts() {
        document.querySelectorAll("script:not([src])").forEach(script => {
          emitTextMediaURLs(script.textContent || "", "script");
        });
      }

      function patchMediaProperty(proto, propertyName, sourceName) {
        try {
          if (!proto) { return; }
          const descriptor = Object.getOwnPropertyDescriptor(proto, propertyName);
          if (!descriptor || !descriptor.set || descriptor.set.__kdownloaderPatched) { return; }
          const nativeSet = descriptor.set;
          const nativeGet = descriptor.get;
          const patchedSet = function(value) {
            try { emit(String(value || ""), sourceName); } catch (_) {}
            return nativeSet.call(this, value);
          };
          patchedSet.__kdownloaderPatched = true;
          Object.defineProperty(proto, propertyName, {
            configurable: descriptor.configurable,
            enumerable: descriptor.enumerable,
            get: nativeGet,
            set: patchedSet
          });
        } catch (_) {}
      }

      function installNetworkHooks() {
        if (window.kdownloaderHooksInstalled) { return; }
        window.kdownloaderHooksInstalled = true;

        const nativeFetch = window.fetch;
        if (nativeFetch) {
          window.fetch = function(input, init) {
            let requestURL = "";
            try {
              requestURL = typeof input === "string" ? input : (input && input.url) || "";
              if (requestURL) { emit(requestURL, "fetch"); }
            } catch (_) {}
            return nativeFetch.apply(this, arguments).then(response => {
              try {
                const contentType = (response.headers && response.headers.get && response.headers.get("content-type")) || "";
                if (/json|text|javascript|mpegurl|x-mpegurl|vnd\\.apple\\.mpegurl/i.test(contentType) || videoPattern.test(requestURL)) {
                  response.clone().text().then(text => emitTextMediaURLs(text, "fetch-response")).catch(() => {});
                }
              } catch (_) {}
              return response;
            });
          };
        }

        const nativeOpen = typeof XMLHttpRequest !== "undefined" && XMLHttpRequest.prototype && XMLHttpRequest.prototype.open;
        if (nativeOpen) {
          XMLHttpRequest.prototype.open = function(method, url) {
            try {
              this.__kdownloaderURL = String(url || "");
              if (url) { emit(url, "xhr"); }
            } catch (_) {}
            return nativeOpen.apply(this, arguments);
          };
        }

        const nativeSend = typeof XMLHttpRequest !== "undefined" && XMLHttpRequest.prototype && XMLHttpRequest.prototype.send;
        if (nativeSend) {
          XMLHttpRequest.prototype.send = function() {
            try {
              this.addEventListener("loadend", () => {
                try {
                  const responseType = String(this.responseType || "");
                  const responseURL = this.responseURL || this.__kdownloaderURL || "";
                  if (responseURL) { emit(responseURL, "xhr-response-url"); }
                  if (!responseType || responseType === "text" || responseType === "json") {
                    emitTextMediaURLs(this.responseText || "", "xhr-response");
                  }
                } catch (_) {}
              });
            } catch (_) {}
            return nativeSend.apply(this, arguments);
          };
        }

        const nativeSetAttribute = typeof Element !== "undefined" && Element.prototype && Element.prototype.setAttribute;
        if (nativeSetAttribute) {
          Element.prototype.setAttribute = function(name, value) {
            try {
              if (/^(src|href|data-src|data-file|data-video|data-hls|data-url|data-play|data-embed)$/i.test(String(name || ""))) {
                emit(String(value || ""), `setattr:${name}`);
              }
            } catch (_) {}
            return nativeSetAttribute.apply(this, arguments);
          };
        }

        patchMediaProperty(typeof HTMLMediaElement !== "undefined" ? HTMLMediaElement.prototype : null, "src", "media-src-setter");
        patchMediaProperty(typeof HTMLSourceElement !== "undefined" ? HTMLSourceElement.prototype : null, "src", "source-src-setter");
        patchMediaProperty(typeof HTMLIFrameElement !== "undefined" ? HTMLIFrameElement.prototype : null, "src", "iframe-src-setter");

        if (window.PerformanceObserver) {
          try {
            const observer = new PerformanceObserver(list => {
              list.getEntries().forEach(entry => emit(entry.name, "resource", entry));
            });
            observer.observe({ entryTypes: ["resource"] });
          } catch (_) {}
        }
      }

      function candidateScore(url, source, entry, video) {
        let score = mediaExtensionScore(url);
        if (source === "video" || source === "video-source") { score += 30; }
        else if (source === "dom") { score += 12; }
        else if (source === "fetch" || source === "xhr") { score += 25; }
        else if (source === "fetch-response" || source === "xhr-response") { score += 35; }
        else if (source === "media-src-setter" || source === "source-src-setter") { score += 35; }
        else if (String(source || "").startsWith("attr:") || String(source || "").startsWith("setattr:")) { score += 18; }
        else if (source === "script") { score += 10; }
        else if (source === "resource") { score -= 4; }
        score += videoElementScore(video);
        const size = Number(entry && (entry.transferSize || entry.encodedBodySize || entry.decodedBodySize) || 0);
        if (size > 5 * 1024 * 1024) { score += 20; }
        else if (size > 1024 * 1024) { score += 8; }
        return score;
      }

      function flushCandidate() {
        emitTimer = null;
        let best = null;
        candidates.forEach(candidate => {
          if (!best || candidate.score > best.score || (candidate.score === best.score && candidate.seenAt > best.seenAt)) {
            best = candidate;
          }
        });
        if (!best || best.url === lastURL || best.score < 20) { return; }
        lastURL = best.url;
        window.webkit.messageHandlers.kdownloaderVideo.postMessage({
          url: best.url,
          pageTitle: cleanTitle(),
          pageURL: location.href,
          source: best.source,
          score: best.score
        });
      }

      function scheduleCandidateFlush() {
        if (emitTimer) { clearTimeout(emitTimer); }
        emitTimer = setTimeout(flushCandidate, 1800);
      }

      function emit(value, source, entry, video) {
        const url = absoluteURL(value);
        if (!isCandidate(url, source, entry, video) || url === lastURL) { return; }
        const score = candidateScore(url, source, entry, video);
        const existing = candidates.get(url);
        candidates.set(url, {
          url,
          source,
          score: existing ? Math.max(existing.score, score) : score,
          seenAt: Date.now()
        });
        if (candidates.size > 30) {
          const oldest = [...candidates.entries()].sort((a, b) => a[1].seenAt - b[1].seenAt)[0];
          if (oldest) { candidates.delete(oldest[0]); }
        }
        scheduleCandidateFlush();
      }

      function scanVideos() {
        installNetworkHooks();
        emitSupportedPageURL();
        removeKnownAdNodes();
        if (!document.querySelectorAll) { return; }
        document.querySelectorAll("video").forEach(video => {
          emit(video.currentSrc || video.src, "video", null, video);
          video.querySelectorAll("source").forEach(source => emit(source.src, "video-source", null, video));
        });
        document.querySelectorAll("source, a").forEach(node => {
          emit(node.src || node.href, "dom");
        });
        scanNodeAttributes(document);
        scanInlineScripts();
        if (performance && performance.getEntriesByType) {
          performance.getEntriesByType("resource").forEach(entry => emit(entry.name, "resource", entry));
        }
      }

      window.kdownloaderScanVideos = scanVideos;
      document.addEventListener("play", scanVideos, true);
      document.addEventListener("loadedmetadata", scanVideos, true);
      function installDomObserver() {
        if (!document.documentElement || window.kdownloaderDomObserverInstalled) { return; }
        window.kdownloaderDomObserverInstalled = true;
        new MutationObserver(scanVideos).observe(document.documentElement, { childList: true, subtree: true, attributes: true });
      }
      document.addEventListener("DOMContentLoaded", () => {
        installDomObserver();
        scanVideos();
      }, true);
      installNetworkHooks();
      installDomObserver();
      setInterval(scanVideos, 1200);
      scanVideos();
    })();
    """

    private static let contentBlockerRules = """
    [
      {"trigger":{"url-filter":".*doubleclick\\\\.net.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*googlesyndication\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*googleadservices\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*adservice\\\\.google\\\\..*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*imasdk\\\\.googleapis\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*adnxs\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*adsrvr\\\\.org.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*pubmatic\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*rubiconproject\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*openx\\\\.net.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*criteo\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*taboola\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*outbrain\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*scorecardresearch\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*moatads\\\\.com.*"},"action":{"type":"block"}}
    ]
    """
}
