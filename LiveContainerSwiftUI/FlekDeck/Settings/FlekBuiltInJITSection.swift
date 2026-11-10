//
//  FlekBuiltInJITSection.swift
//  LiveContainerSwiftUI
//
//  What the JIT page shows while built-in JIT is the selected enabler: its
//  setup, as steps that each tick off once done — the pairing file it connects
//  with, the VPN it connects through, a check that the two work, and the apps
//  to use it for.
//
//  Built-in JIT is a Premium feature, the whole of it. Without Premium the
//  steps give way to an offer of it, and beside that to the free way to JIT,
//  StikDebug, with the guide to setting that up.
//
//  It is meant to be gone through without having read anything: one button on
//  the page is filled at a time, the one to tap next, and the check runs by
//  itself once the two steps before it are done.
//
//  Built-in JIT is StikJIT run by FlekDeck itself. A guest that needs JIT
//  starts a second LiveProcess, which reaches the device's own debug service
//  through a VPN and attaches to the guest — see enableJITWithStikJIT in
//  LCBootstrap. That happens at launch with nothing on screen, so whatever can
//  be set up or found out ahead of it is here.
//

import SwiftUI
import UniformTypeIdentifiers

struct FlekBuiltInJITSection: View {
    private enum Readiness: Equatable {
        case unchecked
        /// With the step under way, as shown.
        case checking(String)
        case ready
        case failed(String)
    }

    /// One at a time: a check opens a tunnel to the device and may mount a disk
    /// image, and two of those at once would mount it twice.
    private static let checkQueue = DispatchQueue(label: "com.fs.flekdeck.builtInJIT.check")

    static let localDevVPNURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    @ObservedObject private var vpn = FlekLoopbackVPN.shared

    @StateObject private var devicePairing = FlekDevicePairing()

    @Environment(\.scenePhase) private var scenePhase

    @State private var pairingFileFound = FlekBuiltInJIT.hasPairingFile
    /// Made on this device rather than imported. Read as the page comes up,
    /// not here: the view is made anew each time the page is redrawn, and
    /// this reads a file.
    @State private var pairingMadeOnDevice = false
    /// By what is kept, from the start, so that the steps are not preceded by
    /// a glimpse of the offer.
    @State private var isPremium = FlekPremium.isActive
    /// While the server is asked about Premium.
    @State private var isCheckingPremium = false
    @State private var showsPremiumSheet = false
    @State private var isChoosingPairingFile = false
    /// While the server is asked, unasked, for the file FlekPair sent.
    @State private var isLookingForPairingFile = false
    @State private var pairingSheet: PairingSheet?
    /// A pairing file came from the server with the computer's guide up. The
    /// guide shows that, and then goes by itself.
    @State private var pairingFileReceived = false
    /// Set from the help sheet, which has to be gone before the file importer
    /// can come up.
    @State private var importsAfterSheet = false
    @State private var readiness = Readiness.unchecked
    /// When the check last passed, or zero. Kept, so that the step stays
    /// ticked between visits, until something it checked has changed.
    @AppStorage("FlekJITReadyAt") private var readyAt = 0.0
    @State private var jitAppCount = 0
    /// Setting the VPN up or turning it on, which takes a moment.
    @State private var isVPNBusy = false
    @State private var notice = ""
    @State private var reportFile: ReportFile?
    @State private var noticeShow = false

