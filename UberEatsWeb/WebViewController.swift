import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private enum BrowserMode: String {
        case mobile
        case desktop
    }

    private let homeURL = URL(string: "https://www.ubereats.com/")!
    private let webLoginURL = URL(string: "https://auth.uber.com/v2/?localeCode=en-US&next_url=https%3A%2F%2Fwww.ubereats.com%2Flogin-redirect%2F%3Fredirect%3D%252F%26guest_mode%3Dfalse%26app_clip%3Dfalse")!

    private let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
    private let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"

    private var browserMode: BrowserMode = .mobile
    private var forcedWebNavigationKey: String?
    private var debugEntries: [String] = []
    private let maximumDebugEntries = 80

    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let appGuardScript = #"""
    (function () {
      if (window.__uberEatsWebGlobalGuardInstalled) return;
      window.__uberEatsWebGlobalGuardInstalled = true;

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

      function isAuthenticationPage() {
        const host = currentHost();
        return host === 'auth.uber.com' || host.endsWith('.auth.uber.com');
      }

      function isUberAppScheme(value) {
        const url = normalize(value).toLowerCase();
        return url.startsWith('uber:') || url.startsWith('ubereats:');
      }

      function isWebLoginURL(value) {
        const url = normalize(value).toLowerCase();
        return url.includes('auth.uber.com') ||
               url.includes('signin_universal_link') ||
               url.includes('/login-redirect') ||
               url.includes('/login?') ||
               url.endsWith('/login');
      }

      function postGuardEvent(type, value, detail) {
        try {
          window.webkit.messageHandlers.appGuardEvent.postMessage({
            type: String(type || ''),
            url: normalize(value),
            page: window.location.href,
            detail: String(detail || '')
          });
        } catch (_) {}
      }

      function startWebLogin(value) {
        try {
          window.webkit.messageHandlers.forceWebLogin.postMessage(normalize(value));
        } catch (_) {}
      }

      function stopEvent(event) {
        if (!event) return;
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
      }

      function elementText(element) {
        return String(
          (element && (element.innerText || element.textContent || element.getAttribute('aria-label'))) || ''
        ).trim().toLowerCase();
      }

      function firstInterestingAttribute(element) {
        if (!element || !element.attributes) return '';

        const importantNames = [
          'href', 'data-href', 'data-url', 'data-link', 'data-deeplink',
          'data-deep-link', 'data-app-link', 'data-universal-link', 'onclick'
        ];

        for (const name of importantNames) {
          const value = element.getAttribute && element.getAttribute(name);
          if (value && (isUberAppScheme(value) || /deep.?link|app.?link|open.?app/i.test(value))) {
            return value;
          }
        }

        return '';
      }

      function closestActionElement(target) {
        return target && target.closest
          ? target.closest('a, button, input, [role="button"], [data-testid], [onclick]')
          : null;
      }

      document.addEventListener('click', function (event) {
        const target = closestActionElement(event.target);
        if (!target) return;

        const href = target.href ||
          target.getAttribute('href') ||
          target.getAttribute('data-blocked-uber-link') ||
          target.getAttribute('data-href') ||
          target.getAttribute('data-url') ||
          '';

        const attributeLink = firstInterestingAttribute(target);
        const text = elementText(target);
        const looksLikeLoginButton =
          text === 'log in' || text === 'login' || text === 'sign in' ||
          text.startsWith('log in ') || text.startsWith('sign in ');
        const looksLikeOpenAppButton =
          text.includes('open in app') || text.includes('use the app') ||
          text.includes('continue in app') || text.includes('view in app');

        const appValue = isUberAppScheme(href) ? href :
          (isUberAppScheme(attributeLink) ? attributeLink : '');

        if (appValue || looksLikeOpenAppButton) {
          stopEvent(event);
          postGuardEvent('blocked-app-click', appValue || href, text);
          return;
        }

        if (!isAuthenticationPage() && (isWebLoginURL(href) || looksLikeLoginButton)) {
          stopEvent(event);
          postGuardEvent('web-login-click', href, text);
          startWebLogin(isWebLoginURL(href) ? href : '');
        }
      }, true);

      document.addEventListener('submit', function (event) {
        if (isAuthenticationPage()) return;

        const form = event.target;
        const action = form && form.action ? form.action : '';
        if (isUberAppScheme(action)) {
          stopEvent(event);
          postGuardEvent('blocked-app-form', action, '');
        } else if (isWebLoginURL(action)) {
          stopEvent(event);
          postGuardEvent('web-login-form', action, '');
          startWebLogin(action);
        }
      }, true);

      const originalOpen = window.open;
      window.open = function (url) {
        if (isUberAppScheme(url)) {
          postGuardEvent('blocked-window-open', url, '');
          return null;
        }

        if (!isAuthenticationPage() && isWebLoginURL(url)) {
          postGuardEvent('web-login-window-open', url, '');
          startWebLogin(url);
          return null;
        }

        return originalOpen.apply(window, arguments);
      };

      const originalAnchorClick = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        const href = this.href || this.getAttribute('href') || '';
        if (isUberAppScheme(href)) {
          postGuardEvent('blocked-programmatic-anchor', href, elementText(this));
          return;
        }
        return originalAnchorClick.apply(this, arguments);
      };

      try {
        const originalAssign = window.location.assign.bind(window.location);
        window.location.assign = function (url) {
          if (isUberAppScheme(url)) {
            postGuardEvent('blocked-location-assign', url, '');
            return;
          }
          return originalAssign(url);
        };
      } catch (_) {}

      try {
        const originalReplace = window.location.replace.bind(window.location);
        window.location.replace = function (url) {
          if (isUberAppScheme(url)) {
            postGuardEvent('blocked-location-replace', url, '');
            return;
          }
          return originalReplace(url);
        };
      } catch (_) {}

      function neutralizeElement(element) {
        if (!element || element.nodeType !== 1) return;

        const href = element.getAttribute && element.getAttribute('href');
        if (href && isUberAppScheme(href)) {
          element.setAttribute('data-blocked-uber-link', href);
          element.setAttribute('href', '#');
          element.removeAttribute('target');
          postGuardEvent('neutralized-app-link', href, elementText(element));
        }

        if (element.querySelectorAll) {
          element.querySelectorAll('a[href^="uber:"], a[href^="ubereats:"]').forEach(function (link) {
            const original = link.getAttribute('href') || '';
            link.setAttribute('data-blocked-uber-link', original);
            link.setAttribute('href', '#');
            link.removeAttribute('target');
          });
        }
      }

      neutralizeElement(document.documentElement);

      new MutationObserver(function (mutations) {
        mutations.forEach(function (mutation) {
          if (mutation.type === 'attributes') {
            neutralizeElement(mutation.target);
          }
          mutation.addedNodes.forEach(neutralizeElement);
        });
      }).observe(document.documentElement || document, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['href', 'data-href', 'data-url', 'data-deeplink', 'data-deep-link']
      });
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
            source: Self.appGuardScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: "forceWebLogin")
        config.userContentController.add(self, name: "appGuardEvent")

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
    private lazy var modeButton = button("iphone", #selector(toggleBrowserMode), "Mobile mode. Tap for Desktop mode")
    private lazy var loginButton = button("person.crop.circle", #selector(openWebLogin), "Web login")
    private lazy var debugButton = button("ladybug", #selector(showDebugLog), "Debug log")
    private lazy var reloadButton = button("arrow.clockwise", #selector(reloadPage), "Refresh")

    private var progressObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        browserMode = BrowserMode(
            rawValue: UserDefaults.standard.string(forKey: "UberEatsWebBrowserMode") ?? "mobile"
        ) ?? .mobile
        applyBrowserMode(reload: false)

        view.addSubview(webView)
        view.addSubview(progressView)
        view.addSubview(toolbar)

        let space = UIBarButtonItem(systemItem: .flexibleSpace)
        toolbar.items = [
            backButton, space,
            forwardButton, space,
            homeButton, space,
            modeButton, space,
            loginButton, space,
            debugButton, space,
            reloadButton
        ]

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

        appendDebug("App opened in \(browserMode.rawValue) mode")
        loadHome()
        updateButtons()
    }

    deinit {
        progressObservation?.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "forceWebLogin")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "appGuardEvent")
    }

    private func button(_ imageName: String, _ action: Selector, _ label: String) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: imageName),
            style: .plain,
            target: self,
            action: action
        )
        item.accessibilityLabel = label
        return item
    }

    private func appendDebug(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        debugEntries.append("[\(timestamp)] \(message)")
        if debugEntries.count > maximumDebugEntries {
            debugEntries.removeFirst(debugEntries.count - maximumDebugEntries)
        }
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

        appendDebug("Opening web login: \(destination.absoluteString)")
        forcedWebNavigationKey = destination.absoluteString
        load(destination)
    }

    private func applyBrowserMode(reload: Bool) {
        UserDefaults.standard.set(browserMode.rawValue, forKey: "UberEatsWebBrowserMode")

        switch browserMode {
        case .mobile:
            webView.customUserAgent = mobileUserAgent
            modeButton.image = UIImage(systemName: "iphone")
            modeButton.accessibilityLabel = "Mobile mode. Tap for Desktop mode"
        case .desktop:
            webView.customUserAgent = desktopUserAgent
            modeButton.image = UIImage(systemName: "desktopcomputer")
            modeButton.accessibilityLabel = "Desktop mode. Tap for Mobile mode"
        }

        appendDebug("Mode changed to \(browserMode.rawValue)")

        if reload, let currentURL = webView.url {
            forcedWebNavigationKey = currentURL.absoluteString
            load(currentURL)
        }
    }

    private func isCurrentlyAuthenticating() -> Bool {
        isUberAuthenticationHost(webView.url?.host)
    }

    private func webFallbackURL(for appURL: URL) -> URL? {
        guard let components = URLComponents(url: appURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let possibleURLNames = [
            "url", "link", "target", "fallback", "fallback_url", "web_url",
            "deeplink", "deep_link", "app_link", "universal_link"
        ]

        for item in components.queryItems ?? [] where possibleURLNames.contains(item.name.lowercased()) {
            guard let value = item.value,
                  let decodedURL = URL(string: value),
                  let scheme = decodedURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }
            return decodedURL
        }

        guard appURL.scheme?.lowercased() == "ubereats" else { return nil }

        var pathParts: [String] = []
        if let host = appURL.host, !host.isEmpty {
            pathParts.append(host)
        }
        pathParts.append(contentsOf: appURL.pathComponents.filter { $0 != "/" })

        guard !pathParts.isEmpty else { return nil }

        var webComponents = URLComponents(string: "https://www.ubereats.com/")!
        webComponents.path = "/" + pathParts.joined(separator: "/")
        webComponents.queryItems = components.queryItems
        return webComponents.url
    }

    private func handleBlockedUberAppLink(_ appURL: URL?) {
        let text = appURL?.absoluteString ?? "Unknown Uber app link"
        appendDebug("Blocked official-app link: \(text)")

        if isCurrentlyAuthenticating() {
            appendDebug("Authentication appears complete; returning to Uber Eats website")
            loadHome()
            return
        }

        if let appURL = appURL {
            let lowercaseURL = appURL.absoluteString.lowercased()
            if lowercaseURL.contains("login") || lowercaseURL.contains("signin") {
                loadWebLogin()
                return
            }

            if let fallbackURL = webFallbackURL(for: appURL) {
                appendDebug("Using web fallback: \(fallbackURL.absoluteString)")
                forcedWebNavigationKey = fallbackURL.absoluteString
                load(fallbackURL)
                return
            }
        }

        appendDebug("No web fallback found; stayed on the current page")
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

    @objc private func toggleBrowserMode() {
        browserMode = browserMode == .mobile ? .desktop : .mobile
        applyBrowserMode(reload: true)
    }

    @objc private func openWebLogin() {
        loadWebLogin()
    }

    @objc private func showDebugLog() {
        let modeName = browserMode == .mobile ? "Mobile" : "Desktop"
        let currentURL = webView.url?.absoluteString ?? "No page loaded"
        let entries = debugEntries.isEmpty ? "No events have been recorded." : debugEntries.joined(separator: "\n")
        let report = "Mode: \(modeName)\nCurrent page: \(currentURL)\n\n\(entries)"

        let alert = UIAlertController(
            title: "Uber Eats Web Debug",
            message: report,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = report
        })
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            self?.debugEntries.removeAll()
            self?.appendDebug("Debug log cleared")
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
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

    private func navigationTypeName(_ type: WKNavigationType) -> String {
        switch type {
        case .linkActivated: return "link"
        case .formSubmitted: return "form-submit"
        case .backForward: return "back-forward"
        case .reload: return "reload"
        case .formResubmitted: return "form-resubmit"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "forceWebLogin" {
            let raw = message.body as? String ?? ""
            let requestedURL = URL(string: raw)
            let requestedScheme = requestedURL?.scheme?.lowercased() ?? ""

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if requestedScheme == "uber" || requestedScheme == "ubereats" {
                    self.handleBlockedUberAppLink(requestedURL)
                } else if self.isCurrentlyAuthenticating() {
                    self.appendDebug("Ignored login restart while authentication is in progress")
                } else {
                    self.loadWebLogin(requestedURL)
                }
            }
            return
        }

        if message.name == "appGuardEvent" {
            guard let event = message.body as? [String: Any] else { return }
            let type = event["type"] as? String ?? "guard-event"
            let url = event["url"] as? String ?? ""
            let detail = event["detail"] as? String ?? ""
            appendDebug("JS \(type): \(url) \(detail)")
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.preferredContentMode = browserMode == .mobile ? .mobile : .desktop

        guard let originalURL = navigationAction.request.url else {
            appendDebug("Cancelled navigation with no URL")
            decisionHandler(.cancel, preferences)
            return
        }

        let scheme = originalURL.scheme?.lowercased() ?? ""
        let typeName = navigationTypeName(navigationAction.navigationType)
        appendDebug("Navigation \(typeName): \(originalURL.absoluteString)")

        if scheme == "http" || scheme == "https" {
            let safeURL = webSafeURL(originalURL)
            let key = safeURL.absoluteString

            if forcedWebNavigationKey == key {
                forcedWebNavigationKey = nil
                decisionHandler(.allow, preferences)
                return
            }

            let sourceIsAuth = isUberAuthenticationHost(webView.url?.host)
            let destinationIsAuth = isUberAuthenticationHost(safeURL.host)
            let enteringAuthentication = destinationIsAuth && !sourceIsAuth
            let URLWasSanitized = safeURL != originalURL

            if sourceIsAuth {
                // Never interfere with Uber's phone/email, password, code, consent,
                // or completion steps while authentication is active.
                decisionHandler(.allow, preferences)
                return
            }

            // Cancel every user-tapped web navigation outside auth and reload it ourselves.
            // This prevents iOS from handing Uber universal links to the official app.
            if isUserActivatedWebNavigation(navigationAction) || enteringAuthentication || URLWasSanitized {
                var request = navigationAction.request
                request.url = safeURL
                forcedWebNavigationKey = key
                appendDebug("Forced navigation to remain in web view")
                decisionHandler(.cancel, preferences)

                DispatchQueue.main.async { [weak self] in
                    self?.webView.load(request)
                }
                return
            }

            decisionHandler(.allow, preferences)
            return
        }

        if ["about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow, preferences)
            return
        }

        decisionHandler(.cancel, preferences)

        if scheme == "uber" || scheme == "ubereats" {
            DispatchQueue.main.async { [weak self] in
                self?.handleBlockedUberAppLink(originalURL)
            }
        } else {
            appendDebug("Cancelled external scheme: \(originalURL.absoluteString)")
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
        appendDebug("Finished: \(webView.url?.absoluteString ?? "Unknown page")")
        updateButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reloadButton.image = UIImage(systemName: "arrow.clockwise")
        reloadButton.accessibilityLabel = "Refresh"
        appendDebug("Navigation failed: \(error.localizedDescription)")
        updateButtons()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reloadButton.image = UIImage(systemName: "arrow.clockwise")
        reloadButton.accessibilityLabel = "Refresh"
        appendDebug("Page failed to start: \(error.localizedDescription)")
        updateButtons()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let originalURL = navigationAction.request.url else {
            return nil
        }

        let scheme = originalURL.scheme?.lowercased() ?? ""
        appendDebug("Popup requested: \(originalURL.absoluteString)")

        if scheme == "uber" || scheme == "ubereats" {
            handleBlockedUberAppLink(originalURL)
            return nil
        }

        if scheme == "http" || scheme == "https" {
            var request = navigationAction.request
            let safeURL = webSafeURL(originalURL)
            request.url = safeURL
            forcedWebNavigationKey = safeURL.absoluteString
            webView.load(request)
        }
        return nil
    }
}
