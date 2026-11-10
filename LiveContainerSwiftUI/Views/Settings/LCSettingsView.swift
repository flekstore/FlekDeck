//
//  LCSettingsView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UserNotifications

enum JITEnablerType : Int, CaseIterable, Identifiable {
    var id: Int { rawValue }
    case SideJITServer = 0
    case StikJIT = 1
    case JITStreamerEBLegacy = 2
    case StikJITLC = 3
    case SideStore = 4
    case StosDebug = 5
    case StosDebugLC = 6
    case StikJITHeadless = 7
    
    var displayName: String {
        switch self {
        case .StikJIT: "StikDebug"
        case .StikJITLC: "StikDebug (Another FlekDeck)"
        case .StosDebug: "StosDebug"
        case .StosDebugLC: "StosDebug (Another FlekDeck)"
        case .SideStore: "SideStore"
        case .JITStreamerEBLegacy: "JitStreamer-EB (Relaunch)"
        case .SideJITServer: "SideJITServer/JITStreamer 2.0"
        case .StikJITHeadless: "FlekJIT (Built-in)"
        }
    }

    /// Left out of the menu, and still honoured for whoever chose it before.
    var isNoLongerOffered: Bool {
        self == .SideStore || self == .JITStreamerEBLegacy
    }
}

struct LCSettingsView: View {
    @State private var showIdentityReport = false
    @State private var showBackgroundInstallReport = false
    @State var errorShow = false
    @State var errorInfo = ""

    @StateObject private var installLC2Alert = AlertHelper<Int>()
    
    @StateObject private var certificateImportFromBuiltInSideStoreAlert = YesNoHelper()
    @StateObject private var certificateRemoveAlert = YesNoHelper()
    
    @AppStorage("LCFrameShortcutIcons") var frameShortIcon = false
    @AppStorage("LCSwitchAppWithoutAsking") var silentSwitchApp = false
    @AppStorage("LCOpenWebPageWithoutAsking") var silentOpenWebPage = false
    @AppStorage("LCDontSignApp", store: LCUtils.appGroupUserDefault) var dontSignApp = false
    @AppStorage("LCCustomBundleIdEnabled", store: LCUtils.appGroupUserDefault) var customBundleIdEnabled = false
    @AppStorage("LCStrictHiding", store: LCUtils.appGroupUserDefault) var strictHiding = false
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = true
    @AppStorage("LCLaunchMultitaskMaximized") var launchMultitaskMaximized = false
    // Multitask switcher bar: rounded (tall, concave corners) when on, flat short bar when off.
    // Bar rounding amount, 0 (flat) … 100 (fully rounded concave corners).
    @AppStorage("LCMultitaskBarLedgeAmount", store: LCUtils.appGroupUserDefault) var barLedgeAmount: Double = 60
    // Multitask control haptics: 0 (off) … 3 (strongest). Read back through
    // MultitaskDockManager, which also carries over the on/off switch this
    // slider replaced.
    @AppStorage("LCMultitaskHapticsLevel", store: LCUtils.appGroupUserDefault) var multitaskHapticsLevel = 1
    @AppStorage("LCAutoEndPiP", store: LCUtils.appGroupUserDefault) var autoEndPiP = false
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = true
    @AppStorage("LCRestartTerminatedApp", store: LCUtils.appGroupUserDefault) var restartTerminatedApp = true
    @AppStorage("LCMaxOneAppOnStage", store: LCUtils.appGroupUserDefault) var onlyOneAppOnStage = false
    @AppStorage("LCRedirectURLToHost", store: LCUtils.appGroupUserDefault) var redirectURLToHost = false
    @AppStorage("LCShowRotationPanel", store: LCUtils.appGroupUserDefault) var showRotationPanel = false
    @AppStorage("LCMultitaskHomeBar", store: LCUtils.appGroupUserDefault) var usesBottomSwipe = FlekDeviceModel.usesBottomSwipeByDefault
    
    @AppStorage("LCSideJITServerAddress", store: LCUtils.appGroupUserDefault) var sideJITServerAddress : String = ""
    @AppStorage("LCDeviceUDID", store: LCUtils.appGroupUserDefault) var deviceUDID: String = ""
    @AppStorage(FlekUDIDProfile.pageAddressKey) private var udidProfilePageAddress = ""
    @AppStorage("LCJITEnablerType", store: LCUtils.appGroupUserDefault) var JITEnabler: JITEnablerType = .SideJITServer
    
    @State var store : Store = .Unknown
    
    @AppStorage("LCLoadTweaksToSelf") var injectToLCItelf = false
    @AppStorage("LCIgnoreJITOnLaunch") var ignoreJITOnLaunch = false
    @AppStorage("LCSelected32BitEmulator", store: LCUtils.appGroupUserDefault) var selected32BitEmulator : String = ""
    @AppStorage("LCKeepSelectedWhenQuit") var keepSelectedWhenQuit = false
    @AppStorage("LCWaitForDebugger") var waitForDebugger = false
    @AppStorage("LCSharePrivateDataWithLiveProcess") var sharePrivateDataWithLiveProcess = false
    @AppStorage("LCOpenPrivateAppsWithoutCopying") var openPrivateAppsWithoutCopying = false
    @AppStorage("FlekPairWithoutCode") var pairWithoutCode = false
#if DEBUG
    @AppStorage("FlekDebugPremium") var debugPremium = false
    @State private var premiumOfferShown = false
#endif
    /// Diagnostics' Forget Device: asked which to forget, and what it did,
    /// while the alert says so.
    @State private var forgetDeviceAsked = false
    @State private var forgottenDeviceNote: String?
    @AppStorage("BKNoWatchdogs") var disableLiveProcessWatchdog = false
    
