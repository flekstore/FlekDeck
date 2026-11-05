import Foundation

protocol LCAppModelDelegate {
    func closeNavigationView()
    func changeAppVisibility(app : LCAppModel)
    func jitLaunch(appName: String, classicMode: UInt) async
    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async
    func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async
    func showRunWhenMultitaskAlert() async -> Bool?
}

/// Why an app cannot be uninstalled. Carries the explanation itself, so the
/// menus that hide Uninstall and the alert that explains the absence do not have
/// to keep their own copies of the wording in step.
enum UninstallRefused : LocalizedError {
    /// The bundle is in the app group and still there, so it is not this
    /// install's to take away.
    case sharedBundle

    var errorDescription: String? {
        switch self {
        case .sharedBundle:
            return "This app is stored in the shared folder, so every FlekDeck on this device uses the same copy — deleting it here would remove it for all of them.\n\nTo delete it, open the app's settings and tap \"Convert to Private App\" first."
        }
    }
}

class LCAppModel: ObservableObject, Hashable {
    
    @Published var appInfo : LCAppInfo
    
    @Published var isAppRunning = false
    @Published var isSigningInProgress = false
    @Published var signProgress = 0.0
    private var observer : NSKeyValueObservation?
    
    @Published var uiIsJITNeeded : Bool {
        didSet {
            appInfo.isJITNeeded = uiIsJITNeeded
        }
    }
    @Published var uiClassicMode : Bool {
        didSet {
            appInfo.classicMode = uiClassicMode
        }
    }
    @Published var uiIsHidden : Bool
    @Published var uiIsLocked : Bool
    @Published var uiIsShared : Bool
    @Published var uiDefaultDataFolder : String?
    @Published var uiContainers : [LCContainer]
    @Published var uiSelectedContainer : LCContainer?
    @Published var uiIs32bit : Bool
    @Published var uiIs32bitEmulator : Bool
    @Published var uiTweakFolder : String? {
        didSet {
            appInfo.tweakFolder = uiTweakFolder
        }
    }
    @Published var uiDoSymlinkInbox : Bool {
        didSet {
            appInfo.doSymlinkInbox = uiDoSymlinkInbox
        }
    }
    @Published var uiUseLCBundleId : Bool {
        didSet {
            appInfo.doUseLCBundleId = uiUseLCBundleId
        }
    }
    
    @Published var uiFixFilePickerNew : Bool {
        didSet {
            appInfo.fixFilePickerNew = uiFixFilePickerNew
        }
    }
    @Published var uiFixLocalNotification : Bool {
        didSet {
            appInfo.fixLocalNotification = uiFixLocalNotification
        }
    }
    
    @Published var uiHideLiveContainer : Bool {
        didSet {
            appInfo.hideLiveContainer = uiHideLiveContainer
        }
    }
    @Published var uiTweakLoaderInjectFailed : Bool
    @Published var uiDontInjectTweakLoader : Bool {
        didSet {
            appInfo.dontInjectTweakLoader = uiDontInjectTweakLoader
        }
    }
    @Published var uiDontLoadTweakLoader : Bool {
        didSet {
            appInfo.dontLoadTweakLoader = uiDontLoadTweakLoader
        }
    }
    @Published var uiOrientationLock : LCOrientationLock {
        didSet {
            appInfo.orientationLock = uiOrientationLock
        }
    }
    @Published var uiSelectedLanguage : String {
        didSet {
            appInfo.selectedLanguage = uiSelectedLanguage
        }
    }
    
    @Published var uiDontSign : Bool {
        didSet {
            appInfo.dontSign = uiDontSign
        }
    }
    
