import UIKit
import SwiftUI

// The app uses UIKit scenes so that one app can have two windows: the iPhone screen
// (PhoneSceneDelegate) and the car screen (CarPlaySceneDelegate). Info.plist maps each
// scene role to its delegate.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        true
    }
}

final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: windowScene)
        w.rootViewController = UIHostingController(rootView: PhoneRootView())
        w.makeKeyAndVisible()
        window = w
    }
}