    // Written from inside LiveProcess by LCHostIdentityInit. The extension has no
    // UI of its own and cannot be attached to on someone else's device, so the app
    // group is the only way to see whether the identifier reached a parallel guest.
    @AppStorage("LCHostIdentityStatus", store: LCUtils.appGroupUserDefault)
    private var hostIdentityStatus: String = ""

    @AppStorage("LCHostIdentityUdid", store: LCUtils.appGroupUserDefault)
    private var hostIdentityUdid: String = ""

    @AppStorage("LCHostIdentityDetail", store: LCUtils.appGroupUserDefault)
    private var hostIdentityDetail: String = ""

    // Published by this app at launch for the extension to pick up.
    @AppStorage("LCHostEncryptedUdid", store: LCUtils.appGroupUserDefault)
    private var publishedEncryptedUdid: String = ""

    // What the continued-processing scheduler did with the last install. Whether a
    // background task was refused, submitted, or ran is invisible from the outside:
    // all three look like an install that simply stopped when the app went away.
    @AppStorage("LCBackgroundInstallStatus", store: LCUtils.appGroupUserDefault)
    private var backgroundInstallStatus: String = ""

    @AppStorage("LCBackgroundInstallDetail", store: LCUtils.appGroupUserDefault)
    private var backgroundInstallDetail: String = ""

    // How many times guest code actually asked the extension for the identifier,
    // and who asked first. Installing the hook and being read are different facts.
    @AppStorage("LCHostIdentityReads", store: LCUtils.appGroupUserDefault)
    private var hostIdentityReads: Int = -1

    @AppStorage("LCHostIdentityReader", store: LCUtils.appGroupUserDefault)
    private var hostIdentityReader: String = ""

    // Size and build date of the dylib that read the identifier, so two devices can
    // be compared from screenshots when the files themselves cannot be moved.
    @AppStorage("LCHostIdentityReaderFingerprint", store: LCUtils.appGroupUserDefault)
    private var hostIdentityReaderFingerprint: String = ""

    // The guest names itself. The image name above can only ever say which
    // library made the call, and resolves to nothing when the caller sits in a
    // hook trampoline — which is why this row used to say only "guest code".
    @AppStorage("LCHostIdentityReaderApp", store: LCUtils.appGroupUserDefault)
    private var hostIdentityReaderApp: String = ""
    
    @AppStorage("LCBetaBannerOverride", store: LCUtils.appGroupUserDefault) private var betaBannerOverride: Int = 0

    @EnvironmentObject private var sharedModel : SharedModel
    
    /// Read from the shared model, which follows the stored password, so a
    /// certificate imported anywhere else — at launch, or through a
    /// flekdeck://certificate link — shows here as well.
    
    @State private var isViewAppeared = false
    
    let storeName = LCUtils.getStoreName()
    
    init() {
        _store = State(initialValue: LCUtils.store())
    }
    
    // Kept as separate lines on purpose. "What this app published" and "what a
    // parallel guest actually resolved" are different facts, and collapsing them
    // into one value hides the case worth catching: a guest that read an
    // identifier belonging to some other install.
    private var multitaskIdentityValue: String {
        hostIdentityUdid.isEmpty ? "" : hostIdentityUdid
    }

    // These live in app group defaults, which outlive the app itself — reinstalling
    // does not clear them. So a status with no timestamp beside it may well be from
    // a previous install, which is exactly how a diagnostic starts lying.
    private var multitaskIdentityDate: Date? {
        LCUtils.appGroupUserDefault.object(forKey: "LCHostIdentityDate") as? Date
    }

    // One line for the row. Everything else moved behind a tap once this grew past
    // what a Settings row can show — a truncated diagnostic is worse than a short
    // one, because the ellipsis hides exactly the part being looked for.
    private var multitaskIdentitySummary: String {
        guard !hostIdentityStatus.isEmpty else {
            return publishedEncryptedUdid.isEmpty
                ? "This app has no identifier to publish"
                : "Launch an app in parallel to confirm it arrives"
        }
        let carried = hostIdentityUdid.isEmpty ? "Not carried" : "Carried"
        switch hostIdentityReads {
        case ..<0: return "\(carried) · read count pending · tap for detail"
        case 0: return "\(carried) · never read · tap for detail"
        default:
            let reader = hostIdentityReader.isEmpty ? "guest code" : hostIdentityReader
            return "\(carried) · read \(hostIdentityReads)× by \(reader) · tap for detail"
        }
    }

