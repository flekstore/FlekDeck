//
//  Shared.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/22.
//

import SwiftUI
import UniformTypeIdentifiers
import SafariServices
import Security
import Combine
import CryptoKit

struct LCPath {
    public static let docPath = {
        let fm = FileManager()
        return fm.urls(for: .documentDirectory, in: .userDomainMask).last!
    }()
    public static let bundlePath = docPath.appendingPathComponent("Applications")
    public static let dataPath = docPath.appendingPathComponent("Data/Application")
    public static let appGroupPath = docPath.appendingPathComponent("Data/AppGroup")
    public static let tweakPath = docPath.appendingPathComponent("Tweaks")
    public static let pairingFilePath = docPath.appendingPathComponent("SideStore/Documents/ALTPairingFile.mobiledevicepairing")
    
    public static let lcGroupDocPath = {
        let fm = FileManager()
        // it seems that Apple don't want to create one for us, so we just borrow our Store's
        if let appGroupPathUrl = LCSharedUtils.appGroupPath() {
            return appGroupPathUrl.appendingPathComponent("LiveContainer")
        } else if let appGroupPathUrl =
                    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.SideStore.SideStore") {
            return appGroupPathUrl.appendingPathComponent("LiveContainer")
        } else {
            return docPath
        }
    }()
    public static let lcGroupBundlePath = lcGroupDocPath.appendingPathComponent("Applications")
    public static let lcGroupDataPath = lcGroupDocPath.appendingPathComponent("Data/Application")
    public static let lcGroupAppGroupPath = lcGroupDocPath.appendingPathComponent("Data/AppGroup")
    public static let lcGroupTweakPath = lcGroupDocPath.appendingPathComponent("Tweaks")
    
    /// Drops staging folders the share extension left behind, where the install
    /// they were copied for never ran — the app was never opened by the install
    /// URL, or was killed before it was done with the file. Nothing else clears
    /// them, and each one holds a whole IPA.
    ///
    /// Called at launch, which is the one moment no install is in flight. That
    /// includes the launch the share itself causes, so only folders too old to
    /// be the one being handed over right now are taken.
    public static func clearStaleShareInbox() {
        guard let shareInbox = LCSharedUtils.shareInboxPath() else {
            return
        }
        let fm = FileManager()
        guard let staged = try? fm.contentsOfDirectory(
            at: shareInbox, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-3600)
        for folder in staged {
            let modified = (try? folder.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// Appended to the folder of an app that is being replaced, for as long as
    /// its replacement is being moved into place. See `recoverInterruptedReplaces`.
    public static let replacingSuffix = ".replacing"

    /// Puts back an app whose replacement never arrived.
    ///
    /// Installing over an existing app parks the old bundle under
    /// `<name>.app.replacing` and drops it once the new bundle is in place. If
    /// the process is killed in between, the app is left under that name — where
    /// nothing looks for it, since the app list only reads folders ending in
    /// `.app`. Restore it unless the replacement did land after all, in which
    /// case the leftover is just the old copy and can go.
    ///
    /// Called for both the private and the shared Applications folder at launch,
    /// which is the only moment nothing else is touching them.
    public static func recoverInterruptedReplaces(in applicationsPath: URL, contents: [String]) {
        let fm = FileManager()
        for folderName in contents where folderName.hasSuffix(replacingSuffix) {
            let backup = applicationsPath.appendingPathComponent(folderName)
            let original = applicationsPath.appendingPathComponent(String(folderName.dropLast(replacingSuffix.count)))
            if fm.fileExists(atPath: original.path) {
                try? fm.removeItem(at: backup)
            } else {
                try? fm.moveItem(at: backup, to: original)
            }
        }
    }

    public static func ensureAppGroupPaths() throws {
        let fm = FileManager()
        if !fm.fileExists(atPath: LCPath.lcGroupBundlePath.path) {
            try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: LCPath.lcGroupDataPath.path) {
            try fm.createDirectory(at: LCPath.lcGroupDataPath, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: LCPath.lcGroupTweakPath.path) {
            try fm.createDirectory(at: LCPath.lcGroupTweakPath, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: LCPath.pairingFilePath.path) {
            try fm.createDirectory(at: LCPath.pairingFilePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }
}

class SharedModel: ObservableObject {
    @Published var selectedTab: LCTabIdentifier = .apps
    @Published var deepLink: URL?
    /// A URL that arrived before any window was ready to act on it, held until
    /// one is. It lives here rather than on the window that received it because
    /// that window is often not the one that survives: opening a document from
    /// the Files app hands it to a newly connected scene, which this app then
    /// closes as a duplicate — taking a URL parked in the scene's own state
    /// with it, which is why an IPA opened that way did nothing at all.
    @Published var pendingOpenURL: URL?
    
    @Published var isHiddenAppUnlocked = false
    @Published var developerMode = false
    // 0 = current liveContainer is the primary one,
    // 2 = current liveContainer is not the primary one
    @Published var multiLCStatus = 0
    @Published var isJITModalOpen = false

    /// Whether a signing certificate is stored, whichever way it came: taken
    /// from the app bundle at launch, picked in Files, or handed back by
    /// SideStore or a flekdeck://certificate link. It follows the stored
    /// password itself rather than each of those reporting in, so a new way
    /// of importing one cannot forget to.
    @Published private(set) var isCertificateImported = LCSharedUtils.certificatePassword() != nil

    /// Whether this copy of FlekDeck should be asking for a certificate. One
    /// that is not the primary signs with the primary's and has no way to
    /// import its own, so it has nothing to ask for.
    var needsCertificate: Bool {
        multiLCStatus != 2 && !isCertificateImported
    }

    /// Whether the stored certificate no longer signs: past its expiry, or
    /// revoked as Apple last said. Marked until another is imported, as no
    /// app can be signed till then. Not for a copy that signs with the
    /// primary's, which has none of its own to replace.
    @Published private(set) var isCertificateInvalid = false

    /// Whether Premium has ended since the user last opened General, where
    /// it says so. Looking once is enough: not renewing is the user's choice.
    @Published private(set) var isPremiumEndUnseen = false

    /// Whether General's row carries the red mark: a certificate to import
    /// or replace, or an end of Premium not looked at yet.
    var generalNeedsAttention: Bool {
        needsCertificate || isCertificateInvalid || isPremiumEndUnseen
    }

    /// What the Settings icon on the home screen counts: the certificate,
    /// and an end of Premium not looked at yet.
    var settingsAttentionCount: Int {
        (needsCertificate || isCertificateInvalid ? 1 : 0) + (isPremiumEndUnseen ? 1 : 0)
    }

    private var certificateObservation: NSKeyValueObservation?
    private var certificateDataObservation: NSKeyValueObservation?
    private var premiumObservations: [NSKeyValueObservation] = []
    private var foregroundObserver: NSObjectProtocol?

    // Apple's last word on whether the stored certificate is revoked, kept
    // by the certificate's digest so that it holds with no network, and
    // when and for which certificate it was last asked.
    private static let revokedCertificateKey = "FlekCertificateRevokedDigest"
    private static let revocationAskedForKey = "FlekCertificateRevocationAskedFor"
    private static let revocationAskedAtKey = "FlekCertificateRevocationAskedAt"
    /// How often Apple is asked again about the same certificate.
    private static let revocationRecheckInterval: TimeInterval = 60 * 60
    
    @Published var enableMultipleWindow = false

    @Published var appDataFolderNames: [String] = []
    @Published var tweakFolderNames: [String] = []
    
    @Published var apps : [LCAppModel] = []
    @Published var arm32EmuApps : [LCAppModel] = []
    @Published var hiddenApps : [LCAppModel] = []
    
    @Published var pidCallback : ((NSNumber, Error?) -> Void)? = nil

    static let isPhone: Bool = {
        UIDevice.current.userInterfaceIdiom == .phone
    }()
    
    static let isLiquidGlassEnabled = {
        if #available(iOS 19.0, *), (dyld_get_program_sdk_version() >= 0x1a0000 || UserDefaults.standard.bool(forKey: "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck")) {
            if let compatibilityEnabled = Bundle.main.infoDictionary?["UIDesignRequiresCompatibility"] as? Bool, compatibilityEnabled {
                return false
            }
            
            return true
        }
        return false
    }()
    
    var mainWindowOpened = false
    
    public static let keychainAccessGroupCount = 128
    
    func updateMultiLCStatus() {
        if LCUtils.appUrlScheme()?.lowercased() != "flekdeck" {
            multiLCStatus = 2
        } else {
            multiLCStatus = 0
        }
    }
    
    /// Re-reads whether a certificate is stored, publishing only a change.
    func refreshCertificateStatus() {
        let imported = LCSharedUtils.certificatePassword() != nil
        if imported != isCertificateImported {
            isCertificateImported = imported
        }
        refreshCertificateValidity()
    }

    /// Re-reads whether the stored certificate still signs. Its expiry is in
    /// the file. Whether it is revoked is Apple's to say, and Apple is asked
    /// at most once an hour for the same certificate; until it answers, the
    /// answer kept from before stands.
    func refreshCertificateValidity() {
        guard multiLCStatus != 2, isCertificateImported,
              let data = LCUtils.certificateData(),
              let password = LCSharedUtils.certificatePassword() else {
            publishCertificateInvalid(false)
            return
        }
        // Read on a queue of its own: the expiry is inside the certificate,
        // which has to be decrypted to get at it, on every return to the
        // foreground. Quick on a new phone, a hitch on an older one.
        Self.certificateQueue.async { [weak self] in
            let digest = Self.digest(of: data)
            let expiry = LCUtils.getCertInfo(withKeyData: data, password: password)?["notAfter"] as? Date
            DispatchQueue.main.async {
                self?.certificateRead(digest: digest, expiry: expiry)
            }
        }
    }

    private static let certificateQueue = DispatchQueue(label: "FlekCertificateValidity", qos: .utility)

    /// What `refreshCertificateValidity` read, back on the main queue.
    private func certificateRead(digest: String, expiry: Date?) {
        // A certificate replaced or removed while this one was being read has
        // a read of its own on the way, and this one is about neither.
        guard isCertificateImported, LCUtils.certificateData().map(Self.digest(of:)) == digest else {
            return
        }
        let isExpired = expiry.map { $0 < Date() } ?? false
        let defaults = UserDefaults.standard
        publishCertificateInvalid(isExpired || defaults.string(forKey: Self.revokedCertificateKey) == digest)

        let askedRecently = defaults.string(forKey: Self.revocationAskedForKey) == digest
            && Date().timeIntervalSince1970 - defaults.double(forKey: Self.revocationAskedAtKey) < Self.revocationRecheckInterval
        guard !isExpired, !askedRecently else {
            return
        }
        defaults.set(digest, forKey: Self.revocationAskedForKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.revocationAskedAtKey)
        // As ZSign's check reports it: 0 good, 1 revoked, anything else no
        // answer. Asked from the same queue, as it decrypts the certificate
        // again before it sends anything.
        Self.certificateQueue.async { [weak self] in
            _ = LCUtils.validateCertificate { status, _, _, _ in
                DispatchQueue.main.async {
                    // An answer about a certificate replaced meanwhile is dropped.
                    guard let self, LCUtils.certificateData().map(Self.digest(of:)) == digest else {
                        return
                    }
                    switch status {
                    case 0:
                        if defaults.string(forKey: Self.revokedCertificateKey) == digest {
                            defaults.removeObject(forKey: Self.revokedCertificateKey)
                        }
                        self.publishCertificateInvalid(false)
                    case 1:
                        defaults.set(digest, forKey: Self.revokedCertificateKey)
                        self.publishCertificateInvalid(true)
                    default:
                        break
                    }
                }
            }
        }
    }

    /// Re-reads whether Premium has ended unseen, publishing only a change.
    /// An end that has passed with the server not asked since is asked
    /// about first, as a renewal may have moved it on; the answer comes back
    /// through what is kept.
    func refreshPremiumAttention() {
        publishPremiumEndUnseen()
        if FlekPremium.needsCheckAfterEnd, !isCheckingPremiumEnd {
            isCheckingPremiumEnd = true
            Task {
                await FlekPremium.refresh()
                // Not asked again at once for no answer: the next return to
                // the foreground asks again.
                await MainActor.run {
                    self.isCheckingPremiumEnd = false
                    self.publishPremiumEndUnseen()
                }
            }
        }
    }

    private func publishPremiumEndUnseen() {
        let unseen = FlekPremium.isEndUnseen
        if unseen != isPremiumEndUnseen {
            isPremiumEndUnseen = unseen
        }
    }

    /// While the server is asked about an end of Premium, so that it is not
    /// asked twice at once.
    private var isCheckingPremiumEnd = false

    private func publishCertificateInvalid(_ invalid: Bool) {
        if invalid != isCertificateInvalid {
            isCertificateInvalid = invalid
        }
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init() {
        updateMultiLCStatus()
        // Every import and removal writes the password through this defaults
        // object, so watching it catches each one as it happens. Published on
        // the next turn of the main queue: a write can come from inside a view
        // update, where publishing is not allowed.
        certificateObservation = LCUtils.appGroupUserDefault.observe(\.LCCertificatePassword) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshCertificateStatus() }
        }
        // A certificate replaced under the same password changes only this.
        certificateDataObservation = LCUtils.appGroupUserDefault.observe(\.LCCertificateData) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshCertificateValidity() }
        }
        // What is kept of Premium, from whichever check, and the user having
        // looked at it.
        premiumObservations = [
            UserDefaults.standard.observe(\.FSSubscriptionStatus) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshPremiumAttention() }
            },
            UserDefaults.standard.observe(\.FSSubscriptionEndDate) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshPremiumAttention() }
            },
            UserDefaults.standard.observe(\.FlekPremiumEndSeen) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshPremiumAttention() }
            },
        ]
        // Another FlekDeck sharing the app group can import or remove one
        // while this one is in the background, and a certificate or Premium
        // can run out meanwhile.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshCertificateStatus()
            self?.refreshPremiumAttention()
        }
        // After launch rather than during it: reading the certificate loads
        // the signing library.
        DispatchQueue.main.async { [weak self] in
            self?.refreshCertificateValidity()
            self?.refreshPremiumAttention()
        }
    }
}