    var body: some View {
        Section {
            if let blocker = FlekBuiltInJIT.blocker {
                // In place of the steps, which could only lead to a check that
                // cannot pass.
                Text(blocker)
                    .foregroundStyle(.red)
            } else if !isPremium {
                premiumOffer
            } else {
                pairingStep
                vpnStep
                readinessStep
                if case .failed = readiness {
                    reportRow
                }
                appsStep
                // Not a step: the setup is whole without it.
                if FlekMobileDataShortcut.isOffered {
                    FlekMobileDataShortcutRow()
                }
            }
            DisclosureGroup("lc.flek.jit.more".loc) {
                if pairingFileFound {
                    Button("lc.flek.jit.pairingFile.remove".loc, role: .destructive) {
                        try? FileManager.default.removeItem(at: LCPath.pairingFilePath)
                        pairingFileFound = false
                        pairingMadeOnDevice = false
                        setupChanged()
                    }
                }
                if vpn.isConfigured {
                    Button("lc.flek.jit.vpn.remove".loc, role: .destructive) {
                        runVPN(then: setupChanged) { try await vpn.remove() }
                    }
                    .disabled(isVPNBusy)
                }
                Button("lc.flek.jit.resetImage".loc) {
                    resetDiskImage()
                }
                .disabled(isChecking)
                if isPremium, pairingFileFound, FlekBuiltInJIT.blocker == nil {
                    Button("lc.flek.jit.report.title".loc) {
                        sendReport()
                    }
                    .disabled(isChecking)
                }
            }
            // On the one row that is always here, the steps giving way to a
            // blocker, and for the same reason as the modifiers on the first
            // step: on the section it would be presented once per row.
            .alert("lc.flek.jit.name".loc, isPresented: $noticeShow) {
                Button("lc.common.ok".loc) {}
            } message: {
                Text(notice)
            }
            .sheet(item: $reportFile) { report in
                ActivityViewController(activityItems: [report.url])
            }
        } header: {
            Text("lc.flek.jit.header".loc)
                // A name, to be read as it is written.
                .textCase(nil)
                // On the header, which is there whatever the section shows
                // under it, and is one view: a modifier on the section would
                // be applied to every row, and so run once per row.
                .onAppear {
                    pairingMadeOnDevice = FlekBuiltInJIT.isPairingFileMadeOnDevice
                    isPremium = FlekPremium.isActive
                    if readiness == .unchecked, readyAt > 0, pairingFileFound {
                        readiness = .ready
                    }
                }
                .task {
                    if FlekLoopbackVPN.isAvailable {
                        await vpn.refresh()
                    }
                    await refreshPremium()
                    collectSentPairingFile()
                }
                .onChange(of: scenePhase) { phase in
                    // Back from getting Premium, as likely as not, or from the
                    // computer the pairing file was sent from.
                    if phase == .active {
                        Task {
                            await refreshPremium()
                            collectSentPairingFile()
                        }
                    }
                }
        } footer: {
            Text("lc.flek.jit.footer".loc)
        }
    }

    /// One step of the setup: its number, which becomes a tick once the step is
    /// done, what the step is, a line about it, and the control that does it.
    private func step<Control: View>(_ number: Int, isDone: Bool, title: String, caption: String,
                                     captionColor: Color = .secondary,
                                     @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(isDone ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(captionColor)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 2)
    }

    /// A step's control. Bordered, so that it is the button that is tapped
    /// rather than the whole row; filled where it is the one to go for.
    @ViewBuilder
    private func stepButton(_ title: String, isProminent: Bool = false, action: @escaping () -> Void) -> some View {
        if isProminent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
    }

    /// The step to do next. Its button is the filled one, so that one thing on
    /// the page always stands out as what to tap.
    private var nextStep: Int {
        if !pairingFileFound {
            return 1
        }
        if FlekLoopbackVPN.isAvailable, !vpn.isConfigured {
            return 2
        }
        return isReady ? 4 : 3
    }

    /// The check that passed says nothing about a setup changed since.
    private func setupChanged() {
        readiness = .unchecked
        readyAt = 0
    }

    // MARK: Without Premium

    /// In place of the steps: Premium, as the easy way, with the one filled
    /// button, and under it StikDebug, which is free and takes another app, a
    /// VPN app and a computer, with the guide to setting it up.
    @ViewBuilder
    private var premiumOffer: some View {
        offer(icon: .image("FlekPremium"),
              title: "lc.flek.jit.offer.premium.title".loc,
              caption: "lc.flek.jit.offer.premium.caption".loc) {
            if isCheckingPremium {
                ProgressView()
            } else {
                stepButton("lc.flek.jit.getPremium".loc, isProminent: true) {
                    // With Premium the steps take the offer's place.
                    withPremium {}
                }
            }
        }
        // On one row, as on the first step.
        .sheet(isPresented: $showsPremiumSheet) {
            FlekPremiumOfferView()
        }
        NavigationLink {
            FlekStikDebugGuideView()
        } label: {
            offer(icon: .symbol("wrench.and.screwdriver"),
                  title: "lc.flek.jit.offer.stikdebug.title".loc,
                  caption: "lc.flek.jit.offer.stikdebug.caption".loc) {
                EmptyView()
            }
        }
    }

    /// What an offer shows where a step has its number.
    private enum OfferIcon {
        /// A system symbol, at the size of the number.
        case symbol(String)
        /// An image of FlekDeck's own, fitted to the space the number takes.
        case image(String)
    }