    // The full picture, for the alert and the clipboard. Copyable matters more than
    // readable here: comparing two devices means sending this to someone else.
    private var multitaskIdentityReport: String {
        var lines: [String] = []
        lines.append("App: \(publishedEncryptedUdid.isEmpty ? "—" : publishedEncryptedUdid)")
        lines.append("Guest: \(hostIdentityUdid.isEmpty ? "—" : hostIdentityUdid)")
        if hostIdentityStatus.isEmpty {
            lines.append("No app has been launched in parallel yet.")
        } else {
            lines.append(hostIdentityDetail.isEmpty ? hostIdentityStatus : "\(hostIdentityStatus) (\(hostIdentityDetail))")
            if let date = multitaskIdentityDate {
                lines.append("Recorded \(date.formatted(.relative(presentation: .numeric)))")
            }
            switch hostIdentityReads {
            case ..<0: lines.append("Read count not reported yet")
            case 0: lines.append("Never read by the guest")
            default:
                let app = hostIdentityReaderApp.isEmpty ? "guest code" : hostIdentityReaderApp
                lines.append("Read \(hostIdentityReads)× by \(app)")
                if !hostIdentityReader.isEmpty {
                    lines.append("via \(hostIdentityReader)")
                }
                if !hostIdentityReaderFingerprint.isEmpty {
                    lines.append(hostIdentityReaderFingerprint)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private var backgroundInstallDate: Date? {
        LCUtils.appGroupUserDefault.object(forKey: "LCBackgroundInstallDate") as? Date
    }

    private var backgroundInstallReport: String {
        guard !backgroundInstallStatus.isEmpty else {
            return "No install has asked for background time yet."
        }
        var lines = [backgroundInstallStatus]
        if !backgroundInstallDetail.isEmpty {
            lines.append(backgroundInstallDetail)
        }
        if let date = backgroundInstallDate {
            lines.append("Recorded \(date.formatted(.relative(presentation: .numeric)))")
        }
        return lines.joined(separator: "\n")
    }

    // Only "Submitted", "Running" and "Finished" mean the chain is intact; every
    // other status is a step that refused.
    private var backgroundInstallIsProblem: Bool {
        !["", "Submitted", "Running", "Finished"].contains(backgroundInstallStatus)
    }

    // What FlekDeck knows this device by: the number FlekSt0re filed it under,
    // and whether an ID for the UDID profile is kept to find it again by.
    private var forgetDeviceStatus: String {
        let device = FlekPremium.deviceNumber.map { "Device \($0)" } ?? "No device"
        return device + (FlekUDIDProfile.hasKeptID ? " · ID kept" : " · No ID")
    }

    // Orange only when something is genuinely wrong: a parallel launch that produced
    // no identifier, or one that produced an identifier this app never published.
    private var multitaskIdentityIsProblem: Bool {
        if hostIdentityStatus.isEmpty {
            return publishedEncryptedUdid.isEmpty
        }
        if hostIdentityUdid.isEmpty {
            return true
        }
        if hostIdentityReads == 0 {
            return true
        }
        return !publishedEncryptedUdid.isEmpty && hostIdentityUdid != publishedEncryptedUdid
    }

    /// Name of the step the haptics slider currently sits on, shown beside it —
    /// a strength is easier to recognise by name than by a bare number, and the
    /// left end being "Off" is the part worth being explicit about.
    private var multitaskHapticsLevelName: String {
        switch multitaskHapticsLevel {
        case 1: return "lc.flek.haptics.light".loc
        case 2: return "lc.flek.haptics.medium".loc
        case 3: return "lc.flek.haptics.strong".loc
        default: return "lc.flek.haptics.off".loc
        }
    }

    /// The slider's Double seen as the stored whole step, playing each new step's
    /// feedback as it is reached: the setting is about how something feels, so it
    /// has to be felt while it is being set. Silent at the off end, and silent
    /// while a drag stays within one step.
    private var multitaskHapticsBinding: Binding<Double> {
        Binding(
            get: { Double(multitaskHapticsLevel) },
            set: { newValue in
                let level = min(max(Int(newValue.rounded()), 0), 3)
                guard level != multitaskHapticsLevel else { return }
                multitaskHapticsLevel = level
                if #available(iOS 16.0, *) {
                    MultitaskDockManager.playHaptic(level: level)
                }
            }
        )
    }

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Categories
                Section {
                    // Where the certificate is imported and Premium shown. It
                    // carries the red mark while there is no certificate, or one
                    // that no longer works, and while an end of Premium has not
                    // been looked at — what the Settings icon on the home screen
                    // counts.
                    NavigationLink { generalPage } label: {
                        HStack(spacing: 0) {
                            categoryRow("lc.flek.cat.general".loc, "gear", .gray, iconSize: 20)
                            if sharedModel.generalNeedsAttention {
                                Spacer(minLength: 8)
                                attentionMark
                            }
                        }
                    }
                    NavigationLink { FlekPersonalizationView() } label: {
                        categoryRow("lc.flek.personalization".loc, "paintbrush.fill", .purple)
                    }
                    NavigationLink { launchBehaviorPage } label: {
                        categoryRow("lc.flek.cat.launch".loc, FlekSymbol.appGrid, .blue, iconSize: 22)
                    }
                    if #available(iOS 16.1, *) {
                        NavigationLink { multitaskPage } label: {
                            categoryRow("lc.flek.cat.multitask".loc, "macwindow.on.rectangle", .green)
                        }
                    }
                    NavigationLink { jitPage } label: {
                        // The mark an app set to launch with JIT carries on its
                        // icon, on a dark tile.
                        categoryRow("lc.flek.cat.jit".loc, FlekSymbol.jit, .black)
                    }
                    NavigationLink { contentRestrictionsPage } label: {
                        categoryRow("lc.flek.cat.content".loc, "nosign", .red, iconSize: 20)
                    }
                    NavigationLink { signingPage } label: {
                        categoryRow("lc.flek.cat.signing".loc, "signature", .mint, iconSize: 15)
                    }
                    NavigationLink { LCTweaksView() } label: {
                        categoryRow("Tweaks", "wrench.and.screwdriver.fill", .orange, iconSize: 17)
                    }
                    NavigationLink { FlekAboutView() } label: {
                        categoryRow("lc.flek.cat.about".loc, "info.circle", .gray, iconSize: 20)
                    }
                }
                Section {
                    linkRow("FlekIconFlekStore", "FlekSt0re.com", action: openFlekstore)
                    linkRow("GitHub", "GitHub - LiveContainer", action: openGitHub)
                    linkRow("GitHub", "lc.flek.sourceCode".loc, action: openFlekDeckRepo)
                    linkRow("Twitter", "khanhduytran0", action: openTwitter)
                    linkRow("GitHub", "GitHub - Huge_Black", action: openGitHub2)
                } footer: {
                    // Centred so it closes the page with the version and build lines
                    // below it, rather than trailing off to one side of them. A Text
                    // sizes to its content, so it takes the full width first and
                    // centres what it wraps onto a second line.
                    Text("lc.settings.warning".loc)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                
                VStack(spacing: 2){
                    Text(LCUtils.getVersionInfo())
                        .foregroundStyle(.gray)
                        // The branch and hash make this long enough to wrap in the
                        // width the padding below leaves it. Two lines to wrap into,
                        // and shrinking only once that is not enough either.
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .multilineTextAlignment(.center)
                        // Filling the width gives the five-tap developer-mode gesture
                        // the whole line to land on, not just the glyphs.
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 5) {
                            sharedModel.developerMode = true
                        }
                    
                    HStack(spacing:0){
                        Text("Build: ")
                            .foregroundStyle(.gray)
                        // A Link here would take over the whole Form row and swallow
                        // the version tap above it, so open the URL by hand instead.
                        Text("FlekSt0re")
                            .foregroundStyle(.blue)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: openFlekstore)
                    }
                    // The size this line has always been. Only the version below the
                    // footer was meant to match it, and a font set here is nearer the
                    // text than the one on the stack, so it is the one that lands.
                    .font(.body)
                    
                }
                .font(.footnote)
                // Line up with the footer above rather than with the cards: a row is
                // kept 20pt clear of each window edge, and a section footer a further
                // 20pt inside that, so a long version string wraps where the warning
                // does. The padding sits within the frame so the background still
                // covers the whole row — inset the row itself and the cell's own card
                // colour shows along both edges.
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(UIColor.systemGroupedBackground))
                .listRowInsets(EdgeInsets())

