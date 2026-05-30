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
    @State private var detectedVideos: [DetectedVideoCandidate] = []
    @State private var showDetectedVideos = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BrowserWebView(
                    controller: controller,
                    detectedVideoURL: $detectedVideoURL,
                    detectedTitleHint: $detectedTitleHint,
                    detectedVideos: $detectedVideos,
                    addressText: $addressText
                )
                .ignoresSafeArea(edges: .bottom)

                if !detectedVideoURL.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 16, weight: .semibold))

                        Text(detectedVideoLabel)
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
                            onDownloadURL(detectedVideoURL, detectedTitleHint)
                        } label: {
                            Label(isRunning ? "Queue" : "Download", systemImage: "arrow.down.circle.fill")
                                .font(.footnote.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(detectedVideoURL.isEmpty)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 8)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showDetectedVideos) {
                detectedVideosSheet
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        controller.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(!controller.canGoBack)

                    Button {
                        controller.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(!controller.canGoForward)
                }

                ToolbarItem(placement: .principal) {
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
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        controller.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 20)
                    }
                    .buttonStyle(.plain)

                    Button {
                        controller.load("https://www.google.com")
                    } label: {
                        Image(systemName: "house")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var detectedVideoLabel: String {
        guard let url = URL(string: detectedVideoURL) else {
            return detectedVideoURL
        }
        return url.lastPathComponent.isEmpty ? (url.host ?? detectedVideoURL) : url.lastPathComponent
    }

    private var detectedVideosSheet: some View {
        NavigationStack {
            List(detectedVideos) { candidate in
                Button {
                    detectedVideoURL = candidate.url
                    detectedTitleHint = candidate.pageTitle
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
            injectionTime: .atDocumentEnd,
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
            parent.detectedVideos = []
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "kdownloaderVideo" else { return }
            if let url = message.body as? String, !url.isEmpty {
                parent.detectedVideoURL = url
            } else if let payload = message.body as? [String: Any],
                      let url = payload["url"] as? String,
                      !url.isEmpty {
                let title = (payload["pageTitle"] as? String) ?? ""
                let source = (payload["source"] as? String) ?? ""
                let score = (payload["score"] as? NSNumber)?.intValue ?? (payload["score"] as? Int) ?? 0
                parent.detectedVideoURL = url
                parent.detectedTitleHint = title
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

      function removeKnownAdNodes() {
        document.querySelectorAll("iframe, script, img, source").forEach(node => {
          const url = node.src || node.href || "";
          if (url && isLikelyAd(url)) {
            node.remove();
          }
        });
      }

      function candidateScore(url, source, entry, video) {
        let score = mediaExtensionScore(url);
        if (source === "video" || source === "video-source") { score += 30; }
        else if (source === "dom") { score += 12; }
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
        removeKnownAdNodes();
        document.querySelectorAll("video").forEach(video => {
          emit(video.currentSrc || video.src, "video", null, video);
          video.querySelectorAll("source").forEach(source => emit(source.src, "video-source", null, video));
        });
        document.querySelectorAll("source, a").forEach(node => {
          emit(node.src || node.href, "dom");
        });
        if (performance && performance.getEntriesByType) {
          performance.getEntriesByType("resource").forEach(entry => emit(entry.name, "resource", entry));
        }
      }

      window.kdownloaderScanVideos = scanVideos;
      document.addEventListener("play", scanVideos, true);
      document.addEventListener("loadedmetadata", scanVideos, true);
      new MutationObserver(scanVideos).observe(document.documentElement, { childList: true, subtree: true, attributes: true });
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
