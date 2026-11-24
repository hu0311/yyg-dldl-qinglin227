import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // 游戏入口地址（gid=227 斗罗大陆H5青春麒麟服）
    private let startURL = URL(string: "https://www.youyougu.cn/?ct=h5login&gid=227")!

    private var webView: WKWebView!
    private var retryView: UIView?
    private var retryLabel: UILabel?
    private var retryCount = 0

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
        config.websiteDataStore = .default()   // Cookie 落盘，退出重进不掉登录
        config.applicationNameForUserAgent = "Safari/604.1"

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black

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

        loadStart()
    }

    private func loadStart() {
        var request = URLRequest(url: startURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        webView.load(request)
    }

    // MARK: - 加载失败重试

    private func showRetry(_ message: String, autoRetry: Bool) {
        hideRetry()
        let container = UIView(frame: view.bounds)
        container.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let label = UILabel()
        label.text = "网络连接失败，请检查网络\n\n\(message)"
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false

        let button = UIButton(type: .system)
        button.setTitle("重新加载", for: .normal)
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
        retryLabel = label

        if autoRetry && retryCount < 3 {
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.retryView != nil else { return }
                self.loadStart()
            }
        }
    }

    private func hideRetry() {
        retryView?.removeFromSuperview()
        retryView = nil
        retryLabel = nil
    }

    @objc private func retryTapped() {
        retryCount = 0
        hideRetry()
        loadStart()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryCount = 0
        hideRetry()
        webView.evaluateJavaScript("""
        (function(){
          var m = document.querySelector('meta[name=viewport]');
          if (m) { m.setAttribute('content','width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no,viewport-fit=cover'); }
          document.documentElement.style.webkitTouchCallout='none';
        })();
        """, completionHandler: nil)
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
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "file" {
            decisionHandler(.allow)
            return
        }
        // weixin:// alipays:// tel: itms-services: 等交给系统
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        decisionHandler(.cancel)
    }

    // MARK: - WKUIDelegate（H5 弹窗、target=_blank）

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

    func webViewDidClose(_ webView: WKWebView) {}
}