                if BetaOverlayManager.isBetaiOS {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iOS Beta Detected")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.red)
                                Text("Beta versions of iOS may cause certificate revocation. Apps and features may not work correctly. Please roll back to the stable release version.")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if sharedModel.developerMode {
                    // Developer-only. This is a diagnostic — it exists to compare what the
                    // guest's identity check actually saw against what the app holds — and it
                    // means nothing to anyone not chasing that particular mismatch.
                    Section {
                        // MARK: - Multitask identity
                        // What reached the last app launched in parallel. A guest reads
                        // the identifier from the host process' bundle, which is the
                        // extension rather than the app, so this is the value the check
                        // actually saw — not the one the app holds.
                        HStack(spacing: 12) {
                            Image(systemName: "square.on.square")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.indigo)
                                .cornerRadius(8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Multitask UDID")
                                    .font(.body)

                                Text("App: \(publishedEncryptedUdid.isEmpty ? "—" : publishedEncryptedUdid)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.3)

                                Text("Guest: \(multitaskIdentityValue.isEmpty ? "—" : multitaskIdentityValue)")
                                    .font(.subheadline)
                                    .foregroundColor(multitaskIdentityIsProblem ? .orange : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.3)

                                Text(multitaskIdentitySummary)
                                    .font(.caption)
                                    .foregroundColor(multitaskIdentityIsProblem ? .orange : .secondary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                            }
                            Spacer()

                            if !multitaskIdentityValue.isEmpty {
                                Button(action: {
                                    UIPasteboard.general.string = multitaskIdentityValue
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 18))
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Copied as well as shown: the point of this row is usually to
                            // send it to someone comparing another device.
                            UIPasteboard.general.string = multitaskIdentityReport
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showIdentityReport = true
                        }
                        .alert("Multitask UDID", isPresented: $showIdentityReport) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text("\(multitaskIdentityReport)\n\nCopied to clipboard.")
                        }

                        // MARK: - Background install
                        // Whether the last install got background time, and if not,
                        // which step said no.
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.teal)
                                .cornerRadius(8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Background Install")
                                    .font(.body)

                                Text(backgroundInstallStatus.isEmpty ? "Never asked" : backgroundInstallStatus)
                                    .font(.subheadline)
                                    .foregroundColor(backgroundInstallIsProblem ? .orange : .secondary)

                                if !backgroundInstallDetail.isEmpty {
                                    Text(backgroundInstallDetail)
                                        .font(.caption)
                                        .foregroundColor(backgroundInstallIsProblem ? .orange : .secondary)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.8)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = backgroundInstallReport
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showBackgroundInstallReport = true
                        }
                        .alert("Background Install", isPresented: $showBackgroundInstallReport) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text("\(backgroundInstallReport)\n\nCopied to clipboard.")
                        }

                        // MARK: - Forget device
                        // Back to a device FlekDeck has not filed, to try the UDID
                        // profile and the restore at launch again. Keeping the ID
                        // is what deleting FlekDeck does; forgetting it too is a
                        // device FlekDeck has never been on.
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.slash")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.orange)
                                .cornerRadius(8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Forget Device")
                                    .font(.body)

                                Text(forgetDeviceStatus)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            forgetDeviceAsked = true
                        }
                        .confirmationDialog("Forget Device", isPresented: $forgetDeviceAsked, titleVisibility: .visible) {
                            Button("Forget Device") {
                                FlekUDIDProfile.forgetDevice(andID: false)
                                forgottenDeviceNote = "Its UDID, number and Premium are gone, and its ID is kept. Open FlekDeck again to find it by that ID, or install the profile again."
                            }
                            Button("Forget Device and Its ID", role: .destructive) {
                                FlekUDIDProfile.forgetDevice(andID: true)
                                forgottenDeviceNote = "Its UDID, number, Premium and ID are gone, as on a device FlekDeck has never been on."
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("FlekDeck forgets this device's UDID, number and Premium. With its ID kept, FlekDeck finds the device again when opened, as after being reinstalled.")
                        }
                        .alert("Device Forgotten",
                               isPresented: Binding(get: { forgottenDeviceNote != nil }, set: { if !$0 { forgottenDeviceNote = nil } }),
                               presenting: forgottenDeviceNote) { _ in
                            Button("OK", role: .cancel) {}
                        } message: { note in
                            Text(note)
                        }
                    } header: {
                        Text("Diagnostics")
                    }
                    Section {
                        if #available(iOS 16.1, *) {
                            Toggle(isOn: $showRotationPanel) {
                                Text("lc.settings.rotationOverlay".loc)
                            }
                            .onChange(of: showRotationPanel) { on in
                                // The overlay always runs; this only draws it. If
                                // the panel is being taken away, drop any manual
                                // lock with it, so a lock cannot outlive the only
                                // control that releases it.
                                if !on { LCRotationLock.isManual = false }
                                LCRotationLockOverlay.setPanelVisible(on)
                            }
                        }
                        Toggle(isOn: $injectToLCItelf) {
                            Text("lc.settings.injectLCItself".loc)
                        }
                        Toggle(isOn: $ignoreJITOnLaunch) {
                            Text("Ignore JIT on Launching App")
                        }
                        Toggle(isOn: $keepSelectedWhenQuit) {
                            Text("Keep Selected App when Quit")
                        }
                        Toggle(isOn: $waitForDebugger) {
                            Text("Wait For Debugger")
                        }
                        Toggle(isOn: $sharePrivateDataWithLiveProcess) {
                            Text("Allow Private Data access from LiveProcess")
                        }
                        // Hands a private app to its window through bookmarks, as
                        // upstream does, instead of staging a copy into the app
                        // group. There to test whether bookmarks open on a given
                        // build and iOS version; see "App group staging" in
                        // AppSceneViewController.m.
                        Toggle(isOn: $openPrivateAppsWithoutCopying) {
                            Text("Open Private Apps in Windows Without Copying")
                        }
                        Toggle(isOn: $disableLiveProcessWatchdog) {
                            Text("Disable LiveProcess watchdog termination")
                        }
                        // Has "Create on This Device" advertise a pairing that
                        // asks for no code, to find out whether iOS goes along
                        // with it. If it asks anyway, the code is 000000.
                        Toggle(isOn: $pairWithoutCode) {
                            Text("Create Pairing File Without a Code")
                        }
#if DEBUG
                        // Stands in for a subscription in a build run from
                        // Xcode, which has no FlekSt0re device ID to look one
                        // up by. Release builds have neither this nor what
                        // reads it.
                        Toggle(isOn: $debugPremium) {
                            Text("Premium (Debug Builds Only)")
                        }
                        // The Premium sheet whatever Premium stands at, to try
                        // the checkout on a device that has Premium already:
                        // nothing else offers the sheet then.
                        Button {
                            premiumOfferShown = true
                        } label: {
                            Text("Show Premium Offer")
                        }
                        .sheet(isPresented: $premiumOfferShown) {
                            FlekPremiumOfferView()
                        }
#endif
                        // A page for Premium Access to open in place of FlekSt0re's
                        // profile, for trying a server out. HTTPS only.
                        HStack {
                            Text("UDID Profile Page")
                            Spacer()
                            TextField("https://", text: $udidProfilePageAddress)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        Button {
                            exportDyld()
                        } label: {
                            Text("Export Dyld")
                        }
                        Button {
                            Task { await nukeSideStore() }
                        } label: {
                            Text("Nuke SideStore")
                        }
                        Button {
                            exportMainBundle()
                        } label: {
                            Text("Export Main Bundle")
                        }
                        Button {
                            resetSymbolOffsets()
                        } label: {
                            Text("Reset Symbol Offsets")
                        }
                        #if is32BitSupported
                        HStack {
                            Text("LiveExec32 .app path")
                            Spacer()
                            TextField("", text: $liveExec32Path)
                                .multilineTextAlignment(.trailing)
                        }
                        #endif
                        // Upstream puts this picker in its own section at the root of
                        // Settings. FlekDeck's root is a list of categories, so it lives
                        // here instead, and only once an emulator is actually installed.
                        if !sharedModel.arm32EmuApps.isEmpty {
                            Picker(selection: $selected32BitEmulator) {
                                Text("lc.common.none".loc).tag("")
                                ForEach(sharedModel.arm32EmuApps, id: \.self) { app in
                                    Text(app.appInfo.displayName()).tag(app.appInfo.relativeBundlePath!)
                                }
                            } label: {
                                Text("lc.settings.selected32BitEmulator".loc)
                            }
                        }
                    } header: {
                        Text("Developer Settings")
                    } footer: {
                        Text("lc.settings.injectLCItselfDesc".loc)
                    }
                }
            }
            .navigationTitle("lc.tabView.settings".loc)
            .navigationBarTitleDisplayMode(.large)
            .alert("lc.common.error".loc, isPresented: $errorShow){
            } message: {
                Text(errorInfo)
            }
            .alert("lc.settings.removeCertificate".loc, isPresented: $certificateRemoveAlert.show) {
                Button(role: .destructive) {
                    certificateRemoveAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }
                
                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateRemoveAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.removeCertificateDesc".loc)
            }
            .alert("lc.settings.importCertFromBuiltinSideStore".loc, isPresented: $certificateImportFromBuiltInSideStoreAlert.show) {
                Button {
                    certificateImportFromBuiltInSideStoreAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateImportFromBuiltInSideStoreAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.importCertFromBuiltinSideStoreDesc".loc)
            }
        }
        .onAppear {
            if !isViewAppeared {
                guard sharedModel.selectedTab == .settings, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        // A column, not the whole width, on an iPhone Duo opened out: every page
        // pushed here is laid out for a phone.
        .modifier(FlekReadableColumn())
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .settings, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }

    /// An external-link row. The artwork is already a full-bleed tile, so it's sized
    /// and clipped to the same 30pt rounded square as the category icons rather than
    /// drawn at its native size, which is far larger than a row.
    @ViewBuilder
    private func linkRow(_ imageName: String, _ title: String, action: @escaping () -> Void) -> some View {
        // These open URLs rather than pushing a view, so there's no NavigationLink to
        // supply a disclosure indicator — it's drawn by hand to match the category
        // rows above. `.plain` keeps the title in the label colour like those rows
        // (a bare Button would tint it), and the content shape makes the whole row
        // tappable rather than just the text.
        Button(action: action) {
            HStack(spacing: 10) {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `iconSize` is per-symbol on purpose. Point size sets the em, not the drawn
    /// shape, and how much of that em a symbol inks varies by design — an enclosed
    /// glyph like `info.circle` or a thin one like `app.grid` reads far smaller than a
    /// `.fill` symbol at the same size. The default suits most of the set; the
    /// densest symbols pass a smaller value rather than everything sharing one size
    /// and half the rows looking undersized.
    @ViewBuilder
    private func categoryRow(_ title: String, _ systemImage: String, _ color: Color,
                             iconSize: CGFloat = 17) -> some View {
        // Laid out by hand rather than with `Label`: its icon-to-title gap is fixed
        // and too wide for a tile this size, and it can't be tightened otherwise.
        let tile = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    tile.fill(color)
                        // Sheen over the colour, brightest at the top and gone by the
                        // bottom. Drawn in the same shape as the fill so it needs no
                        // clipping, and it sits in the background so the white glyph
                        // stays on top of it.
                        .overlay(
                            tile.fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.45), Color.white.opacity(0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        )
                )
            Text(title)
        }
    }

    /// The red mark iOS puts on a Settings row that needs the user, as it
    /// badges General while an update waits.
    private var attentionMark: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 20))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .red)
            .accessibilityLabel(attentionReason)
    }

    /// What the mark is for, the certificate first.
    private var attentionReason: String {
        if sharedModel.needsCertificate {
            return "lc.flek.certificate.notImported".loc
        }
        if sharedModel.isCertificateInvalid {
            return "lc.flek.attention.certificateInvalid".loc
        }
        return "lc.flek.attention.premiumEnded".loc
    }

    @ViewBuilder private var generalPage: some View {
        FlekGeneralView(
            managesCertificate: sharedModel.multiLCStatus != 2,
            onRemoveCertificate: { clearCertificate() },
            jitPage: { jitPage }
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.general".loc).font(.headline) } }
    }

    @ViewBuilder private var launchBehaviorPage: some View {
        Form {
                Section {
                    Toggle(isOn: $silentSwitchApp) {
                        Text("lc.settings.silentSwitchApp".loc)
                    }
                } footer: {
                    Text("lc.settings.silentSwitchAppDesc".loc)
                }
                
                Section {
                    Toggle(isOn: $silentOpenWebPage) {
                        Text("lc.settings.silentOpenWebPage".loc)
                    }
                } footer: {
                    Text("lc.settings.silentOpenWebPageDesc".loc)
                }
                
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.launch".loc).font(.headline) } }
    }

    @ViewBuilder private var multitaskPage: some View {
        Form {
                if #available(iOS 16.1, *) {
                    Section {
                        if(UIApplication.shared.supportsMultipleScenes) {
                            Picker(selection: $multitaskMode) {
                                Text("lc.settings.multitaskMode.virtualWindow".loc).tag(MultitaskMode.virtualWindow)
                                Text("lc.settings.multitaskMode.nativeWindow".loc).tag(MultitaskMode.nativeWindow)
                            } label: {
                                Text("lc.settings.multitaskMode".loc)
                            }
                        }
                        Toggle(isOn: $launchInMultitaskMode) {
                            Text("lc.settings.autoLaunchInMultitaskMode".loc)
                        }
                        
                        if multitaskMode == .virtualWindow {
                            Toggle(isOn: $launchMultitaskMaximized) {
                                Text("lc.settings.launchMultitaskMaximized".loc)
                            }
                            if launchMultitaskMaximized {
                                Toggle(isOn: $onlyOneAppOnStage) {
                                    Text("lc.settings.onlyOneAppOnStage".loc)
                                }
                            }
                            Toggle(isOn: $autoEndPiP) {
                                Text("lc.settings.autoEndPiP".loc)
                            }
                            Toggle(isOn: $skipTerminatedScreen) {
                                Text("lc.settings.skipTerminatedScreen".loc)
                            }
                            if skipTerminatedScreen {
                                Toggle(isOn: $restartTerminatedApp) {
                                    Text("lc.settings.restartTerminatedApp".loc)
                                }
                            }
                            Toggle(isOn: $redirectURLToHost) {
                                Text("lc.settings.redirectURLToHost".loc)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("lc.flek.switcherHaptics".loc)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text(multitaskHapticsLevelName)
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                // Four stops, off at the left end. Every stop plays
                                // its own feedback as it is reached, so the strength
                                // is chosen by feel rather than by name.
                                Slider(value: multitaskHapticsBinding,
                                       in: 0...3, step: 1) {
                                    Text("lc.flek.switcherHaptics".loc)
                                }
                                .tint(.accentColor)
                            }
                            .padding(.vertical, 4)
                            Picker(selection: $usesBottomSwipe) {
                                Text("lc.flek.multitaskControl.assistiveTouch".loc).tag(false)
                                Text("lc.flek.multitaskControl.bottomSwipe".loc).tag(true)
                            } label: {
                                Text("lc.flek.multitaskControl".loc)
                            }
                            .onChange(of: usesBottomSwipe) { _ in
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("MultitaskHomeBarSettingChanged"),
                                    object: nil)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("lc.flek.roundedSwitcherBar".loc)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text("\(Int(barLedgeAmount))%")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                // 0% = flat bar, 100% = fully rounded concave corners,
                                // in 10% steps.
                                Slider(value: $barLedgeAmount, in: 0...100, step: 10) {
                                    Text("lc.flek.roundedSwitcherBar".loc)
                                }
                                .tint(.accentColor)
                                .onChange(of: barLedgeAmount) { _ in
                                    NotificationCenter.default.post(
                                        name: NSNotification.Name("MultitaskBarDesignChanged"),
                                        object: nil)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } footer: {
                        Text("lc.settings.multitaskDesc".loc)
                    }
                }
                
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.multitask".loc).font(.headline) } }
    }

    @ViewBuilder private var jitPage: some View {
        // JIT alone: the certificate that JIT-less takes, with its removal and
        // its diagnosis, is on General.
        Form {
                Section {
                    if JITEnabler == .SideJITServer || JITEnabler == .JITStreamerEBLegacy {
                        HStack {
                            Text("lc.settings.JitAddress".loc)
                            Spacer()
                            TextField(JITEnabler == .SideJITServer ? "http://x.x.x.x:8080" : "http://[fd00::]:9172", text: $sideJITServerAddress)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if JITEnabler == .SideJITServer {
                        HStack {
                            Text("lc.settings.JitUDID".loc)
                            Spacer()
                            TextField("", text: $deviceUDID)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Picker(selection: $JITEnabler) {
                        // StikJIT does not load before iOS 17.4.
                        if #available(iOS 17.4, *) {
                            Text(JITEnablerType.StikJITHeadless.displayName).tag(JITEnablerType.StikJITHeadless)
                        }
                        Text("SideJITServer/JITStreamer 2.0").tag(JITEnablerType.SideJITServer)
                        Text("StikDebug").tag(JITEnablerType.StikJIT)
                        Text("StikDebug (Another FlekDeck)").tag(JITEnablerType.StikJITLC)
                        // Not offered any more: SideStore, whose link does not
                        // enable JIT on its own, and JitStreamer-EB, which is
                        // no longer maintained. One chosen earlier stays
                        // listed, as the menu needs a row for the selection.
                        if JITEnabler.isNoLongerOffered {
                            Text(JITEnabler.displayName).tag(JITEnabler)
                        }
                    } label: {
                        Text("lc.settings.jitEnabler".loc)
                    }
                    // StikDebug is set up outside FlekDeck, which can only
                    // explain how.
                    if JITEnabler == .StikJIT {
                        NavigationLink {
                            FlekStikDebugGuideView()
                        } label: {
                            Label("lc.flek.jit.stikdebug.help".loc, systemImage: "questionmark.circle")
                        }
                    }
                    
                } footer: {
                    // FlekJIT is what a copy starts on, and the one enabler
                    // that takes Premium, so under it the rest of the menu is
                    // said to be free.
                    Text((JITEnabler == .StikJITHeadless ? "lc.flek.jit.enablerFooter" : "lc.settings.JitDesc").loc)
                }
                // The pairing file is the primary FlekDeck's, as it is upstream.
                if JITEnabler == .StikJITHeadless, sharedModel.multiLCStatus == 0 {
                    FlekBuiltInJITSection()
                }
                
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.jit".loc).font(.headline) } }
    }

    @ViewBuilder private var contentRestrictionsPage: some View {
        Form {
                Section{
                    AgeConfirmationView()
                } header: {
                    Text("Sensitive Content")
                } footer: {
                    Text("Enabling this option will grant access to applications with strict age restrictions and the \"Adult\" category.")
                }
                
                if sharedModel.isHiddenAppUnlocked {
                    Section {
                        Toggle(isOn: $strictHiding) {
                            Text("lc.settings.strictHiding".loc)
                        }
                    } footer: {
                        Text("lc.settings.strictHidingDesc".loc)
                    }
                }
                
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.content".loc).font(.headline) } }
    }

    @ViewBuilder private var signingPage: some View {
        Form {
                Section {
                    Toggle(isOn: $dontSignApp) {
                        Text("lc.settings.dontSign".loc)
                    }
                } footer: {
                    Text("lc.settings.dontSignDesc".loc)
                }
                
                Section {
                    Toggle(isOn: $customBundleIdEnabled) {
                        Text("lc.settings.customBundleId".loc)
                    }
                } footer: {
                    Text("lc.settings.customBundleIdDesc".loc)
                }
                
                Section {
                    NavigationLink {
                        LCDataManagementView()
                    } label: {
                        Text("lc.settings.dataManagement".loc)
                    }
                }
                
                if (store != .Unknown && store != .ADP) || LCUtils.isAppGroupAltStoreLike() {
                    Section{
                        NavigationLink {
                            LCMultiLCManagementView()
                        } label: {
                            if sharedModel.multiLCStatus == 0 {
                                Text("lc.settings.multiLCInstall".loc)
                            } else if sharedModel.multiLCStatus == 2 {
                                Text("lc.settings.multiLCIsSecond".loc)
                            }
                            
                        }
                        .disabled(sharedModel.multiLCStatus == 2)
                        
                        if(sharedModel.multiLCStatus == 2) {
                            NavigationLink {
                                LCJITLessDiagnoseView()
                            } label: {
                                Text("lc.settings.jitlessDiagnose".loc)
                            }
                        }
                    } header: {
                        Text("lc.settings.multiLC".loc)
                    } footer: {
                        Text("lc.settings.multiLCDesc".loc)
                    }
                }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.signing".loc).font(.headline) } }
    }

    
    func openFleksign() {
        UIApplication.shared.open(URL(string: "https://fleksign.com")!)
    }

    func openFlekstore() {
        UIApplication.shared.open(URL(string: "https://flekstore.com")!)
    }

    func openGitHub() {
        UIApplication.shared.open(URL(string: "https://github.com/LiveContainer/LiveContainer")!)
    }

    func openFlekDeckRepo() {
        UIApplication.shared.open(URL(string: "https://github.com/flekstore/FlekDeck")!)
    }
    
    func openGitHub2() {
        UIApplication.shared.open(URL(string: "https://github.com/hugeBlack")!)
    }
    
    func openTwitter() {
        UIApplication.shared.open(URL(string: "https://x.com/khanhduytran0")!)
    }

    func clearNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllDeliveredNotifications()
        notificationCenter.removeAllPendingNotificationRequests()
        if #available(iOS 16.0, *) {
            notificationCenter.setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    func exportMainBundle() {
        let url = Bundle.main.bundleURL
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied main bundle to Documents.")
        } catch {
            print("Error copying main bundle \(error)")
        }
    }
    
    func resetSymbolOffsets() {
        LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
    }
    
    func importCertificateFromSideStore() async {
        if UserDefaults.sideStoreExist() {
            if let ans = await certificateImportFromBuiltInSideStoreAlert.open(), ans {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "signingCertificate",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecAttrService as String: "com.kdt.livecontainer",
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]
                
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                
                guard status == errSecSuccess else {
                    if status == errSecItemNotFound {
                        errorInfo = "lc.settings.importCertFromBuiltinSideStore.certNotFounndErr".loc
                        errorShow = true
                    } else {
                        errorInfo = "Keychain read error: \(status)"
                        errorShow = true
                    }
                    return
                }
                
                guard let data = item as? Data else {
                    errorInfo = "Failed to decode certificate data"
                    errorShow = true
                    return
                }
                
                let passwordQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "signingCertificatePassword",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecAttrService as String: "com.kdt.livecontainer",
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]
                
                var passwordItem: CFTypeRef?
                let passwordStatus = SecItemCopyMatching(passwordQuery as CFDictionary, &passwordItem)
                var password = ""
                if passwordStatus == errSecSuccess,
                   let passwordData = passwordItem as? Data,
                   let pwd = String(data: passwordData, encoding: .utf8) {
                    password = pwd
                }
                
                onSideStoreCertificateCallback(certificateData: data, password: password)
                
                return
            }
        }
        
        let storeScheme : String
        if store == .AltStore {
            storeScheme = "altstore-classic"
        } else {
            storeScheme = "sidestore"
        }
        
        guard let url = URL(string: "\(storeScheme.lowercased())://certificate?callback_template=flekdeck%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29") else {
            errorInfo = "Failed to initialize certificate import URL."
            errorShow = true
            return
        }
        await UIApplication.shared.open(url)
    }
    func onSideStoreCertificateCallback(certificateData: Data, password: String) {
        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
    }
    
    /// Forgets the stored certificate. General asks first, in words of its own
    /// that depend on the certificate.
    func clearCertificate() {
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateUpdateDate")
        
        UserDefaults.standard.set(nil, forKey: "LCAppGroupID")
    }
    
    func nukeSideStore() async {
        guard let doRemove = await certificateRemoveAlert.open(), doRemove else {
            return
        }
        do {
            let fm = FileManager.default
            let sidestoreAppGroupURL = LCPath.lcGroupDocPath.deletingLastPathComponent()
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Database"))
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Apps"))
        } catch {
            print("wtf \(error)")
        }
    }
    
    func exportDyld() {
        let url = URL(fileURLWithPath: "/usr/lib/dyld")
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied dyld to Documents.")
        } catch {
            print("Error copying dyld \(error)")
        }
    }
    
    func handleURL(url: URL) {
        if url.host == "certificate" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let encodedCert = queryItems["cert"]?.removingPercentEncoding,
                      let password = queryItems["password"],
                      let certData = Data(base64Encoded: encodedCert)
                else { return }
                
                onSideStoreCertificateCallback(certificateData: certData, password: password)
                
            }
        }
    }
}