    @Published var jitLaunchScriptJs: String? {
        didSet {
            appInfo.jitLaunchScriptJs = jitLaunchScriptJs
            // A name only goes with a picked file's contents: the default, a
            // built-in script and a Custom with nothing picked yet have none.
            let script = jitLaunchScriptJs ?? ""
            if (script.isEmpty || script.hasPrefix("/")) && jitLaunchScriptName != nil {
                jitLaunchScriptName = nil
            }
        }
    }
    /// The name of the file a custom script was picked from.
    @Published var jitLaunchScriptName: String? {
        didSet {
            appInfo.jitLaunchScriptName = jitLaunchScriptName
        }
    }
    /// The script as an external JIT enabler takes it: its contents,
    /// base64-encoded. One of the scripts that ship in StikJIT.framework is
    /// stored as its path inside the bundle, which only built-in JIT reads, so
    /// it is read out here.
    var jitLaunchScriptJsResolved: String? {
        get {
            var script = jitLaunchScriptJs
            // A 32-bit app offers no choice of script, and where TXM is present
            // its translation layer needs the universal one.
            if (script ?? "").isEmpty, appInfo.is32bit, LCUtils.isTXMScriptRequired() {
                script = "/Frameworks/StikJIT.framework/universal.js"
            }
            guard let script, script.hasPrefix("/") else {
                return script
            }
            let url = URL(fileURLWithPath: Bundle.main.bundlePath.appending(script))
            return (try? Data(contentsOf: url))?.base64EncodedString()
        }
    }
    
    @Published var uiSelected32BitEmulator : String {
        didSet {
            appInfo.selected32BitEmulator = uiSelected32BitEmulator
        }
    }
    
    @Published var uiSpoofSDKVersion : Bool {
        didSet {
            appInfo.spoofSDKVersion = uiSpoofSDKVersion
        }
    }
    
    @Published var uiSpoofLocation : Bool {
        didSet {
            appInfo.spoofLocation = uiSpoofLocation
        }
    }
    
    @Published var uiRemark : String {
        didSet {
            appInfo.remark = uiRemark
        }
    }
    
    @Published var uiIsMultitaskModeSpecificed : MultitaskSpecified {
        didSet {
            appInfo.multitaskSpecified = uiIsMultitaskModeSpecificed;
        }
    }
    
    public var bundleIdentifier: String {
        get {
            return appInfo.bundleIdentifier() ?? "?"
        }
    }
    
    public var version: String {
        get {
            return appInfo.version() ?? "?"
        }
    }
    
    public var displayName: String {
        get {
            return appInfo.displayName() ?? "?"
        }
    }
    
