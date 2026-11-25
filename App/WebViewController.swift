import UIKit
import WebKit

/// H5 游戏壳：黑屏自愈 + 支付页留在 App 内
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // 游戏入口地址（gid=227 斗罗大陆H5青春麒麟服）
    private let startURL = URL(string: "https://www.youyougu.cn/?ct=h5login&gid=227")!

    private var webView: WKWebView!
    private var retryView: UIView?
    private var retryCount = 0
    private var blankCheck: DispatchWorkItem?
    private var lastContentURL: URL?
    private var popupVC: PopupViewController?
    private var pendingExternalPay = false
    private var crashCount = 0
    private var lastCrash: Date?

    override var prefersStatusBarHidden: Bool { return true }
    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .all }
    override var shouldAutorotate: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = .default()          // Cookie 落盘，退出重进不掉登录
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.applicationNameForUserAgent = "Safari/604.1"

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.scrollView.bounces = false
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true                        // 不透明渲染，避免整屏黑块
        webView.backgroundColor = .black
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = .black
        }

        if #available(iOS 16.4, *) {
            webView.isInspectable = false
        }

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)

        loadStart()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 加载

    private func loadStart() {
        var request = URLRequest(url: startURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        webView.load(request)
    }

    /// 支付 / 外部 App 回来后回到游戏页，而不是停在支付中转页
    private func backToGame() {
        if let url = lastContentURL, url.absoluteString != webView.url?.absoluteString {
            webView.load(URLRequest(url: url))
        } else if webView.url == nil {
            loadStart()
        } else {
            webView.reload()
        }
    }

    // MARK: - 失败提示

    private func showRetry(_ message: String, autoRetry: Bool) {
        hideRetry()
        let container = UIView(frame: view.bounds)
        container.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let label = UILabel()
        label.text = "游戏加载失败，请检查网络\n\n\(message)"
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false

        let button = UIButton(type: .system)
        button.setTitle("重新进入游戏", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        button.backgroundColor = UIColor(red: 0.85, green: 0.18, blue: 0.15, alpha: 1.0)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        container.addSubview(label)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 28),
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.widthAnchor.constraint(equalToConstant: 176),
            button.heightAnchor.constraint(equalToConstant: 46)
        ])

        view.addSubview(container)
        retryView = container

        if autoRetry && retryCount < 3 {
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.retryView != nil else { return }
                self.hideRetry()
                self.loadStart()
            }
        }
    }

    private func hideRetry() {
        retryView?.removeFromSuperview()
        retryView = nil
    }

    @objc private func retryTapped() {
        retryCount = 0
        hideRetry()
        backToGame()
    }

    // MARK: - 黑屏自愈

    private func scheduleBlankCheck() {
        blankCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkBlank() }
        blankCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// 加载完成却没有任何可见内容时判为黑屏，自动重载；三次仍空白给手动入口
    private func checkBlank() {
        let js = """
        (function(){
          try{
            var b=document.body;
            if(!b) return 0;
            var text=(b.innerText||'').replace(/\\s/g,'').length;
            var canvas=document.querySelectorAll('canvas').length;
            var frames=document.querySelectorAll('iframe').length;
            var imgs=b.querySelectorAll('img').length;
            return (text>0 || canvas>0 || frames>0 || imgs>1) ? 1 : 0;
          }catch(e){ return 1; }
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self = self else { return }
            if let n = value as? NSNumber, n.intValue == 1 {
                self.retryCount = 0
                return
            }
            self.retryCount += 1
            if self.retryCount <= 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.webView.reload()
                }
            } else {
                self.showRetry("页面长时间空白，可能内存不足被系统回收", autoRetry: false)
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        if let last = lastCrash, now.timeIntervalSince(last) < 20 {
            crashCount += 1
        } else {
            crashCount = 0
        }
        lastCrash = now

        if crashCount >= 3 {
            showRetry("游戏进程被系统回收（内存不足）", autoRetry: false)
        } else {
            webView.reload()
        }
    }

    // MARK: - 前后台切换（支付返回）

    @objc private func appDidBecomeActive() {
        guard pendingExternalPay else { return }
        pendingExternalPay = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.backToGame()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideRetry()
        if let url = webView.url, url.absoluteString.hasPrefix("http") {
            lastContentURL = url
        }
        webView.evaluateJavaScript("""
        (function(){
          var m = document.querySelector('meta[name=viewport]');
          if (m) { m.setAttribute('content','width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no,viewport-fit=cover'); }
          document.documentElement.style.webkitTouchCallout='none';
          window.dispatchEvent(new Event('resize'));
          setTimeout(function(){ window.dispatchEvent(new Event('resize')); }, 300);
        })();
        """, completionHandler: nil)
        scheduleBlankCheck()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    private func handle(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        showRetry(ns.localizedDescription, autoRetry: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file" || scheme == "data" {
            decisionHandler(.allow)
            return
        }
        openExternal(url)
        decisionHandler(.cancel)
    }

    private func openExternal(_ url: URL) {
        let scheme = (url.scheme ?? "").lowercased()
        let paySchemes = ["weixin", "wechat", "alipay", "alipays", "mqq", "mqqapi"]
        if paySchemes.contains(where: { scheme.hasPrefix($0) }) {
            pendingExternalPay = true
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] ok in
            guard let self = self else { return }
            if !ok {
                self.pendingExternalPay = false
                self.backToGame()
            }
        }
    }

    // MARK: - WKUIDelegate（新窗口 / 支付页）

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }

        if let url = navigationAction.request.url {
            let scheme = (url.scheme ?? "").lowercased()
            if !(scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file") {
                openExternal(url)
                return nil
            }
        }

        // 已有浮层就直接复用，避免叠多层
        if let existing = popupVC {
            existing.webView.load(navigationAction.request)
            return existing.webView
        }

        // 用 App 内浮层承载，支付页 / 协议页都留在 App 里，不跳 Safari
        let vc = PopupViewController(configuration: configuration, request: navigationAction.request)
        vc.onClose = { [weak self] in
            guard let self = self else { return }
            self.popupVC?.dismiss(animated: true) { [weak self] in
                self?.popupVC = nil
                self?.backToGame()
            }
        }
        vc.modalPresentationStyle = .fullScreen
        popupVC = vc
        present(vc, animated: true)
        return vc.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupVC?.onClose?()
    }

    // MARK: - JS 弹窗

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(defaultText)
    }
}

/// 站内浮层：承载 window.open / 支付中转页，支付成功或手动关闭后回到游戏
final class PopupViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    let webView: WKWebView
    var onClose: (() -> Void)?

    private let bar = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    init(configuration: WKWebViewConfiguration, request: URLRequest) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true
        webView.load(request)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { return false }
    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        bar.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        bar.translatesAutoresizingMaskIntoConstraints = false

        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        titleLabel.text = "充值"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 15)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        webView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(bar)
        bar.addSubview(closeButton)
        bar.addSubview(titleLabel)
        view.addSubview(webView)

        let top = view.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: top),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),

            closeButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            closeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 56),

            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func closeTapped() {
        onClose?()
    }

    // 支付成功页自动关闭，回到游戏
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let t = webView.title, !t.isEmpty {
            titleLabel.text = t
        }
        let js = """
        (function(){
          var t=(document.body?document.body.innerText:'').replace(/\\s/g,'');
          if(t.indexOf('支付成功')>=0 || t.indexOf('充值成功')>=0 || t.indexOf('购买成功')>=0){ return 1; }
          return 0;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            if let n = value as? NSNumber, n.intValue == 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.onClose?() }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file" || scheme == "data" {
            decisionHandler(.allow)
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            let scheme = (url.scheme ?? "").lowercased()
            if scheme == "http" || scheme == "https" {
                webView.load(navigationAction.request)
            } else {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }
}
