// CarPlay video surface for Nuvio.
//
// Approach adapted from YouDash (https://github.com/sa4hnd/YouDash, GPL-3.0):
// instead of building a second copy of the app for the car, the single,
// already-initialized Nuvio root controller (SwiftUI + Compose + MPV player)
// is moved into the CarPlay window, scaled to a usable logical canvas, and
// returned to the phone window untouched when CarPlay disconnects.
//
// Requires a provisioning profile that grants `com.apple.developer.carplay-video`
// and an iOS/head-unit combination that hands the app a drawable car window.

import CarPlay
import SwiftUI
import UIKit

private let nuvioCarBackground = UIColor(red: 0.051, green: 0.051, blue: 0.051, alpha: 1)

/// Session roles that represent a car display.
func nuvioIsCarRole(_ role: UISceneSession.Role) -> Bool {
    role == .carTemplateApplication
        || role.rawValue == "UIWindowSceneSessionRoleCarPlay"
        || role == .windowExternalDisplayNonInteractive
}

// MARK: - Scaled canvas

/// Lays out content in logical points (at least ~1024×600) and scales it down
/// uniformly to fit small car displays. UIKit transforms keep touch mapping exact.
final class NuvioCarScaledContentView: UIView {
    static let logicalMinimum = CGSize(width: 1024, height: 600)

    let canvas = UIView()

    static func scale(for viewport: CGSize) -> CGFloat {
        guard viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(1, min(viewport.width / logicalMinimum.width, viewport.height / logicalMinimum.height))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        canvas.backgroundColor = nuvioCarBackground
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = Self.scale(for: bounds.size)
        let logical = CGRect(x: 0, y: 0, width: bounds.width / scale, height: bounds.height / scale)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        // Only touch geometry when it changes; this runs during playback layout passes.
        if canvas.bounds != logical { canvas.bounds = logical }
        if canvas.center != center { canvas.center = center }
        if canvas.transform != transform { canvas.transform = transform }
    }
}

// MARK: - Host controller shown on the car display

final class NuvioCarPlayHostController: UIViewController {
    private(set) var nativeController: UIViewController?
    private let content = NuvioCarScaledContentView()
    private let status = UILabel()
    private var keyboardController: UIViewController?
    private weak var inputTarget: (UIView & UIKeyInput)?