    public var shouldLaunchInMultitaskMode : Bool {
        get {
            if #available(iOS 16.0, *) {
                let globalDefault = UserDefaults.standard.object(forKey: "LCLaunchInMultitaskMode") == nil ? true : UserDefaults.standard.bool(forKey: "LCLaunchInMultitaskMode")
                return uiIsMultitaskModeSpecificed == .yes ||
                (uiIsMultitaskModeSpecificed == .default && globalDefault)
            } else {
                return false
            }
        }
    }
    
    @Published var supportedLanguages : [String]?

    /// Whether the bundle this entry points at is gone from disk.
    ///
    /// An entry can outlive its files. A replace-install removes the old bundle
    /// before unpacking the new one, so a failure in between leaves the model
    /// pointing at a folder that no longer exists, and a conversion between
    /// private and shared that fails partway leaves it pointing at the side the
    /// bundle just left. Such an entry is stale: nothing is shared with the other
    /// LiveContainers on the device any more, so the rules that protect a shared
    /// bundle do not apply to it and it should just be removable.
    var isBundleMissing : Bool {
        guard let bundlePath = appInfo.bundlePath(), !bundlePath.isEmpty else {
            return true
        }
        return !FileManager.default.fileExists(atPath: bundlePath)
    }

    /// Whether this entry is ours to delete.
    ///
    /// A shared bundle belongs to the app group, where every FlekDeck on the
    /// device sees the same copy, so deleting it from one takes it from all of
    /// them; the app has to be converted to private first. A stale entry is the
    /// exception, for the reason `isBundleMissing` gives.
    ///
    /// Every menu that offers Uninstall asks this, and `uninstall` enforces it,
    /// so the rule cannot drift between them — which it had, the app banner
    /// having never picked up the exception for a stale entry.
    var isUninstallable : Bool {
        !uiIsShared || isBundleMissing
    }

    /// Deletes the app's bundle, and the folders behind its containers if asked.
    ///
    /// This is the whole of what uninstalling touches on disk. The home screen
    /// and the app banner both call it: they differ in how they ask, not in what
    /// they remove. While they each had their own copy of this they drifted —
    /// the banner went on looking for a shared app's container folder in our own
    /// Documents, threw on the first one, and left the rest of the uninstall
    /// undone with the folder stranded in the app group.
    ///
    /// Taking the entry out of the app list is the caller's to do afterwards,
    /// through `removeApp`.
    func uninstall(removingContainers: Bool) throws {
        guard isUninstallable else {
            throw UninstallRefused.sharedBundle
        }
        let fm = FileManager()
        // A stale entry has no bundle left to remove, which is what makes it
        // removable in the first place.
        if let bundlePath = appInfo.bundlePath(), !isBundleMissing {
            try fm.removeItem(atPath: bundlePath)
        }
        guard removingContainers else {
            return
        }
        for container in appInfo.containers {
            let folderName = container.folderName
            // A folder the user pointed at external storage lives outside
            // FlekDeck and is not ours to delete; its keychain items still are.
            // Otherwise containerURL resolves to the app group for a shared app
            // and to our own Documents for a private one, so a stale shared
            // entry cleans up the folder it actually has.
            //
            // Not a hard failure if the folder turns out not to be there: what
            // matters is that the containers after it, and their keychain items,
            // still get cleaned up.
            if container.storageBookMark == nil {
                try? fm.removeItem(at: container.containerURL)
            }
            LCUtils.removeAppKeychain(dataUUID: folderName)
            DispatchQueue.main.async {
                DataManager.shared.model.appDataFolderNames.removeAll { $0 == folderName }
            }
        }
    }

    var delegate : LCAppModelDelegate?
    
    init(appInfo : LCAppInfo, delegate: LCAppModelDelegate? = nil) {
        self.appInfo = appInfo
        self.delegate = delegate

        if !appInfo.isLocked && appInfo.isHidden {
            appInfo.isLocked = true
        }
        
        self.uiIsJITNeeded = appInfo.isJITNeeded
        self.uiClassicMode = appInfo.classicMode
        self.uiIsHidden = appInfo.isHidden
        self.uiIsLocked = appInfo.isLocked
        self.uiIsShared = appInfo.isShared
        self.uiSelectedLanguage = appInfo.selectedLanguage ?? ""
        self.uiDefaultDataFolder = appInfo.dataUUID
        self.uiContainers = appInfo.containers
        self.uiTweakFolder = appInfo.tweakFolder
        self.uiDoSymlinkInbox = appInfo.doSymlinkInbox
        self.uiOrientationLock = appInfo.orientationLock
        self.uiIsMultitaskModeSpecificed = appInfo.multitaskSpecified
        self.uiUseLCBundleId = appInfo.doUseLCBundleId
        self.uiFixFilePickerNew = appInfo.fixFilePickerNew
        self.uiFixLocalNotification = appInfo.fixLocalNotification
        self.uiHideLiveContainer = appInfo.hideLiveContainer
        self.uiDontInjectTweakLoader = appInfo.dontInjectTweakLoader
        self.uiTweakLoaderInjectFailed = appInfo.info()["LCTweakLoaderCantInject"] as? Bool ?? false
        self.uiDontLoadTweakLoader = appInfo.dontLoadTweakLoader
        self.uiDontSign = appInfo.dontSign
        self.jitLaunchScriptJs = appInfo.jitLaunchScriptJs
        self.jitLaunchScriptName = appInfo.jitLaunchScriptName
        self.uiSelected32BitEmulator = appInfo.selected32BitEmulator ?? ""
        self.uiSpoofSDKVersion = appInfo.spoofSDKVersion
        self.uiSpoofLocation = appInfo.spoofLocation
        self.uiRemark = appInfo.remark ?? ""
        self.uiIs32bit = appInfo.is32bit
        self.uiIs32bitEmulator = appInfo.is32bitEmulator
        for container in uiContainers {
            if container.folderName == uiDefaultDataFolder {
                self.uiSelectedContainer = container;
                break
            }
        }
    }
    
    static func == (lhs: LCAppModel, rhs: LCAppModel) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    
    // You should let LCAppModel.runApp to decide whether to run in multitask mode, but you may override the multitask parameter if necessary
    func runApp(multitask: Bool? = nil, containerFolderName : String? = nil, bundleIdOverride : String? = nil, urlStr : String? = nil, forceJIT: Bool? = nil) async throws{
        if isAppRunning {
            return
        }
        // Counted toward the Apps widget's Most Used order however the launch
        // goes on: in a window, in single mode, or brought to the front.
        FlekWidgetSync.shared.recordLaunch(of: self)
        
        if uiContainers.isEmpty {
            let newName = NSUUID().uuidString
            let newContainer = LCContainer(folderName: newName, name: newName, isShared: uiIsShared)
            uiContainers.append(newContainer)
            if uiSelectedContainer == nil {
                uiSelectedContainer = newContainer;
            }
            appInfo.containers = uiContainers;
            newContainer.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
            appInfo.dataUUID = newName
            uiDefaultDataFolder = newName
        }
        if let containerFolderName {
            uiSelectedContainer = uiContainers.first { $0.folderName == containerFolderName } ?? uiSelectedContainer
        }
        let currentDataFolder = containerFolderName ?? uiSelectedContainer?.folderName
        
        let classicMode = appInfo.defaultClassicMode
        let multitask = classicMode == 0 ? (multitask ?? shouldLaunchInMultitaskMode) : false
        
        if MultitaskManager.isMultitasking() || multitask,
           let currentDataFolder {
            if await bringExistingMultitaskWindowIfNeeded(dataUUID: currentDataFolder, urlScheme: urlStr) {
                return
            }
            
        }
        
        // this is rerouted to bringing app to front, so not needed here?
//        if(MultitaskManager.isUsing(container: uiSelectedContainer!.folderName)) {
//            throw "lc.container.inUse".loc + "\n MultiTask"
//        }
        
        // if the selected container is in use (either other lc or multitask), open the host lc associated with it
        if
            let fn = uiSelectedContainer?.folderName,
            var runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: fn)
        {
            runningLC = (runningLC as NSString).deletingPathExtension
            
            var openURLComp = URLComponents()
            openURLComp.scheme = runningLC
            if let urlStr {
                openURLComp.host = "open-url"
                openURLComp.queryItems = [
                    URLQueryItem(name: "url", value: Data(urlStr.utf8).base64EncodedString())
                ]
            }
            if await UIApplication.shared.canOpenURL(openURLComp.url!) {
                await UIApplication.shared.open(openURLComp.url!)
                return
            }
        }
        
        // find a free lc to run non-multitasking shared app. If none, ask user if they want to terminate all multitasking apps
        var endsWindows = false
        if MultitaskManager.isMultitasking() && !multitask {
            if self.uiIsShared {
                var freeScheme: String? = nil
                LCUtils.forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                    freeScheme = scheme
                    shouldBreak = true
                }
                if let freeScheme {
                    LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                    LCUtils.appGroupUserDefault.set(self.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                    LCUtils.appGroupUserDefault.set(uiSelectedContainer?.folderName, forKey: "LCLaunchExtensionContainerName")
                    if let urlStr {
                        LCUtils.appGroupUserDefault.set(urlStr, forKey: "LCLaunchExtensionLaunchURL")
                    }
                    LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                    var launchURLComp = URLComponents()
                    launchURLComp.scheme = freeScheme
                    launchURLComp.host = "livecontainer-launch"
                    var queryItems: [URLQueryItem] = []
                    if let bundlePath = self.appInfo.relativeBundlePath {
                        queryItems.append(URLQueryItem(name: "bundle-name", value: bundlePath))
                    }
                    if let folderName = uiSelectedContainer?.folderName {
                        queryItems.append(URLQueryItem(name: "container-folder-name", value: folderName))
                    }
                    
                    launchURLComp.queryItems = queryItems
                    
                    if let url = launchURLComp.url {
                        await UIApplication.shared.open(url)
                    } else {
                        throw "Unable to build URL from launchURLComp???"
                    }
                    return
                }
            }
            
            guard let ans = await delegate?.showRunWhenMultitaskAlert(), ans else {
                return
            }
            endsWindows = true
        }
        
        await MainActor.run {
            isAppRunning = true
        }
        defer {
            Task { await MainActor.run {
                isAppRunning = false
            }}
        }
        try await signApp(force: false)
        
        var jitNeeded = appInfo.isJITNeeded || appInfo.is32bit
        if let forceJIT {
            jitNeeded = forceJIT
        }
