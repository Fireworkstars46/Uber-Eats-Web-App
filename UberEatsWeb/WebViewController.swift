import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let homeURL = URL(string: "https://www.ubereats.com/")!

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
                guard let self else { return }
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

    private func loadHome() {
        var request = URLRequest(url: homeURL)
        request.timeoutInterval = 60
        webView.load(request)
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)

        if scheme == "uber" || scheme == "ubereats" {
            let alert = UIAlertController(
                title: "App-only link",
                message: "That link tries to open the official Uber app. This wrapper keeps you on the website instead.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        } else if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
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

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