    /// One of the two ways offered, laid out as a step is, with an icon where
    /// a step has its number.
    private func offer<Control: View>(icon: OfferIcon, title: String, caption: String,
                                      @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            // As wide as a step's number, whichever icon it is, so that the
            // offers' titles line up.
            Image(systemName: "1.circle")
                .hidden()
                .overlay {
                    switch icon {
                    case .symbol(let name):
                        Image(systemName: name)
                    case .image(let name):
                        Image(name)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 2)
    }

    /// Runs `proceed` once Premium is settled, with the server where nothing
    /// kept says yes: it may have been got a moment ago. Without Premium the
    /// offer takes the steps' place, and says how to get it.
    private func withPremium(_ proceed: @escaping () -> Void) {
        guard !isCheckingPremium else {
            return
        }
        isCheckingPremium = true
        Task {
            let answer = await FlekPremium.confirm()
            isCheckingPremium = false
            switch answer {
            case .active:
                isPremium = true
                proceed()
            case .inactive:
                isPremium = false
                showsPremiumSheet = true
            case .unconfirmed:
                show("lc.flek.jit.premium.unconfirmed".loc)
            }
        }
    }

    // MARK: 1. Pairing file

    private enum PairingSheet: Identifiable {
        case create
        /// How a pairing file is made on a computer.
        case importHelp

        var id: Self { self }
    }

    /// Whether the pairing file can be made on this device, or why not.
    private enum OnDevicePairing {
        case available
        case needsNewerSystem
        /// The pairing library is not in this build.
        case missing
    }

    private var onDevicePairing: OnDevicePairing {
        guard #available(iOS 27.0, *) else {
            return .needsNewerSystem
        }
        return LCDevicePairing.isAvailable ? .available : .missing
    }

    @ViewBuilder
    private var pairingStep: some View {
        step(1, isDone: pairingFileFound,
             title: "lc.flek.jit.step1.title".loc,
             caption: pairingCaption) {
            if pairingFileFound {
                Menu("lc.flek.jit.replace".loc) {
                    Button {
                        createPairingFile()
                    } label: {
                        Text("lc.flek.jit.pair.create".loc)
                        Text(onDeviceCaption)
                    }
                    .disabled(!isOnDevicePairingOffered)
                    Button("lc.flek.jit.pair.fromComputer".loc) {
                        pairingSheet = .importHelp
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .sheet(item: $pairingSheet, onDismiss: pairingSheetClosed) { sheet in
            switch sheet {
            case .create:
                FlekDevicePairingView(pairing: devicePairing) {
                    pairingFileFound = true
                    pairingMadeOnDevice = true
                    setupChanged()
                    checkOnceSetUp()
                }
            case .importHelp:
                FlekPairingImportHelpView(received: pairingFileReceived) {
                    await takeSentPairingFile()
                } onImport: {
                    importsAfterSheet = true
                }
            }
        }
        // On one row: a modifier on the section would be applied to every row,
        // and so present once per row.
        .betterFileImporter(isPresented: $isChoosingPairingFile, types: Self.pairingFileTypes, multiple: false) { urls in
            importPairingFile(from: urls[0])
        } onDismiss: {
            isChoosingPairingFile = false
        }

        // The two ways to a pairing file, for as long as there is none to use.
        // Making it here comes first wherever the device can do that, and is
        // shown where it cannot, with the reason. The other is a computer's,
        // and always opens its guide: what to do there, and under it the two
        // ways the file gets here, collected from where FlekPair sent it or
        // picked by hand.
        if !pairingFileFound {
            pairingOption(title: "lc.flek.jit.pair.create".loc, caption: onDeviceCaption,
                          button: "lc.flek.jit.create".loc,
                          isProminent: isOnDevicePairingOffered,
                          isEnabled: isOnDevicePairingOffered,
                          isBusy: isCheckingPremium) {
                createPairingFile()
            }
            pairingOption(title: "lc.flek.jit.pair.fromComputer".loc,
                          caption: "lc.flek.jit.pair.fromComputer.caption".loc,
                          button: "lc.flek.jit.import".loc,
                          isProminent: !isOnDevicePairingOffered) {
                pairingSheet = .importHelp
            }
        }
    }

    /// One of the ways to a pairing file, set in under the step it belongs to.
    private func pairingOption(title: String, caption: String, button: String, isProminent: Bool,
                               isEnabled: Bool = true, isBusy: Bool = false,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            // As wide as a step's number, so the text lines up with the step's.
            Image(systemName: "1.circle")
                .font(.title2)
                .hidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView()
            } else {
                stepButton(button, isProminent: isProminent, action: action)
                    .disabled(!isEnabled)
            }
        }
        .padding(.vertical, 2)
    }

    private var isOnDevicePairingOffered: Bool {
        onDevicePairing == .available
    }

    private var onDeviceCaption: String {
        switch onDevicePairing {
        case .available: return "lc.flek.jit.pair.create.caption".loc
        case .needsNewerSystem: return "lc.flek.jit.pair.create.caption.os".loc
        case .missing: return "lc.flek.jit.pair.create.caption.missing".loc
        }
    }

    private var pairingCaption: String {
        guard pairingFileFound else {
            // What the file is for, over the two ways to get one.
            return "lc.flek.jit.step1.caption".loc
        }
        return (pairingMadeOnDevice ? "lc.flek.jit.step1.done.created" : "lc.flek.jit.step1.done").loc
    }

    /// Premium is settled first, as it is for everything here: it may have
    /// ended since the page came up.
    private func createPairingFile() {
        withPremium {
            devicePairing.begin()
            pairingSheet = .create
        }
    }

    private func pairingSheetClosed() {
        pairingFileReceived = false
        // How Cancel and a swipe down end a pairing under way. Once paired
        // there is nothing left to end.
        if devicePairing.state != .paired {
            devicePairing.cancel()
        }
        if importsAfterSheet {
            importsAfterSheet = false
            isChoosingPairingFile = true
        }
    }

    /// What is kept about Premium, and the server's word where that says no,
    /// unless nothing here could be used with it either.
    private func refreshPremium() async {
        isPremium = FlekPremium.isActive
        guard !isPremium, FlekBuiltInJIT.blocker == nil else {
            return
        }
        if await FlekPremium.refresh() == true {
            isPremium = true
        }
    }

    /// A pairing file is a property list whatever it is called; iloader and
    /// SideStore name theirs .mobiledevicepairing.
    private static let pairingFileTypes: [UTType] = [
        .propertyList,
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data),
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data),
    ].compactMap { $0 }