#if targetEnvironment(simulator)
        jitNeeded = false
#else
        if jitNeeded {
            // Asked before the app is recorded below as the one to start: a
            // guest started without a working JIT setup fails as it launches,
            // which the user only learns the next time FlekDeck opens.
            try await FlekJITSetup.ensureReady()
        }
#endif
        // Location Spoofer is a Premium feature, asked here for the same
        // reason; the app is told how it went (FlekLocationSpoofer).
        if appInfo.spoofLocation, FlekLocationSpoofer.isBundled {
            try await FlekLocationSpoofer.ensurePremium()
        }
        
        if let bundleIdOverride {
            UserDefaults.standard.set(bundleIdOverride, forKey: "selected")
        } else {
            UserDefaults.standard.set(self.appInfo.relativeBundlePath, forKey: "selected")
        }
        if let urlStr {
            UserDefaults.standard.setValue(urlStr, forKey: "launchAppUrlScheme")
        }
        UserDefaults.standard.set(uiSelectedContainer?.folderName, forKey: "selectedContainer")

        if endsWindows {
            // Running in single mode relaunches FlekDeck with SIGKILL, and the
            // windows' processes go with it. Have them write out first, here
            // rather than before signing and the checks above, which can take
            // long enough for a window to change something again. A pause
            // rather than a wait for each window, since a guest has no way to
            // answer; writing out takes a fraction of this.
            LCSharedUtils.requestGuestFlush()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        if jitNeeded {
            if multitask, #available(iOS 17.4, *) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    LCUtils.launchMultitaskGuestApp(appInfo.displayName()) { pidNumber, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let pidNumber = pidNumber else {
                            continuation.resume(throwing: "Failed to obtain PID from LiveProcess")
                            return
                        }
                        Task {
                            if let scriptData = self.jitLaunchScriptJsResolved, !scriptData.isEmpty {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: scriptData, appName: self.appInfo.displayName())
                            } else {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: nil, appName: self.appInfo.displayName())
                            }
                            continuation.resume()
                        }
                    }
                }
            } else {
                // Non-multitask JIT flow remains unchanged
                if let scriptData = jitLaunchScriptJsResolved, !scriptData.isEmpty {
                    await delegate?.jitLaunch(withScript: scriptData, appName: self.appInfo.displayName(), classicMode: classicMode)
                } else {
                    await delegate?.jitLaunch(appName: self.appInfo.displayName(), classicMode: classicMode)
                }
            }
        } else if multitask, #available(iOS 16.0, *) {
            try await LCUtils.launchMultitaskGuestApp(appInfo.displayName())
        } else {
            if #available(iOS 26.0, *), FileManager.default.fileExists(atPath: "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE") {
                let fileContents = "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE".data(using: .utf8)
                let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("preloadLibraries.txt")
                try fileContents?.write(to: fileURL)
            }
            LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
        }
        
        // Record the launch time
        appInfo.lastLaunched = Date()

        await MainActor.run {
            isAppRunning = false
        }
    }
    
    func forceResign() async throws {
        if isAppRunning {
            return
        }
        isAppRunning = true
        defer {
            Task{ await MainActor.run {
                self.isAppRunning = false
            }}

        }
        try await signApp(force: true)
    }
    
    func signApp(force: Bool = false) async throws {
        var signError : String? = nil
        var signSuccess = false
        defer {
            Task{ await MainActor.run {
                self.isSigningInProgress = false
            }}
        }
        
        await withUnsafeContinuation({ c in
            appInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error;
                signSuccess = success;
                c.resume()
            }, progressHandler: { signProgress in
                guard let signProgress else {
                    return
                }
                self.isSigningInProgress = true
                self.observer = signProgress.observe(\.fractionCompleted) { p, v in
                    DispatchQueue.main.async {
                        self.signProgress = signProgress.fractionCompleted
                    }
                }
            }, forceSign: force)
        })
        if let signError {
            if !signSuccess {
                throw signError.loc
            }
        }
        
        // The Tweaks folder the guest loads from (LCBootstrap): the app group's
        // for a shared app, this FlekDeck's own for a private one.
        let tweakRoot = appInfo.isShared ? LCPath.lcGroupTweakPath : LCPath.tweakPath
        
        // sign its tweak
        if let tweakFolder = appInfo.tweakFolder {
            try await LCUtils.signTweaks(tweakFolderUrl: tweakRoot.appendingPathComponent(tweakFolder), force: force) { p in
                Task{ await MainActor.run {
                    self.isSigningInProgress = true
                }}
            }
        }
        
        // sign global tweak. TweakLoader loads these into every app, whether or not
        // it has a folder of its own; returning early for an app without one left a
        // newly imported global tweak unsigned, and dlopen refused it ("code
        // signature invalid"). A shared app's root may not exist yet.
        if FileManager.default.fileExists(atPath: tweakRoot.path) {
            do {
                try await LCUtils.signTweaks(tweakFolderUrl: tweakRoot, force: force) { p in
                    Task{ await MainActor.run {
                        self.isSigningInProgress = true
                    }}
                }
            } catch let error where !force {
                // One global tweak that can't be signed must not keep every app
                // from opening; it only fails to load, and TweakLoader says so in
                // the app. Force Sign still reports it here.
                NSLog("[LC] Global tweaks not signed: \(error.localizedDescription)")
            }
        }
    }

    func setLocked(newLockState: Bool) async {
        // if locked state in appinfo already match with the new state, we just the change
        if appInfo.isLocked == newLockState {
            return
        }
        
        if newLockState {
            appInfo.isLocked = true
        } else {
            // authenticate before cancelling locked state
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    uiIsLocked = true
                    return
                }
            } catch {
                uiIsLocked = true
                return
            }
            
            // auth pass, we need to cancel app's lock and hidden state
            appInfo.isLocked = false
            if appInfo.isHidden {
                await toggleHidden()
            }
        }
    }
    
    func toggleHidden() async {
        delegate?.closeNavigationView()
        if appInfo.isHidden {
            appInfo.isHidden = false
            uiIsHidden = false
        } else {
            appInfo.isHidden = true
            uiIsHidden = true
        }
        delegate?.changeAppVisibility(app: self)
    }
    
    func loadSupportedLanguages() throws {
        let fm = FileManager.default
        if supportedLanguages != nil {
            return
        }
        supportedLanguages = []
        let fileURLs = try fm.contentsOfDirectory(at: URL(fileURLWithPath: appInfo.bundlePath()!) , includingPropertiesForKeys: nil)
        for fileURL in fileURLs {
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            let fileType = attributes[.type] as? FileAttributeType
            if(fileType == .typeDirectory && fileURL.lastPathComponent.hasSuffix(".lproj")) {
                supportedLanguages?.append(fileURL.deletingPathExtension().lastPathComponent)
            }
        }
        
    }
    
    private func bringExistingMultitaskWindowIfNeeded(dataUUID: String, urlScheme: String?) async -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        return await MainActor.run {
            if let urlScheme {
                UserDefaults.standard.setValue(urlScheme, forKey: "launchAppUrlScheme")
            }
            var found = false
            if #available(iOS 16.1, *) {
                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: dataUUID)
            }
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: dataUUID)
            }
            if let urlScheme, !found  {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            }
            return found
        }
    }
}
