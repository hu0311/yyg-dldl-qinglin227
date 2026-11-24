import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = WebViewController()
        window?.makeKeyAndVisible()
        // 游戏页需要长时间停留，禁止自动锁屏
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        UIApplication.shared.isIdleTimerDisabled = true
    }
}
