import UIKit
import SwiftUI
import Intents

@objc class AppDelegate: UIResponder, UIApplicationDelegate {
    
    /// Set to `.portrait` when the springboard is visible so that only the
    /// home screen is locked to portrait while the rest of the app can rotate.
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    /// Puts the interface into `orientationLock`, turning the window when the
    /// orientation it is currently in has just stopped being allowed.
    ///
    /// Narrowing the mask is not enough on its own. UIKit re-resolves orientation
    /// off a device event, and leaving a landscape app for the springboard is not
    /// one — the phone lies exactly where it was. Without an explicit request the
    /// window keeps that landscape and the springboard, which has only a portrait
    /// layout, is drawn sideways into it.
    ///
    /// Returns whether a turn was actually asked for, so a caller that must not draw
    /// until the window has turned knows whether it has anything to wait for.
    @discardableResult
    static func applyOrientationLock() -> Bool {
        applyOrientationLock(retriesLeft: 2)
    }

    @discardableResult
    private static func applyOrientationLock(retriesLeft: Int) -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first else { return false }

        // Every window in the scene, not just the key one. This app keeps overlay
        // windows above its own — the multitask host, the rotation readout — and
        // whichever of them happens to be key may have no root controller at all,
        // in which case asking only the key window asks nobody.
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        let current = mask(for: scene.interfaceOrientation)
        guard !current.isEmpty, !orientationLock.contains(current) else { return false }

        // The member of the mask the device is actually pointing at, where the mask
        // allows more than one. Handing UIKit the whole set lets it choose, and on a
        // landscape pair it can settle on the turn the user is not holding — which
        // also silently undoes a caller that asked for a specific one a moment
        // earlier, as the way back from the switcher does.
        var requested = orientationLock
        if let facing = interfaceOrientation(matchingDevice: UIDevice.current.orientation) {
            let facingMask = mask(for: facing)
            if !facingMask.isEmpty, orientationLock.contains(facingMask) {
                requested = facingMask
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: requested)) { _ in
            // Refusals are not exceptional here, and silence is the worst outcome.
            //
            // The request is validated against the supported set UIKit currently
            // believes in, and `setNeedsUpdateOfSupportedInterfaceOrientations` above
            // only marks that set for re-resolution — it does not re-resolve it. So a
            // request made in the same turn of the run loop as the mask that permits
            // it can be refused, and with no handler it was refused silently: nothing
            // turned, nothing asked again, and whatever was waiting for the turn ran
            // out its patience and drew itself the wrong way round.
            //
            // The next turn of the run loop is after that re-resolution. Bounded, and
            // re-entrant through the front door so it re-reads the lock rather than
            // repeating a stale one — by then the destination may have changed.
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.async { _ = applyOrientationLock(retriesLeft: retriesLeft - 1) }
        }
        return true
    }

    /// The interface orientation a device reading corresponds to, or nil for face up,
    /// face down and unknown, which describe the phone's relationship to the ground
    /// rather than to the viewer and name no interface orientation at all.
    static func interfaceOrientation(matchingDevice device: UIDeviceOrientation) -> UIInterfaceOrientation? {
        switch device {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight   // device and interface axes are mirrored
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }

    /// The single-orientation mask an interface orientation belongs to, so it can
    /// be tested against `orientationLock`. Empty for `.unknown`, which no mask
    /// contains and which nothing should be turned away from.
    static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return []
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
        application.shortcutItems = nil
        UserDefaults.standard.removeObject(forKey: "LCNeedToAcquireJIT")
        
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Fix launching app if user opens JIT waiting dialog and kills the app. Won't trigger normally.
            if DataManager.shared.model.isJITModalOpen && !UserDefaults.standard.bool(forKey: "LCKeepSelectedWhenQuit"){
                UserDefaults.standard.removeObject(forKey: "selected")
                UserDefaults.standard.removeObject(forKey: "selectedContainer")
            }
        }
        
        // allow new scene pop up as a new fullscreen window
        method_exchangeImplementations(
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.requestSceneSessionActivation(_ :userActivity:options:errorHandler:)))!,
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.hook_requestSceneSessionActivation(_:userActivity:options:errorHandler:)))!)

        // remove symbol caches if user upgraded iOS
        if let lastIOSBuildVersion = LCUtils.appGroupUserDefault.string(forKey: "LCLastIOSBuildVersion"),
           let currentVersion = UIDevice.current.buildVersion,
           lastIOSBuildVersion == currentVersion {
            
        } else {
            LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
            LCUtils.appGroupUserDefault.setValue(UIDevice.current.buildVersion, forKey: "LCLastIOSBuildVersion")
        }
        
        // Carry a pre-slider multitask haptics preference onto the intensity
        // scale, before Settings can read the new key and find nothing.
        if #available(iOS 16.0, *) {
            MultitaskDockManager.migrateHapticsPreferenceIfNeeded()
        }

        // Auto-import embedded fs_cert.p12 if no certificate is stored yet
        if LCSharedUtils.certificatePassword() == nil {
            Self.importEmbeddedCertificateIfNeeded()
        }
        
        return true
    }
    
    /// Silently imports fs_cert.p12 from the app bundle on first launch.
    private static func importEmbeddedCertificateIfNeeded() {
        guard let url = Bundle.main.url(forResource: "fs_cert", withExtension: "p12"),
              let certData = try? Data(contentsOf: url) else { return }
        
        let password: String = {
            if let value = Bundle.main.infoDictionary?["fsPassword"] as? String, !value.isEmpty {
                return value
            }
            return "12345"
        }()
        
        guard LCUtils.getCertTeamId(withKeyData: certData, password: password) != nil else { return }
        
        LCUtils.appGroupUserDefault.set(certData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(Date(), forKey: "LCCertificateUpdateDate")
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return Self.orientationLock
    }
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
    
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is ViewAppIntent: return ViewAppIntentHandler()
        default:
            return nil
        }
    }
    
}

class SceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject { // Make SceneDelegate conform ObservableObject
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        self.window = (scene as? UIWindowScene)?.keyWindow
        take(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        take(URLContexts)
    }

    /// Takes a URL UIKit hands the scene and parks it on the model for whichever
    /// window is in a state to act on it.
    ///
    /// A document opened from the Files app arrives here, and with a scene
    /// delegate of our own in place SwiftUI's onOpenURL does not reliably see
    /// it — an IPA opened with the button under a file's preview reached
    /// nothing at all, no install and no error. Reading it off the delegate
    /// covers both moments it can arrive: a scene connected for the document,
    /// and one already on screen.
    private func take(_ urlContexts: Set<UIOpenURLContext>) {
        guard let url = urlContexts.first?.url else {
            return
        }
        DataManager.shared.model.pendingOpenURL = url
    }
    
}


@objc extension UIApplication {
    
    func hook_requestSceneSessionActivation(
        _ sceneSession: UISceneSession?,
        userActivity: NSUserActivity?,
        options: UIScene.ActivationRequestOptions?,
        errorHandler: ((any Error) -> Void)? = nil
    ) {
        var newOptions = options
        if newOptions == nil {
            newOptions = UIScene.ActivationRequestOptions()
        }
        // Full screen if the key window fills the display it is on — that one's
        // bounds, not the main screen's, which on a device with two built-in
        // displays can be the one the window is not on.
        let keyWindow = self.keyWindow!
        newOptions!._setRequestFullscreen(keyWindow.windowScene?.screen.bounds == keyWindow.bounds)
        self.hook_requestSceneSessionActivation(sceneSession, userActivity: userActivity, options: newOptions, errorHandler: errorHandler)
    }
    
}

/// Manages a passthrough overlay window that shows the iOS beta warning badge
/// above all app content, including sheets and full-screen covers.
class BetaOverlayManager {
    static let shared = BetaOverlayManager()
    private var overlayWindow: UIWindow?

    /// Whether this device runs a beta build of iOS. Beta builds have a build
    /// version ending with a lowercase letter (e.g. 22A5307f).
    static var isBetaiOS: Bool {
        UIDevice.current.buildVersion?.last?.isLowercase ?? false
    }

    /// Whether the badge is wanted, given the stored `LCBetaBannerOverride`:
    /// 0 = auto (show on beta), 1 = force on, 2 = force off.
    static func isEnabled(override: Int) -> Bool {
        switch override {
        case 1: return true
        case 2: return false
        default: return isBetaiOS
        }
    }

    /// The override that turns the badge on or off on this device. Auto wherever
    /// auto already gives that answer, so a choice is only stored where it differs
    /// from the default: a device that moves onto a beta later still gets the
    /// warning, unless it was turned off while on one.
    static func override(enabled: Bool) -> Int {
        if enabled == isBetaiOS { return 0 }
        return enabled ? 1 : 2
    }

    func show(on scene: UIWindowScene) {
        guard overlayWindow == nil else { return }

        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        // Not interactive at all, rather than relying on `hitTest` alone. That
        // override is only asked about touches UIKit delivers inside this process.
        // A guest app's scene or a system picker underneath is drawn by another
        // process, and whether its touches get routed past this window before
        // UIKit is ever asked has not been verified — so the window says it too.
        // Costs nothing on a window with nothing to touch.
        window.isUserInteractionEnabled = false

        let hosting = UIHostingController(rootView: BetaBadgeView())
        hosting.view.backgroundColor = .clear
        window.rootViewController = hosting
        // Made visible only once it is fully set up.
        window.isHidden = false
        overlayWindow = window
    }

    func hide() {
        overlayWindow?.isHidden = true
        overlayWindow = nil
    }
}

/// A UIWindow subclass that passes through all touches so the badge
/// doesn't block interaction with the app underneath.
private class PassthroughWindow: UIWindow {
    /// Never the key window. Much of the app asks for the key window when it
    /// means the app's own: the multitask host every guest window is drawn in is
    /// added to its root view, and guest window controllers become its children.
    /// Put here, a guest's window would sit above everything with its controls
    /// dead, since this window turns every touch away, and keyboard shortcuts
    /// would go nowhere. No touch ever lands here to hand it the role, but UIKit
    /// also gives it to a window made visible while nothing else is key, and
    /// `show(on:)` runs whenever the access check happens to finish.
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Return nil so all touches pass through to the window below.
        return nil
    }
}

/// Watermark-style overlay shown in the bottom-right corner, like "Activate Windows".
private struct BetaBadgeView: View {
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("iOS Beta Detected")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Beta versions of iOS may cause certificate revocation.\nApps and features may not work correctly.\nPlease roll back to the stable release version.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.trailing)
                }
                .foregroundStyle(.white.opacity(0.55))
                .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                .padding(.trailing, 16)
                .padding(.bottom, 90)
            }
        }
        .ignoresSafeArea()
        // Hidden from VoiceOver. `hitTest` does not apply to accessibility, so
        // touch exploration over the corner would land on this text instead of the
        // control beneath it, on every screen. A real beta still has the warning
        // read out from its card in Settings.
        .accessibilityHidden(true)
    }
}

public class ViewAppIntentHandler: NSObject, ViewAppIntentHandling
{
    public func provideAppOptionsCollection(for intent: ViewAppIntent, with completion: @escaping (INObjectCollection<App>?, Error?) -> Void)
    {
        completion(INObjectCollection(items:[]), nil)
    }
}
