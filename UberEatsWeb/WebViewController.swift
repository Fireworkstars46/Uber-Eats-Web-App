import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let homeURL = URL(string: "https://www.ubereats.com/")!

    // Used only as a fallback when Uber tries to launch an uber:// or ubereats:// link.
    private let webLoginURL = URL(string: "https://auth.uber.com/v2/?localeCode=en-US&next_url=https%3A%2F%2Fwww.ubereats.com%2Flogin-redirect%2F%3Fredirect%3D%252F%26guest_mode%3Dfalse%26app_clip%3Dfalse")!

    // A manually loaded request comes back through the navigation delegate once more.
    // This key lets that second pass continue instead of creating a loop.
    private var forcedWebNavigationKey: String?

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let view = WKWebView(frame: .zero, configuration: config)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.keyboardDismissMode = .interactive

        // Some sites treat a normal WKWebView as an embedded app browser and push users
        // toward their native app. This identifies the wrapper as mobile Safari instead.
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
        return view
    }()

    private let toolbar: UIToolbar = {
        let view = UIToolbar()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .bar)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private lazy var backButton = button("chevron.backward", #selector(goBack), "Back")
    private lazy var forwardButton = button("chevron.forward", #selector(goForward), "Forward")
    private lazy var homeButton = button("house", #selector(goHome), "Uber Eats home")
    private lazy var reloadButton = button("arrow.clockwise", #selector(reloadPage), "Refresh")
    private lazy var browserButton = button("safari", #selector(openInBrowser), "Open in browser")

    private var progressObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(webView)
        view.addSubview(progressView)
        view.addSubview(toolbar)

        let space = UIBarButtonItem(systemItem: .flexibleSpace)
        toolbar.items = [backButton, space, forwardButton, space, homeButton, space, reloadButton, space, browserButton]

        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let progress = Float(webView.estimatedProgress)
                self.progressView.isHidden = progress >= 1
                self.progressView.setProgress(progress, animated: true)
            }
        }

        loadHome()
        updateButtons()
    }

    deinit {
        progressObservation?.invalidate()
    }

    private func button(_ imageName: String, _ action: Selector, _ label: String) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: imageName), style: .plain, target: self, action: action)
        item.accessibilityLabel = label
        return item
    }

    private func load(_ url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        webView.load(request)
    }

    private func loadHome() {
        load(homeURL)
    }

    private func loadWebLogin() {
        load(webLoginURL)
    }

    private func updateButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        browserButton.isEnabled = webView.url != nil
    }

    @objc private func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    @objc private func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    @objc private func goHome() {
        loadHome()
    }

    @objc private func reloadPage() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        webView.reload()
        sender.endRefreshing()
    }

    @objc private func openInBrowser() {
        guard let url = webView.url else { return }
        UIApplication.shared.open(url)
    }

    private func isUserActivatedWebNavigation(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated || action.targetFrame == nil
    }

    private func webSafeURL(_ originalURL: URL) -> URL {
        guard originalURL.host?.lowercased() == "auth.uber.com",
              var outer = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
              var outerItems = outer.queryItems else {
            return originalURL
        }

        // Uber currently labels its website login return path as a universal link.
        // Removing only that tracking flag keeps the return path as an ordinary webpage.
        for index in outerItems.indices where outerItems[index].name == "next_url" {
            guard let value = outerItems[index].value,
                  var nested = URLComponents(string: value) else {
                continue
            }

            nested.queryItems = nested.queryItems?.filter {
                !($0.name == "campaign" && $0.value == "signin_universal_link")
            }
            outerItems[index].value = nested.url?.absoluteString ?? value
        }

        outer.queryItems = outerItems
        return outer.url ?? originalURL
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let originalURL = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = originalURL.scheme?.lowercased() ?? ""

        if scheme == "http" || scheme == "https" {
            let safeURL = webSafeURL(originalURL)
            let key = safeURL.absoluteString

            // Allow the second pass generated by our manual webView.load call.
            if forcedWebNavigationKey == key {
                forcedWebNavigationKey = nil
                decisionHandler(.allow)
                return
            }

            // A user-tapped universal link can be handed to the installed Uber app.
            // Cancel that tap and load the exact request ourselves so it remains web content.
            if isUserActivatedWebNavigation(navigationAction) {
                var request = navigationAction.request
                request.url = safeURL
                forcedWebNavigationKey = key
                decisionHandler(.cancel)

                DispatchQueue.main.async { [weak self] in
                    self?.webView.load(request)
                }
                return
            }

            decisionHandler(.allow)
            return
        }

        if ["about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)

        if scheme == "uber" || scheme == "ubereats" {
            // Never hand an Uber deep link to the broken official app. Go to the real
            // browser-based sign-in page instead.
            DispatchQueue.main.async { [weak self] in
                self?.loadWebLogin()
            }
        } else if UIApplication.shared.canOpenURL(originalURL) {
            UIApplication.shared.open(originalURL)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        reloadButton.image = UIImage(systemName: "xmark")
        reloadButton.accessibilityLabel = "Stop loading"
        updateButtons()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        reloadButton.image = UIImage(systemName: "arrow.clockwise")
        reloadButton.accessibilityLabel = "Refresh"
        updateButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reloadButton.image = UIImage(systemName: "arrow.clockwise")
        reloadButton.accessibilityLabel = "Refresh"
        updateButtons()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reloadButton.image = UIImage(systemName: "arrow.clockwise")
        reloadButton.accessibilityLabel = "Refresh"
        updateButtons()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let originalURL = navigationAction.request.url {
            var request = navigationAction.request
            request.url = webSafeURL(originalURL)
            webView.load(request)
        }
        return nil
    }
}