    private func importPairingFile(from url: URL) {
        do {
            try FlekBuiltInJIT.storePairingFile(try Data(contentsOf: url))
            pairingFileTaken()
        } catch {
            show(error.localizedDescription)
        }
    }

    /// There is a pairing file, or another than there was.
    private func pairingFileTaken() {
        pairingFileFound = true
        // Still one made on this device, if that is what was brought back.
        pairingMadeOnDevice = FlekBuiltInJIT.isPairingFileMadeOnDevice
        // The computer's guide has nothing left to say, if that is what is up:
        // the file may have been found while it was being read. It says that
        // the file has come and closes itself.
        if pairingSheet == .importHelp {
            pairingFileReceived = true
        }
        setupChanged()
        checkOnceSetUp()
    }

    /// Takes the pairing file FlekPair sent for this device, when the guide's
    /// Refresh asks for it. What stood in the way, or nil once the file is
    /// taken: the guide is up over the page, and says it itself.
    private func takeSentPairingFile() async -> String? {
        do {
            let file = try await FlekPairingDownload.fetch()
            // With a file in place, what was taken from the server before is
            // nothing new: the server keeps a file until the next is sent.
            // Taking it again would put an old file over the one in use. And
            // where a look without being asked brought it in while this one
            // was out, it would start over the check that look started.
            if pairingFileFound, FlekPairingDownload.wasTaken(file) {
                return "lc.flek.jit.pair.fetch.nothingNew".loc
            }
            try FlekBuiltInJIT.storePairingFile(file)
            FlekPairingDownload.noteTaken(file)
            pairingFileTaken()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Looks for a file FlekPair sent without being asked: as the page comes
    /// up, and when the app is back in front, which is when the user is back
    /// from the computer. Only while there is no pairing file, and saying
    /// nothing of finding none. It does not take again what was taken before:
    /// the server keeps a file until the next is sent, and one removed here is
    /// still there. Nor does it look while a file is being made here: that
    /// one is about to take this one's place, and the check a file brings on
    /// would run across the pairing.
    private func collectSentPairingFile() {
        guard isPremium, !pairingFileFound, pairingSheet != .create,
              FlekBuiltInJIT.blocker == nil, !isLookingForPairingFile else {
            return
        }
        isLookingForPairingFile = true
        Task {
            defer { isLookingForPairingFile = false }
            // A file the user has got another way meanwhile is left alone.
            guard let file = try? await FlekPairingDownload.fetch(),
                  !pairingFileFound, pairingSheet != .create, !FlekPairingDownload.wasTaken(file),
                  (try? FlekBuiltInJIT.storePairingFile(file)) != nil else {
                return
            }
            FlekPairingDownload.noteTaken(file)
            pairingFileTaken()
        }
    }

    // MARK: 2. VPN

    /// The VPN the helper connects through: FlekDeck's own where this copy can
    /// provide one, and LocalDevVPN, which FlekDeck has no way to see or to
    /// start, where it cannot.
    @ViewBuilder
    private var vpnStep: some View {
        if FlekLoopbackVPN.isAvailable {
            step(2, isDone: vpn.isConfigured,
                 title: "lc.flek.jit.step2.title".loc,
                 caption: "lc.flek.jit.step2.caption".loc) {
                if vpn.isConfigured {
                    Toggle("lc.flek.jit.step2.title".loc, isOn: vpnSwitch)
                        .labelsHidden()
                        .disabled(isVPNBusy)
                } else if isVPNBusy {
                    ProgressView()
                } else {
                    stepButton("lc.flek.jit.setUp".loc, isProminent: nextStep == 2) {
                        runVPN(then: checkOnceSetUp) {
                            try await vpn.setUp()
                            try await vpn.connect()
                        }
                    }
                }
            }
        } else {
            step(2, isDone: false,
                 title: "lc.flek.jit.step2.external.title".loc,
                 caption: "lc.flek.jit.step2.external.caption".loc) {
                stepButton("lc.flek.jit.get".loc) {
                    UIApplication.shared.open(Self.localDevVPNURL)
                }
            }
        }
    }

    private var vpnSwitch: Binding<Bool> {
        Binding {
            vpn.isOn
        } set: { isOn in
            if isOn {
                runVPN { try await vpn.connect() }
            } else {
                vpn.disconnect()
            }
        }
    }

    /// `then` follows only where the work went through.
    private func runVPN(then: (() -> Void)? = nil, _ work: @escaping () async throws -> Void) {
        isVPNBusy = true
        Task {
            do {
                try await work()
                isVPNBusy = false
                then?()
            } catch {
                isVPNBusy = false
                show(error.localizedDescription)
            }
        }
    }

    // MARK: 3. Readiness

    private var readinessStep: some View {
        step(3, isDone: isReady,
             title: "lc.flek.jit.step3.title".loc,
             caption: readinessCaption,
             captionColor: readinessColor) {
            if isChecking {
                ProgressView()
            } else {
                stepButton("lc.flek.jit.check".loc, isProminent: nextStep == 3) {
                    checkReadiness()
                }
                .disabled(!pairingFileFound || FlekBuiltInJIT.blocker != nil)
            }
        }
    }

    /// Ready, and with the pairing file still there.
    private var isReady: Bool {
        readiness == .ready && pairingFileFound
    }

    /// Runs the check without being asked once the two steps before it are
    /// done, so that finishing the second of them is all it takes. Not where
    /// the VPN is another app's: whether that is connected cannot be told, and
    /// a check that fails for it would only alarm.
    private func checkOnceSetUp() {
        // After whatever called this has had its changes take.
        DispatchQueue.main.async {
            guard pairingFileFound, FlekBuiltInJIT.blocker == nil, !isChecking, !isReady,
                  FlekLoopbackVPN.isAvailable, vpn.isConfigured else {
                return
            }
            checkReadiness()
        }
    }

    private var isChecking: Bool {
        if case .checking = readiness { return true }
        return false
    }

    private var readinessCaption: String {
        switch readiness {
        case .unchecked:
            return "lc.flek.jit.step3.caption".loc
        case .checking(let step):
            return step
        case .ready:
            return "lc.flek.jit.ready".loc
        case .failed(let reason):
            return reason
        }
    }

    private var readinessColor: Color {
        switch readiness {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    /// Does what a guest's helper does first at launch — reach the device and
    /// mount its developer disk image — but here, where it can be watched, and
    /// with the image left mounted for the launches that follow.
    /// - Parameter report: Records the check, and the device's log while it
    ///   runs, for a report the share sheet is then opened with.
    private func checkReadiness(report: FlekJITReport? = nil) {
        readiness = .checking(Self.stepText(0, -1))
        Task {
            // FlekDeck's own VPN is turned on for the check as it is for a
            // launch. If it does not come up, the check says so in its own way.
            if vpn.isConfigured {
                do {
                    try await vpn.connect()
                    report?.note("VPN turned on")
                } catch {
                    report?.note("VPN did not turn on: \(error.localizedDescription)")
                }
            }
            // Over mobile data the device does not answer however the VPN is,
            // and on no connection at all a VPN that is off cannot start. The
            // check would only say that it timed out and ask about the VPN.
            let isReachable = await FlekBuiltInJIT.isDeviceReachable()
            report?.note(isReachable ? "Device answers through the VPN" : "Device does not answer through the VPN")
            if !isReachable, let reason = await connectionReason() {
                readiness = .failed(reason)
                readyAt = 0
                if let report {
                    Self.checkQueue.async {
                        let file = report.finish(result: reason)
                        DispatchQueue.main.async { reportFinished(file) }
                    }
                }
                return
            }
            Self.checkQueue.async {
                if let report {
                    DispatchQueue.main.async {
                        readiness = .checking("lc.flek.jit.report.recording".loc)
                    }
                    report.startDeviceLog()
                }
                let error = LCUtils.prepareBuiltInJIT { stage, fraction in
                    report?.noteStage(stage, fraction)
                    let step = Self.stepText(stage, fraction)
                    DispatchQueue.main.async {
                        readiness = .checking(step)
                    }
                }
                var file: URL?
                if let report {
                    let result = (error as NSError?).map { "failed — \($0.localizedDescription) (\($0.domain) \($0.code))" } ?? "passed"
                    file = report.finish(result: result)
                }
                DispatchQueue.main.async {
                    if let error = error as NSError? {
                        // Code 1 is StikJITPreflight's "nothing answered", which is
                        // nearly always the VPN that leads back to the device.
                        let hint = error.code == 1 ? "\n" + "lc.flek.jit.unreachableHint".loc : ""
                        readiness = .failed(error.localizedDescription + hint)
                        readyAt = 0
                    } else {
                        readiness = .ready
                        readyAt = Date().timeIntervalSince1970
                    }
                    if report != nil {
                        reportFinished(file)
                    }
                }
            }
        }
    }

    /// Runs the check again for a report, which the share sheet is then opened
    /// with.
    private func sendReport() {
        let vpnState: String
        if !FlekLoopbackVPN.isAvailable {
            vpnState = "FlekDeck's VPN not in this copy (another VPN app is used)"
        } else if !vpn.isConfigured {
            vpnState = "FlekDeck's VPN not set up"
        } else {
            vpnState = "FlekDeck's VPN set up, \(vpn.isOn ? "on" : "off") before the check"
        }
        checkReadiness(report: FlekJITReport(vpn: vpnState))
    }

    private func reportFinished(_ file: URL?) {
        if let file {
            reportFile = ReportFile(url: file)
        } else {
            show("lc.flek.jit.report.notWritten".loc)
        }
    }

    /// A report made, for the share sheet to be opened with.
    struct ReportFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    /// Offered under the check once it has failed: what to do when the steps
    /// to try have not helped.
    private var reportRow: some View {
        Button {
            sendReport()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("lc.flek.jit.report.title".loc)
                Text("lc.flek.jit.report.caption".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isChecking)
    }

    /// Why the device does not answer, where that is down to what it is
    /// connected through, with the one thing to do about it next.
    private func connectionReason() async -> String? {
        switch await FlekBuiltInJIT.connection() {
        case .mobileData:
            // FlekDeck's own VPN has just been turned on, and stays on.
            return (vpn.isConfigured ? "lc.flek.jit.check.mobileData" : "lc.flek.jit.check.mobileData.other").loc
        case .offline where vpn.isConfigured && !vpn.isOn:
            return "lc.flek.jit.check.offline".loc
        default:
            return nil
        }
    }

    /// The stages StikJITPreflight reports, in its numbering.
    private static func stepText(_ stage: Int, _ fraction: Double) -> String {
        let percent = Int((max(0, min(1, fraction)) * 100).rounded())
        switch stage {
        case 1: return "lc.flek.jit.step.checkingImage".loc
        case 2: return String(format: "lc.flek.jit.step.downloading %lld".loc, percent)
        case 3: return String(format: "lc.flek.jit.step.mounting %lld".loc, percent)
        case 4, 5: return "lc.flek.jit.step.verifying".loc
        default: return "lc.flek.jit.step.reaching".loc
        }
    }

    private func resetDiskImage() {
        Self.checkQueue.async {
            let error = LCUtils.resetBuiltInJITDiskImage()
            DispatchQueue.main.async {
                setupChanged()
                show(error?.localizedDescription ?? "lc.flek.jit.resetImage.done".loc)
            }
        }
    }

    // MARK: 4. Apps

    /// The setup enables JIT for no app by itself, so the apps to use it for
    /// are chosen here as its last step rather than one by one in their own
    /// settings, which have the same switch.
    private var appsStep: some View {
        NavigationLink {
            FlekJITAppsView()
        } label: {
            step(4, isDone: jitAppCount > 0,
                 title: "lc.flek.jit.step4.title".loc,
                 caption: jitAppCount > 0 ? String(format: "lc.flek.jit.step4.caption.count %lld".loc, jitAppCount)
                                          : "lc.flek.jit.step4.caption".loc) {
                EmptyView()
            }
        }
        // Also on the way back from the list, where the count changes.
        .onAppear {
            jitAppCount = FlekJITAppsView.countUsingJIT
        }
    }

    private func show(_ text: String) {
        notice = text
        noticeShow = true
    }
}

/// The installed apps, each with the switch that has it launch with JIT: the
/// one in an app's own settings, gathered where JIT is set up.
struct FlekJITAppsView: View {
    /// Hidden apps only while they are unlocked, as everywhere else.
    static var apps: [LCAppModel] {
        let model = DataManager.shared.model
        return model.apps + (model.isHiddenAppUnlocked ? model.hiddenApps : [])
    }

    /// How many of them launch with JIT: those switched on here, and the
    /// 32-bit ones, which always do.
    static var countUsingJIT: Int {
        apps.filter { $0.uiIsJITNeeded || $0.uiIs32bit }.count
    }

    @ObservedObject private var model = DataManager.shared.model

    var body: some View {
        Form {
            Section {
                if Self.apps.isEmpty {
                    Text("lc.flek.jit.apps.empty".loc)
                        .foregroundStyle(.secondary)
                }
                ForEach(Self.apps, id: \.self) { app in
                    Row(app: app)
                }
            } footer: {
                Text("lc.flek.jit.apps.footer".loc)
            }
        }
        .navigationTitle("lc.flek.jit.apps.title".loc)
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Row: View {
        @ObservedObject var app: LCAppModel
        @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

        var body: some View {
            // A 32-bit app runs with JIT whatever is chosen, which is how its
            // own settings show it too.
            Toggle(isOn: app.uiIs32bit ? .constant(true) : $app.uiIsJITNeeded) {
                HStack(spacing: 12) {
                    IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon))
                        .frame(width: 32, height: 32)
                    Text(app.appInfo.displayName() ?? "")
                }
            }
            .disabled(app.uiIs32bit)
        }
    }
}

/// The way to a pairing file that goes by a computer: how the file is made
/// there, and under that the two ways it gets here.
///
/// The tool it sends the user to is FlekPair, FlekSt0re's own: iloader with
/// everything but the export of the file taken out, so that there is one
/// button to click, and which sends the file on for FlekDeck to collect.
/// Refresh collects it, and is the button that stands out. Import Manually is
/// for a file carried over by hand, which is what iloader itself and
/// idevice_pair leave one with: they make the same file and are kept under
/// Other Options, for whoever has one of them already, or is on Linux, which
/// FlekPair is not built for.
struct FlekPairingImportHelpView: View {
    /// FlekPair's newest release, whichever that is by then. The StikDebug
    /// guide sends its readers there too.
    static let flekPairURL = URL(string: "https://github.com/flekstore/FlekPair/releases/latest")!
    /// The same address as it is read and typed.
    static let flekPairAddress = flekPairURL.absoluteString.replacingOccurrences(of: "https://", with: "")
    private static let iloaderURL = URL(string: "https://github.com/nab138/iloader/releases/latest")!
    private static let idevicePairURL = URL(string: "https://github.com/jkcoxson/idevice_pair/releases/latest")!

    /// How long the mark of a file received is up before the sheet goes: long
    /// enough to be seen, and no longer, as the page behind has gone on.
    private static let receivedPause: UInt64 = 1_300_000_000

    /// Whether the file has come, by Refresh here or found without asking
    /// while this was up.
    var received = false
    /// Asks for the file FlekPair sent. What stood in the way, or nil once
    /// the file is taken.
    var onRefresh: () async -> String?
    /// Called when a file is to be picked by hand. The sheet is still up at
    /// that point, so the importer has to wait for it to go.
    var onImport: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isRefreshing = false
    /// Why the last Refresh brought nothing.
    @State private var failure: String?
    /// The mark of a file received is up, and the sheet about to go.
    @State private var showsReceived = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Label("lc.flek.jit.importHelp.step1".loc, systemImage: "1.circle")
                    Label("lc.flek.jit.importHelp.step2".loc, systemImage: "2.circle")
                    Label("lc.flek.jit.importHelp.step3".loc, systemImage: "3.circle")
                }
                Section {
                    Link("lc.flek.jit.importHelp.get".loc, destination: Self.flekPairURL)
                } footer: {
                    // The page is wanted on the computer, not on this device,
                    // so its address is there to be typed as well: the one the
                    // row opens, on a line of its own so that it stays whole.
                    Text(String(format: "lc.flek.jit.importHelp.address %@".loc, Self.flekPairAddress))
                }
                Section {
                    // Filled and the full width, with no row behind it: of the
                    // two ways, the one to go for. It stays filled while it
                    // asks and takes no taps: disabled, it would turn gray
                    // under a spinner drawn for the fill.
                    Button(action: refresh) {
                        HStack(spacing: 8) {
                            if isRefreshing {
                                // Small, so that the button keeps its height
                                // and nothing under it moves.
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text("lc.flek.jit.refresh".loc)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .allowsHitTesting(!isRefreshing)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    if let failure {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button("lc.flek.jit.importHelp.importManually".loc) {
                        onImport()
                        dismiss()
                    }
                } footer: {
                    Text("lc.flek.jit.importHelp.importNote".loc)
                }
                Section {
                    DisclosureGroup("lc.flek.jit.importHelp.other".loc) {
                        Link("iloader", destination: Self.iloaderURL)
                        Link("idevice_pair", destination: Self.idevicePairURL)
                        Text("lc.flek.jit.importHelp.other.note".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("lc.flek.jit.importHelp.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        dismiss()
                    }
                }
            }
        }
        // Over the bar as well: there is nothing left to cancel.
        .overlay {
            if showsReceived {
                FlekPairingReceivedView()
                    .transition(.opacity)
            }
        }
        .onChange(of: received) { hasCome in
            if hasCome {
                showReceived()
            }
        }
        // Ended with the sheet, so that one closed by hand meanwhile is not
        // followed by a second closing, of whatever is up by then.
        .task(id: showsReceived) {
            guard showsReceived else { return }
            try? await Task.sleep(nanoseconds: Self.receivedPause)
            if !Task.isCancelled {
                dismiss()
            }
        }
    }

    private func showReceived() {
        guard !showsReceived else { return }
        UIAccessibility.post(notification: .announcement, argument: "lc.flek.jit.pair.received".loc)
        withAnimation(.easeOut(duration: 0.2)) {
            showsReceived = true
        }
    }

    /// Why nothing came is said under the button: an alert on the page would
    /// be behind this sheet.
    private func refresh() {
        // For a press that is no touch: VoiceOver's, or a keyboard's.
        guard !isRefreshing else { return }
        isRefreshing = true
        failure = nil
        Task {
            let problem = await onRefresh()
            isRefreshing = false
            if let problem {
                failure = problem
            } else {
                showReceived()
            }
        }
    }
}

/// What the computer's guide shows between a pairing file's coming and its own
/// going: the mark an install ends on, larger, which draws its check and gives
/// its light tap as it appears, and a ring going out from it once, as from
/// something that has just landed.
private struct FlekPairingReceivedView: View {
    private static let markSize: CGFloat = 72

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isIn = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.green, lineWidth: 2)
                    .frame(width: Self.markSize, height: Self.markSize)
                    .scaleEffect(isIn ? 1.8 : 1)
                    .opacity(isIn ? 0 : 0.5)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.7).delay(0.15), value: isIn)
                FlekRowCheckmark(accent: .green, size: Self.markSize)
                    .scaleEffect(isIn || reduceMotion ? 1 : 0.6)
                    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6), value: isIn)
            }
            Text("lc.flek.jit.pair.received".loc)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            isIn = true
        }
    }
}