    var statusText: String {
        get { status.text ?? "" }
        set { status.text = newValue }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = nuvioCarBackground

        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        // Background is edge to edge; interactive content stays clear of the CarPlay sidebar.
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            content.topAnchor.constraint(equalTo: safe.topAnchor),
            content.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
        ])

        status.text = "Opening Nuvio…"
        status.numberOfLines = 0
        status.textAlignment = .center
        status.textColor = .white
        status.font = .preferredFont(forTextStyle: .title3)
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])

        if #available(iOS 17.0, *) {
            // Nuvio's adaptive layouts key off idiom/size class. A CarPlay window would
            // otherwise report the `.carPlay` idiom, which Compose/SwiftUI don't design for.
            traitOverrides.userInterfaceIdiom = .pad
            traitOverrides.horizontalSizeClass = .regular
            traitOverrides.verticalSizeClass = .regular
        }
    }

    func embed(_ controller: UIViewController) {
        loadViewIfNeeded()
        guard nativeController !== controller else { return }
        releaseNative()
        nativeController = controller
        controller.overrideUserInterfaceStyle = .dark
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        content.canvas.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: content.canvas.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: content.canvas.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: content.canvas.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: content.canvas.bottomAnchor),
        ])
        content.setNeedsLayout()
        content.layoutIfNeeded()
        controller.didMove(toParent: self)
        status.isHidden = true
    }

    /// Detaches the native controller so it can be handed back to the phone window.
    func releaseNative() {
        hideKeyboard()
        guard let controller = nativeController else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.overrideUserInterfaceStyle = .unspecified
        nativeController = nil
        status.isHidden = false
    }

    // MARK: On-screen keyboard (the system keyboard is never shown on a car display)

    func showKeyboard(for target: UIView & UIKeyInput) {
        if inputTarget === target, keyboardController != nil { return }
        hideKeyboard(resign: false)
        inputTarget = target

        let keyboard = UIHostingController(rootView: NuvioCarKeyboard(
            initialText: Self.currentText(of: target),
            secure: target.isSecureTextEntry ?? false,
            onInsert: { [weak self] text in self?.inputTarget?.insertText(text) },
            onDelete: { [weak self] in self?.inputTarget?.deleteBackward() },
            onGo: { [weak self] in self?.submit() },
            onDone: { [weak self] in self?.hideKeyboard() }
        ))
        keyboard.view.backgroundColor = UIColor(white: 0.08, alpha: 0.97)
        keyboard.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(keyboard)
        view.addSubview(keyboard.view)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            keyboard.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            keyboard.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            keyboard.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyboard.view.heightAnchor.constraint(equalTo: safe.heightAnchor, multiplier: 0.62),
        ])
        keyboard.didMove(toParent: self)
        keyboardController = keyboard
    }

    func hideKeyboard(resign: Bool = true) {
        if let keyboard = keyboardController {
            keyboard.willMove(toParent: nil)
            keyboard.view.removeFromSuperview()
            keyboard.removeFromParent()
            keyboardController = nil
        }
        if resign { inputTarget?.resignFirstResponder() }
        inputTarget = nil
    }

    private func submit() {
        if let field = inputTarget as? UITextField {
            if field.delegate?.textFieldShouldReturn?(field) == nil {
                field.sendActions(for: .editingDidEndOnExit)
            }
        } else {
            // Compose maps a newline from the input view to the field's IME action.
            inputTarget?.insertText("\n")
        }
        hideKeyboard()
    }

    private static func currentText(of target: UIKeyInput) -> String {
        guard let input = target as? UITextInput,
              let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        else { return "" }
        return input.text(in: range) ?? ""
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nativeController }
}

// MARK: - Phone placeholder

private final class NuvioCarPhonePlaceholderController: UIViewController {
    var onReturnToPhone: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        let icon = UIImageView(image: UIImage(systemName: "car.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let label = UILabel()
        label.text = "Nuvio is showing on CarPlay."
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0

        let detail = UILabel()
        detail.text = "For use while parked. Disconnect CarPlay, or bring Nuvio back to this iPhone."
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .lightGray
        detail.textAlignment = .center
        detail.numberOfLines = 0

        let button = UIButton(type: .system)
        button.setTitle("Use on iPhone", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, label, detail, button])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }

    @objc private func returnTapped() { onReturnToPhone?() }
}

// MARK: - Surface coordinator

/// Owns the one Nuvio root controller and decides whether it lives on the phone
/// or the car. CPWindow (template scene) and a CarPlay window scene can arrive in
/// either order; exactly one host ever owns the native controller, so the player
/// is never duplicated.
@MainActor
final class NuvioCarPlaySurface {
    static let shared = NuvioCarPlaySurface()

    /// Optional factory for a fresh root when the app is cold-launched from the
    /// car and iOS never creates the phone scene. Set from `iOSApp`.
    var makeStandaloneRoot: (() -> UIViewController)?

    /// True while Nuvio's UI is on the car display. Readable from any context.
    nonisolated(unsafe) private(set) static var isPresentingOnCar = false

    private var interfaceController: CPInterfaceController?
    private weak var templateWindow: UIWindow?
    private weak var sceneWindow: UIWindow?
    private var host: NuvioCarPlayHostController?

    private var nativeController: UIViewController? {
        didSet { Self.isPresentingOnCar = nativeController != nil }
    }
    private var nativeIsStandalone = false
    private var phoneWindow: UIWindow?
    private var phoneOriginalRoot: UIViewController?
    private var placeholder: NuvioCarPhonePlaceholderController?

