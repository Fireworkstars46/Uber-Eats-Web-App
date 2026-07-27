import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let homeURL = URL(string: "https://www.ubereats.com/")!

    private let webLoginURL = URL(string: "https://auth.uber.com/v2/?localeCode=en-US&next_url=https%3A%2F%2Fwww.ubereats.com%2Flogin-redirect%2F%3Fredirect%3D%252F%26guest_mode%3Dfalse%26app_clip%3Dfalse")!

    private var forcedWebNavigationKey: String?

    private static let loginInterceptorScript = #"""
    (function () {
      if (window.__uberEatsWebLoginInterceptorInstalled) return;
      window.__uberEatsWebLoginInterceptorInstalled = true;

      function normalize(value) {
        try {
          return new URL(String(value || ''), window.location.href).href;
        } catch (_) {
          return String(value || '');
        }
      }

      function currentHost() {
        return String(window.location.hostname || '').toLowerCase();
      }

      function isInsideUberAuthentication() {
        const host = currentHost();
        return host === 'auth.uber.com' || host.endsWith('.auth.uber.com');
      }

      function isUberAppURL(value) {
        const url = normalize(value).toLowerCase();
        return url.startsWith('uber:') || url.startsWith('ubereats:');
      }

      function isUberWebLoginURL(value) {
        const url = normalize(value).toLowerCase();
        return url.includes('auth.uber.com') ||
               url.includes('signin_universal_link') ||
               url.includes('/login-redirect') ||
               url.includes('/login?') ||
               url.endsWith('/login');
      }

      function sendToNative(value) {
        const url = normalize(value);
        try {
          window.webkit.messageHandlers.forceWebLogin.postMessage(url);
        } catch (_) {}
      }

      function elementText(element) {
        return String(
          (element && (element.innerText || element.textContent || element.getAttribute('aria-label'))) || ''
        ).trim().toLowerCase();
      }

      document.addEventListener('click', function (event) {
        const target = event.target && event.target.closest
          ? event.target.closest('a, button, [role="button"], [data-testid]')
          : null;

        if (!target) return;

        const href = target.href || target.getAttribute('href') || target.getAttribute('data-href') || '';
        const text = elementText(target);
        const looksLikeLoginButton =
          text === 'log in' || text === 'login' || text === 'sign in' ||
          text.startsWith('log in ') || text.startsWith('sign in ');

        const mustBlockAppLink = isUberAppURL(href);
        const mustStartWebLogin = !isInsideUberAuthentication() &&
          (isUberWebLoginURL(href) || looksLikeLoginButton);

        if (mustBlockAppLink || mustStartWebLogin) {
          event.preventDefault();
          event.stopPropagation();
          event.stopImmediatePropagation();
          sendToNative((mustBlockAppLink || isUberWebLoginURL(href)) ? href : '');
        }
      }, true);

      document.addEventListener('submit', function (event) {
        const form = event.target;
        const action = form && form.action ? form.action : '';

        // Never interfere with forms once the user is on auth.uber.com. Those forms
        // are the phone/email, password, verification-code, and consent steps.
        if (isInsideUberAuthentication()) return;

        if (isUberAppURL(action) || isUberWebLoginURL(action)) {
          event.preventDefault();
          event.stopPropagation();
          event.stopImmediatePropagation();
          sendToNative(action);
        }
      }, true);

      const originalOpen = window.open;
      window.open = function (url) {
        const mustBlockAppLink = isUberAppURL(url);
        const mustStartWebLogin = !isInsideUberAuthentication() && isUberWebLoginURL(url);

        if (mustBlockAppLink || mustStartWebLogin) {
          sendToNative(url);
          return null;
        }
        return originalOpen.apply(window, arguments);
      };

      function neutralizeAppLinks(root) {
        const scope = root && root.querySelectorAll ? root : document;
        scope.querySelectorAll('a[href^="uber:"], a[href^="ubereats:"]').forEach(function (link) {
          link.setAttribute('data-blocked-uber-link', link.getAttribute('href') || '');
          link.setAttribute('href', '#');
          link.removeAttribute('target');
        });
      }

      neutralizeAppLinks(document);
      new MutationObserver(function (mutations) {
        mutations.forEach(function (mutation) {
          mutation.addedNodes.forEach(function (node) {
            neutralizeAppLinks(node);
          });
        });
      }).observe(document.documentElement || document, { childList: true, subtree: true });
    })();
    """#

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let userScript = WKUserScript(
            source: Self.loginInterceptorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: "forceWebLogin")

        let view = WKWebView(frame: .zero, configuration: config)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.keyboardDismissMode = .interactive
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
    private lazy var loginButton = button("person.crop.circle", #selector(openWebLogin), "Web login")
    private lazy var reloadButton = button("arrow.clockwise", #selector(reloadPage), "Refresh")

    private var progressObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(webView)
        view.addSubview(progressView)
        view.addSubview(toolbar)

        let space = UIBarButtonItem(systemItem: .flexibleSpace)
        toolbar.items = [backButton, space, forwardButton, space, homeButton, space, loginButton, space, reloadButton]

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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "forceWebLogin")
    }

    private func button(_ imageName: String, _ action: Selector, _ label: String) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: imageName), style: .plain, target: self, action: action)
        item.accessibilityLabel = label
        return item
    }

    private func load(_ url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadRevalidatingCacheData
        webView.load(request)
    }

    private func loadHome() {
        load(homeURL)
    }

    private func loadWebLogin(_ requestedURL: URL? = nil) {
        let destination: URL
        if let requestedURL = requestedURL,
           let scheme = requestedURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            destination = webSafeURL(requestedURL)
        } else {
            destination = webLoginURL
        }

        forcedWebNavigationKey = destination.absoluteString
        load(destination)
    }

    private func isCurrentlyAuthenticating() -> Bool {
        webView.url?.host?.lowercased() == "auth.uber.com"
    }

    private func handleBlockedUberAppLink() {
        if isCurrentlyAuthenticating() {
            // At the end of authentication Uber may try to return through its native app.
            // The web session cookies should already exist, so return to the website instead.
            loadHome()
        } else {
            loadWebLogin()
        }
    }

    private func updateButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
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

    @objc private func openWebLogin() {
        loadWebLogin()
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

    private func isUserActivatedWebNavigation(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated || action.targetFrame == nil
    }

    private func isUberAuthenticationHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "auth.uber.com" || host.hasSuffix(".auth.uber.com")
    }

    private func webSafeURL(_ originalURL: URL) -> URL {
        guard isUberAuthenticationHost(originalURL.host),
              var outer = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
              var outerItems = outer.queryItems else {
            return originalURL
        }

        for index in outerItems.indices where outerItems[index].name == "next_url" {
            guard let value = outerItems[index].value,
                  var nested = URLComponents(string: value) else {
                continue
            }

            nested.queryItems = nested.queryItems?.filter {
                !(($0.name == "campaign" && $0.value == "signin_universal_link") ||
                  $0.name == "deep_link" ||
                  $0.name == "app_link")
            }
            outerItems[index].value = nested.url?.absoluteString ?? value
        }

        outer.queryItems = outerItems.filter {
            !(($0.name == "campaign" && $0.value == "signin_universal_link") ||
              $0.name == "deep_link" ||
              $0.name == "app_link")
        }
        return outer.url ?? originalURL
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "forceWebLogin" else { return }

        let raw = message.body as? String ?? ""
        let requestedURL = URL(string: raw)
        let requestedScheme = requestedURL?.scheme?.lowercased() ?? ""

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if requestedScheme == "uber" || requestedScheme == "ubereats" {
                self.handleBlockedUberAppLink()
            } else if self.isCurrentlyAuthenticating() {
                // Never restart an authentication flow that is already in progress.
                return
            } else {
                self.loadWebLogin(requestedURL)
            }
        }
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

            if forcedWebNavigationKey == key {
                forcedWebNavigationKey = nil
                decisionHandler(.allow)
                return
            }

            let sourceIsAuth = isUberAuthenticationHost(webView.url?.host)
            let destinationIsAuth = isUberAuthenticationHost(safeURL.host)
            let enteringAuthentication = destinationIsAuth && !sourceIsAuth
            let URLWasSanitized = safeURL != originalURL

            // Only manually reload the initial jump into web authentication. Once the
            // browser is on auth.uber.com, allow every form and next-step navigation.
            if isUserActivatedWebNavigation(navigationAction) &&
               (enteringAuthentication || URLWasSanitized) {
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
            DispatchQueue.main.async { [weak self] in
                self?.handleBlockedUberAppLink()
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
            let scheme = originalURL.scheme?.lowercased() ?? ""
            if scheme == "uber" || scheme == "ubereats" {
                handleBlockedUberAppLink()
            } else {
                var request = navigationAction.request
                request.url = webSafeURL(originalURL)
                webView.load(request)
            }
        }
        return nil
    }
}
