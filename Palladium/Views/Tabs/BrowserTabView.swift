import SwiftUI
import WebKit

struct BrowserTabView: View {
    let isRunning: Bool
    let onDownloadURL: (String) -> Void

    @StateObject private var controller = BrowserController()
    @State private var addressText = "https://www.google.com"
    @State private var detectedVideoURL = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BrowserWebView(
                    controller: controller,
                    detectedVideoURL: $detectedVideoURL,
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
                            onDownloadURL(detectedVideoURL)
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
                    }
                    .disabled(!controller.canGoBack)

                    Button {
                        controller.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!controller.canGoForward)
                }

                ToolbarItem(placement: .principal) {
                    TextField("Search or URL", text: $addressText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            controller.load(addressText)
                        }
                        .frame(minWidth: 180, maxWidth: 420)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        controller.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button {
                        controller.load("https://www.google.com")
                    } label: {
                        Image(systemName: "house")
                    }
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
            }
        }
    }

    private static let videoDetectionScript = """
    (() => {
      if (window.kdownloaderInstalled) { return; }
      window.kdownloaderInstalled = true;
      let lastURL = "";
      const videoPattern = /\\.(m3u8|mp4|m4v|mov|webm|mpd|ts)(\\?|#|$)/i;
      const ignoredPattern = /(doubleclick|googlesyndication|google-analytics|facebook\\.com\\/tr)/i;

      function absoluteURL(value) {
        if (!value || typeof value !== "string") { return ""; }
        try { return new URL(value, location.href).href; } catch (_) { return value; }
      }

      function isCandidate(value) {
        const url = absoluteURL(value);
        if (!url || ignoredPattern.test(url)) { return false; }
        return videoPattern.test(url);
      }

      function emit(value) {
        const url = absoluteURL(value);
        if (!isCandidate(url) || url === lastURL) { return; }
        lastURL = url;
        window.webkit.messageHandlers.kdownloaderVideo.postMessage(url);
      }

      function scanVideos() {
        document.querySelectorAll("video").forEach(video => {
          emit(video.currentSrc || video.src);
          video.querySelectorAll("source").forEach(source => emit(source.src));
        });
        document.querySelectorAll("source, a").forEach(node => {
          emit(node.src || node.href);
        });
        if (performance && performance.getEntriesByType) {
          performance.getEntriesByType("resource").forEach(entry => emit(entry.name));
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
}