    private var retryTimer: Timer?
    private var attempts = 0
    private var reconciling = false
    private var userReturnedToPhone = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    var activeWindow: UIWindow? { sceneWindow ?? templateWindow }

    // MARK: Connection events

    func connectTemplate(_ controller: CPInterfaceController, window: CPWindow?) {
        log("Template connected, window=\(window.map { NSCoder.string(for: $0.bounds) } ?? "none")")
        interfaceController = controller
        templateWindow = window
        userReturnedToPhone = false
        installRootTemplate()
        startObserving()
        reconcile()
    }

    func disconnectTemplate() {
        log("Template disconnected")
        if let old = templateWindow, old.rootViewController === host { old.rootViewController = nil }
        templateWindow = nil
        interfaceController = nil
        reconcile()
    }

    func connectWindow(_ window: UIWindow) {
        log("Window connected, role=\(window.windowScene?.session.role.rawValue ?? "?") bounds=\(NSCoder.string(for: window.bounds))")
        if let old = sceneWindow, old !== window, old.rootViewController === host { old.rootViewController = nil }
        sceneWindow = window
        userReturnedToPhone = false
        startObserving()
        reconcile()
    }

    func disconnectWindow(_ window: UIWindow?) {
        guard let window, sceneWindow === window else { return }
        log("Window disconnected")
        sceneWindow = nil
        if window.rootViewController === host { window.rootViewController = nil }
        reconcile()
    }

    func textInputBecameActive(_ view: UIView) {
        guard let window = activeWindow, view.window === window,
              let input = view as? (UIView & UIKeyInput) else { return }
        host?.showKeyboard(for: input)
    }

    /// Sends the UI back to the phone while CarPlay stays connected.
    func returnToPhone() {
        userReturnedToPhone = true
        restorePhone()
        host?.statusText = "Nuvio is on your iPhone."
        installRootTemplate()
    }

    // MARK: Reconciliation

