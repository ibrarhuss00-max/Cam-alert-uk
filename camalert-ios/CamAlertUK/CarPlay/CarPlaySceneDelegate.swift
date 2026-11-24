import UIKit
import CarPlay

/// CarPlay calls this when the iPhone is plugged into (or wirelessly paired with) a car.
/// Navigation apps get a window to draw the map in, so the `to window:` variants are used.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        CarPlayCoordinator.shared.connect(interfaceController, window: window)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        CarPlayCoordinator.shared.disconnect()
    }
}
