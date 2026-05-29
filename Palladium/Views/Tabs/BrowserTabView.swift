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

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BrowserWebView(
                    controller: controller,
                    detectedVideoURL: $detectedVideoURL,
                    detectedTitleHint: $detectedTitleHint,
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
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        controller.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .disabled(!controller.canGoBack)

                    Button {
                        controller.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
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
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)

                    Button {
                        controller.load("https://www.google.com")
                    } label: {
                        Image(systemName: "house")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
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
                parent.detectedVideoURL = url
                parent.detectedTitleHint = (payload["pageTitle"] as? String) ?? ""
            }
        }
    }

    private static let videoDetectionScript = """
    (() => {
      if (window.kdownloaderInstalled) { return; }
      window.kdownloaderInstalled = true;
      let lastURL = "";
      const videoPattern = /\\.(m3u8|mp4|m4v|mov|webm|mpd|ts)(\\?|#|$)/i;
      const adHostPattern = /(^|\\.)(doubleclick\\.net|googlesyndication\\.com|googleadservices\\.com|adservice\\.google\\.|adnxs\\.com|adsrvr\\.org|pubmatic\\.com|rubiconproject\\.com|openx\\.net|criteo\\.com|taboola\\.com|outbrain\\.com|scorecardresearch\\.com|moatads\\.com|imasdk\\.googleapis\\.com)$/i;
      const adPathPattern = /(^|[\\/_\\-.?&=])(ad|ads|advert|advertising|vast|vpaid|prebid|preroll|midroll|postroll|ima|beacon|pixel|tracking|analytics|sponsor|promo)([\\/_\\-.?&=]|$)/i;

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

      function isCandidate(value, source, entry) {
        const url = absoluteURL(value);
        if (!url || isLikelyAd(url) || !videoPattern.test(url)) { return false; }
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

      function emit(value, source, entry) {
        const url = absoluteURL(value);
        if (!isCandidate(url, source, entry) || url === lastURL) { return; }
        lastURL = url;
        window.webkit.messageHandlers.kdownloaderVideo.postMessage({
          url,
          pageTitle: cleanTitle(),
          pageURL: location.href,
          source
        });
      }

      function scanVideos() {
        removeKnownAdNodes();
        document.querySelectorAll("video").forEach(video => {
          emit(video.currentSrc || video.src, "video");
          video.querySelectorAll("source").forEach(source => emit(source.src, "video-source"));
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