    func reconcile() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }

        guard let destination = activeWindow, !userReturnedToPhone else {
            restorePhone()
            if activeWindow == nil { stopObserving() }
            return
        }

        let host = self.host ?? NuvioCarPlayHostController()
        self.host = host
        destination.overrideUserInterfaceStyle = .dark
        if destination.rootViewController !== host {
            for other in [templateWindow, sceneWindow] where other !== destination && other?.rootViewController === host {
                other?.rootViewController = nil
            }
            destination.rootViewController = host
            destination.makeKeyAndVisible()
        }
        NuvioCarPlayResponderHook.install()

        if nativeController != nil {
            coverLatePhoneWindowIfNeeded()
            return
        }

        if let phone = findPhoneWindow(), let root = phone.rootViewController, root.isViewLoaded {
            phoneWindow = phone
            phoneOriginalRoot = root
            nativeController = root
            nativeIsStandalone = false
            phone.rootViewController = makePlaceholder()
            host.embed(root)
            destination.makeKeyAndVisible()
            stopRetry()
            log("Moved Nuvio root \(type(of: root)) to car display \(NSCoder.string(for: destination.bounds))")
            return
        }

        // Cold launch from the car: iOS may never connect the phone scene.
        if attempts >= 3, let factory = makeStandaloneRoot {
            let root = factory()
            nativeController = root
            nativeIsStandalone = true
            host.embed(root)
            destination.makeKeyAndVisible()
            stopRetry()
            log("Started standalone Nuvio root on car display")
            return
        }

        host.statusText = "Opening Nuvio…"
        scheduleRetry()
    }

    /// If the phone scene connects while a standalone root is on the car, keep a
    /// single live UI by parking the phone's own root behind the placeholder.
    private func coverLatePhoneWindowIfNeeded() {
        guard nativeIsStandalone, phoneWindow == nil,
              let phone = findPhoneWindow(), let root = phone.rootViewController else { return }
        phoneWindow = phone
        phoneOriginalRoot = root
        phone.rootViewController = makePlaceholder()
        log("Covered late phone window while car shows standalone root")
    }

    private func restorePhone() {
        stopRetry()
        host?.releaseNative()
        if let phone = phoneWindow, let original = phoneOriginalRoot,
           phone.rootViewController === placeholder {
            // When the car showed a standalone root, the phone gets its own original back
            // and the standalone copy is released here.
            phone.rootViewController = original
            phone.makeKeyAndVisible()
            log("Restored Nuvio root to phone window")
        }
        nativeController = nil
        nativeIsStandalone = false
        phoneWindow = nil
        phoneOriginalRoot = nil
        placeholder = nil
        if activeWindow == nil { host = nil }
        attempts = 0
    }

    private func makePlaceholder() -> UIViewController {
        let controller = NuvioCarPhonePlaceholderController()
        controller.onReturnToPhone = { [weak self] in self?.returnToPhone() }
        placeholder = controller
        return controller
    }

    private func findPhoneWindow() -> UIWindow? {
        var best: UIWindow?
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
        where scene.session.role == .windowApplication {
            for window in scene.windows where window.windowLevel == .normal {
                guard let root = window.rootViewController,
                      !(root is NuvioCarPlayHostController),
                      !(root is NuvioCarPhonePlaceholderController) else { continue }
                if best == nil || window.isKeyWindow { best = window }
            }
        }
        return best
    }

    private func installRootTemplate() {
        guard let controller = interfaceController else { return }
        let template: CPListTemplate
        if userReturnedToPhone {
            let item = CPListItem(text: "Show Nuvio on this display", detailText: "Moves Nuvio from your iPhone to CarPlay.")
            item.handler = { [weak self] _, completion in
                self?.userReturnedToPhone = false
                self?.installRootTemplate()
                self?.reconcile()
                completion()
            }
            template = CPListTemplate(title: "Nuvio", sections: [CPListSection(items: [item])])
        } else if activeWindow != nil {
            template = CPListTemplate(title: "Nuvio", sections: [])
        } else {
            let item = CPListItem(
                text: "Waiting for a CarPlay video window",
                detailText: "This car or iOS version didn't provide a drawable display, or the app lacks the CarPlay video entitlement."
            )
            template = CPListTemplate(title: "Nuvio", sections: [CPListSection(items: [item])])
        }
        controller.setRootTemplate(template, animated: false, completion: nil)
    }

    // MARK: Retry and observers

    private func scheduleRetry() {
        guard retryTimer == nil, attempts < 90 else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.attempts += 1
                if self.attempts >= 90 {
                    self.stopRetry()
                    self.host?.statusText = "Open Nuvio on your iPhone, then reconnect CarPlay."
                    self.log("Timed out waiting for the Nuvio root")
                    return
                }
                self.reconcile()
            }
        }
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.willEnterForegroundNotification, UIWindow.didBecomeVisibleNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            })
        }
        observers.append(center.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let field = note.object as? UITextField { self?.textInputBecameActive(field) }
            }
        })
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[NuvioCarPlay] \(message)")
        #endif
    }
}

// MARK: - Scene delegates (referenced from Info.plist)

@objc(NuvioCarPlayTemplateDelegate)
final class NuvioCarPlayTemplateDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        NuvioCarPlaySurface.shared.connectTemplate(interfaceController, window: window)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        NuvioCarPlaySurface.shared.connectTemplate(interfaceController, window: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        NuvioCarPlaySurface.shared.disconnectTemplate()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        NuvioCarPlaySurface.shared.disconnectTemplate()
    }

    func sceneDidBecomeActive(_ scene: UIScene) { NuvioCarPlaySurface.shared.reconcile() }
}

@objc(NuvioCarPlayWindowDelegate)
final class NuvioCarPlayWindowDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        NuvioCarPlaySurface.shared.connectWindow(window)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        NuvioCarPlaySurface.shared.disconnectWindow(window)
        window = nil
    }

    func sceneDidBecomeActive(_ scene: UIScene) { NuvioCarPlaySurface.shared.reconcile() }
}
