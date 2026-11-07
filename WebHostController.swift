import UIKit
import WebKit

final class WebHostController: UIViewController {

    private var server: LocalHTTPServer?
    private var webView: WKWebView!
    private let bridge = BridgeController()
    private var lastDownloadURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        setup()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(enterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        server?.stop()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    @objc private func enterBackground() {
        // Nothing to pause: the model download continues in the foreground
        // only, and audio is stopped by the web UI.
    }

    private func setup() {
        guard let resources = Bundle.main.resourceURL?
            .appendingPathComponent("Resources", isDirectory: true),
            FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("index.html").path
            ) else {
            showFatal("Coey Ai's web bundle is missing from the app.")
            return
        }

        let http = LocalHTTPServer(root: resources)
        do {
            let port = try http.start()
            server = http
            installWebView(port: port)
        } catch {
            showFatal("The local web server could not start.")
        }
    }

    private func installWebView(port: UInt16) {
        let userContent = WKUserContentController()
        userContent.add(bridge, name: "coey")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContent
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.maximumZoomScale = 1
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        self.webView = webView
        bridge.webView = webView

        guard let url = URL(string: "http://127.0.0.1:\(port)/index.html") else {
            showFatal("The app could not build its local address.")
            return
        }
        webView.load(URLRequest(url: url))
    }

    private func showFatal(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }
}

extension WebHostController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "http" || scheme == "https" {
            let host = (url.host ?? "").lowercased()
            if host == "127.0.0.1" || host == "localhost" {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
            return
        }

        if ["mailto", "tel", "sms", "facetime", "facetime-audio"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }
}

extension WebHostController: WKUIDelegate {

    @available(iOS 15.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }
        return nil
    }
}

extension WebHostController: WKDownloadDelegate {

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let files = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let directory = files.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var name = suggestedFilename.isEmpty ? "Coey Ai chat.json" : suggestedFilename
        if (name as NSString).pathExtension.isEmpty { name += ".json" }

        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        lastDownloadURL = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = lastDownloadURL else { return }
        lastDownloadURL = nil

        let activity = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        present(activity, animated: true)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        lastDownloadURL = nil
    }
}