extension UserDefaults {
    /// The stored certificate password, declared only so that it can be
    /// observed: key-value observing reaches a defaults key through a
    /// property of exactly the key's name. The same goes for the ones below.
    @objc dynamic var LCCertificatePassword: String? {
        string(forKey: "LCCertificatePassword")
    }

    @objc dynamic var LCCertificateData: Data? {
        data(forKey: "LCCertificateData")
    }

    @objc dynamic var FSSubscriptionStatus: Bool {
        bool(forKey: "FSSubscriptionStatus")
    }

    @objc dynamic var FSSubscriptionEndDate: String? {
        string(forKey: "FSSubscriptionEndDate")
    }

    @objc dynamic var FlekPremiumEndSeen: String? {
        string(forKey: "FlekPremiumEndSeen")
    }
}

extension Bundle {
    /// The per-device ID FlekSt0re's signer writes into the Info.plist of each
    /// build it signs. A build it did not sign carries the key empty: nil.
    var flekStoreDeviceID: String? {
        let value = (infoDictionary?["encryptedUdid"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

extension String {
    /// Whether this is shaped like an iOS device's UDID: eight hex digits, a
    /// hyphen and sixteen more on devices since the iPhone XS, forty hex
    /// digits on older ones. What is left in a half-cleared field is not.
    var isDeviceUDID: Bool {
        range(of: "^([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil
    }
}

class DataManager {
    static let shared = DataManager()
    let model = SharedModel()
}

class AlertHelper<T> : ObservableObject {
    @Published var show = false
    private var result : T?
    private var c : UnsafeContinuation<Void, Never>? = nil
    
    func open() async -> T? {
        await withUnsafeContinuation { c in
            self.c = c
            Task { await MainActor.run {
                self.show = true
            }}
        }
        return self.result
    }
    
    func close(result: T?) {
        if let c {
            self.result = result
            c.resume()
            self.c = nil
        }
        DispatchQueue.main.async {
            self.show = false
        }

    }
}

typealias YesNoHelper = AlertHelper<Bool>

class InputHelper : AlertHelper<String> {
    @Published var initVal = ""
    
    func open(initVal: String) async -> String? {
        self.initVal = initVal
        return await super.open()
    }
    
    override func open() async -> String? {
        self.initVal = ""
        return await super.open()
    }
}

extension String: @retroactive Error {}
extension String: @retroactive LocalizedError {
    public var errorDescription: String? { return self }
        
    private static var enBundle : Bundle? = {
        let language = "en"
        let path = Bundle.main.path(forResource:language, ofType: "lproj")
        let bundle = Bundle(path: path!)
        return bundle
    }()
    
    var loc: String {
        let message = NSLocalizedString(self, comment: "")
        if message != self {
            return message
        }

        if let forcedString = String.enBundle?.localizedString(forKey: self, value: nil, table: nil){
            return forcedString
        }else {
            return self
        }
    }
    
    func localizeWithFormat(_ arguments: CVarArg...) -> String{
        String.localizedStringWithFormat(self.loc, arguments)
    }
    
    func sanitizeNonACSII() -> String  {
        filter { $0.isASCII }
    }
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa")!
    static let tipa = UTType(filenameExtension: "tipa")!
    static let dylib = UTType(filenameExtension: "dylib")!
    static let deb = UTType(filenameExtension: "deb")!
    static let lcFramework = UTType(filenameExtension: "framework", conformingTo: .package)!
    static let p12 = UTType(filenameExtension: "p12")!
    static let mobileProvision = UTType(filenameExtension: "mobileprovision")!
}

extension Color {
    func readableTextColor() -> Color {
        let color = Color(.systemBackground)
        let percentage = 0.5
        
        // https://stackoverflow.com/a/78649412
        let components1 = UIColor(self).cgColor.components!
        var bgR: CGFloat = 0, bgG: CGFloat = 0, bgB: CGFloat = 0, bgA: CGFloat = 0
        UIColor(color).getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA)
        var red = (1.0 - percentage) * components1[0] + percentage * bgR
        var green = (1.0 - percentage) * components1[1] + percentage * bgG
        var blue = (1.0 - percentage) * components1[2] + percentage * bgB
        //var alpha = (1.0 - percentage) * components1[3] + percentage * bgA
        //UIColor(mix(with: Color(.systemBackground), by: 0.5)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        let brightness = (0.2126*red + 0.7152*green + 0.0722*blue);
        let brightnessOffset = brightness < 0.5 ? 0.4 : -0.4
        red = min(Double(red) + brightnessOffset, 1.0)
        green = min(Double(green) + brightnessOffset, 1.0)
        blue = min(Double(blue) + brightnessOffset, 1.0)
        return Color(red: red, green: green, blue: blue)
    }
}

struct ImageDocument: FileDocument {
    var data: Data
    
    static var readableContentTypes: [UTType] {
        [UTType.image] // Specify that the document supports image files
    }
    
    // Initialize with data
    init(uiImage: UIImage) {
        self.data = uiImage.pngData()!
    }
    
    // Function to read the data from the file
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    
    // Write data to the file
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}


struct SiteAssociationDetailItem : Codable {
    var appID: String?
    var appIDs: [String]?
    
    func getBundleIds() -> [String] {
        var ans : [String] = []
        // get rid of developer id
        if let appID = appID, appID.count > 11 {
            let index = appID.index(appID.startIndex, offsetBy: 11)
            let modifiedString = String(appID[index...])
            ans.append(modifiedString)
        }
        if let appIDs = appIDs {
            for appID in appIDs {
                if appID.count > 11 {
                    let index = appID.index(appID.startIndex, offsetBy: 11)
                    let modifiedString = String(appID[index...])
                    ans.append(modifiedString)
                }
            }
        }
        return ans
    }
}

struct AppLinks : Codable {
    var details : [SiteAssociationDetailItem]?
}

struct SiteAssociation : Codable {
    var applinks: AppLinks?
}


struct JITStreamerEBLaunchAppResponse : Codable {
    let ok: Bool
    let launching: Bool
    let position: Int?
    let error: String?
}

struct JITStreamerEBStatusResponse : Codable {
    let ok: Bool
    let done: Bool
    let position: Int?
    let error: String?
}

struct JITStreamerEBMountResponse : Codable {
    let ok: Bool
    let mounting: Bool
    let error: String?
}



extension NSNotification {
    static let InstallAppNotification = Notification.Name.init("InstallAppNotification")
}

public enum LCTabIdentifier: Hashable {
    case sources
    case apps
    case browse
    case tweaks
    case settings
    case search
}


enum BatchMoveError: LocalizedError {
    case emptySource(URL)
    case sourceDoesNotExist(URL)
    case sourceIsNotReachable(URL, underlying: Error)
    case sourceParentIsNotWritable(URL)
    case destinationAlreadyExists(URL)
    case destinationParentDoesNotExist(URL)
    case destinationParentIsNotDirectory(URL)
    case destinationParentIsNotWritable(URL)
    case duplicateSource(URL)
    case duplicateDestination(URL)
    case sourceEqualsDestination(URL)
    case moveWouldPlaceDirectoryInsideItself(source: URL, destination: URL)
    case moveFailed(source: URL, destination: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .emptySource(let url):
            return "Source URL is invalid: \(url)"
        case .sourceDoesNotExist(let url):
            return "Source does not exist: \(url.path)"
        case .sourceIsNotReachable(let url, let error):
            return "Source is not reachable: \(url.path). \(error)"
        case .sourceParentIsNotWritable(let url):
            return "Source parent is not writable: : \(url.path)"
        case .destinationAlreadyExists(let url):
            return "Destination already exists: \(url.path). Delete or rename this file/folder to continue."
        case .destinationParentDoesNotExist(let url):
            return "Destination parent directory does not exist: \(url.path)"
        case .destinationParentIsNotDirectory(let url):
            return "Destination parent is not a directory: \(url.path)"
        case .destinationParentIsNotWritable(let url):
            return "Destination parent is not writable: \(url.path)"
        case .duplicateSource(let url):
            return "Duplicate source URL in move list: \(url.path)"
        case .duplicateDestination(let url):
            return "Duplicate destination URL in move list: \(url.path)"
        case .sourceEqualsDestination(let url):
            return "Source and destination are the same: \(url.path)"
        case .moveWouldPlaceDirectoryInsideItself(let source, let destination):
            return "Cannot move directory \(source.path) inside itself at \(destination.path)"
        case .moveFailed(let source, let destination, let error):
            return "Failed to move \(source.path) to \(destination.path). \(error)"
        }
    }

}

