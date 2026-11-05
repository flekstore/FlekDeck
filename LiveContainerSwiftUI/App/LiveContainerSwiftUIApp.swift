//
//  LiveContainerSwiftUIApp.swift
//  LiveContainer
//
//  Created by s s on 2025/5/16.
//
import SwiftUI

@main
struct LiveContainerSwiftUIApp : SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // appDataFolderNames and tweakFolderNames used to be @State here and were
    // threaded down as bindings. Upstream moved them onto DataManager's shared
    // model, which is populated at the end of init() below, so the views read
    // them from the environment instead.
    @StateObject private var flekstoreSharedModel = FlekstoreSharedModel()
    
    init() {
        // The identifier guest apps check against lives in this app's Info.plist,
        // but a guest launched in parallel runs inside LiveProcess.appex and reads
        // the bundle of *that* process, which never carries it. Publish it to the
        // app group here so the extension is handed the value rather than having to
        // find this bundle on disk — a search that lands on the wrong app entirely
        // when the extension in use belongs to another LiveContainer install.
        if let hostEncryptedUdid = Bundle.main.infoDictionary?["encryptedUdid"] as? String,
           !hostEncryptedUdid.isEmpty {
            LCUtils.appGroupUserDefault.set(hostEncryptedUdid, forKey: "LCHostEncryptedUdid")
        } else {
            // A build FlekSt0re did not sign has none to hand on, and must not hand
            // on one an earlier FlekSt0re install left behind. The app group
            // outlives the app while anything else shares it, and a signing tool
            // can give every app it signs with one certificate the same group.
            LCUtils.appGroupUserDefault.removeObject(forKey: "LCHostEncryptedUdid")
        }
        // The same goes for how long Premium lasts, which guests are told too.
        FlekPremium.publish()
        FlekBuiltInJIT.adoptWhereNothingIsChosen()

        LCPath.clearStaleShareInbox()

        FlekImageMemory.configureCaches()

        // Before the app list is read. A private app opened in a window is staged
        // into the app group until the window closes, so a FlekDeck killed with
        // windows open leaves copies behind, and builds before the staging folder
        // left them among the shared apps, where they were listed as a second,
        // shared copy of the app.
        LCWindowStaging.recoverAfterLaunch()
        MultitaskManager.beginFlushingGuestsWhenBackgrounded()

        let fm = FileManager()
        var tempAppDataFolderNames : [String] = []
        var tempTweakFolderNames : [String] = []
        
        var tempApps: [LCAppModel] = []
        var tempArm32EmuApps: [LCAppModel] = []
        var tempHiddenApps: [LCAppModel] = []
        var tempURLSchemes: Set<String>? = DataManager.shared.model.multiLCStatus != 2 ? Set() : nil

        do {
            // load apps
            try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
            var appDirs = try fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)
            // Launch is the one moment nothing else is in these folders, so it is
            // where an install that died mid-replace gets its app back.
            if appDirs.contains(where: { $0.hasSuffix(LCPath.replacingSuffix) }) {
                LCPath.recoverInterruptedReplaces(in: LCPath.bundlePath, contents: appDirs)
                appDirs = try fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)
            }
            for model in Self.loadApps(appDirs, in: LCPath.bundlePath, isShared: false) {
                if model.appInfo.isHidden {
                    tempHiddenApps.append(model)
                } else {
                    tempApps.append(model)
                    tempURLSchemes?.formUnion(model.appInfo.urlSchemes() as! [String])
                }
                if model.appInfo.is32bitEmulator {
                    tempArm32EmuApps.append(model)
                }
            }
            if LCPath.lcGroupDocPath != LCPath.docPath {
                try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
                var appDirsShared = try fm.contentsOfDirectory(atPath: LCPath.lcGroupBundlePath.path)
                if appDirsShared.contains(where: { $0.hasSuffix(LCPath.replacingSuffix) }) {
                    LCPath.recoverInterruptedReplaces(in: LCPath.lcGroupBundlePath, contents: appDirsShared)
                    appDirsShared = try fm.contentsOfDirectory(atPath: LCPath.lcGroupBundlePath.path)
                }
                for model in Self.loadApps(appDirsShared, in: LCPath.lcGroupBundlePath, isShared: true) {
                    if model.appInfo.isHidden {
                        tempHiddenApps.append(model)
                    } else {
                        tempApps.append(model)
                        tempURLSchemes?.formUnion(model.appInfo.urlSchemes() as! [String])
                    }
                    if model.appInfo.is32bitEmulator {
                        tempArm32EmuApps.append(model)
                    }
                }
            }
            // load document folders
            try fm.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)
            let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
            for dataDir in dataDirs {
                let dataDirUrl = LCPath.dataPath.appendingPathComponent(dataDir)
                if !dataDirUrl.hasDirectoryPath {
                    continue
                }
                tempAppDataFolderNames.append(dataDir)
            }
            
            // load tweak folders
            try fm.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)
            let tweakDirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
            for tweakDir in tweakDirs {
                let tweakDirUrl = LCPath.tweakPath.appendingPathComponent(tweakDir)
                if !tweakDirUrl.hasDirectoryPath {
                    continue
                }
                let folderName = tweakDir.hasSuffix(".disabled") ? String(tweakDir.dropLast(".disabled".count)) : tweakDir
                tempTweakFolderNames.append(folderName)
            }
        } catch {
            NSLog("[LC] error:\(error)")
        }
        
        DataManager.shared.model.apps = tempApps
        DataManager.shared.model.arm32EmuApps = tempArm32EmuApps
        DataManager.shared.model.hiddenApps = tempHiddenApps
        DataManager.shared.model.appDataFolderNames = tempAppDataFolderNames
        DataManager.shared.model.tweakFolderNames = tempTweakFolderNames
        if let tempURLSchemes {
            UserDefaults.lcShared().set(Array(tempURLSchemes), forKey: "LCGuestURLSchemes")
        }
    }
    
    /// The apps in one Applications folder, in folder order.
    ///
    /// FlekDeck starts afresh every time an app run in single mode is left, and
    /// the list is read before anything shows. Each app is a few small files —
    /// its Info.plist, its settings, one file per data container — and read one
    /// after another on the main thread, a phone with many apps waited for every
    /// one of them on every return. They are read side by side instead: no app's
    /// reading touches another's files.
    private static func loadApps(_ contents: [String], in folder: URL, isShared: Bool) -> [LCAppModel] {
        let names = contents.filter { $0.hasSuffix(".app") }
        var models = [LCAppModel?](repeating: nil, count: names.count)
        models.withUnsafeMutableBufferPointer { buffer in
            let slots = buffer
            DispatchQueue.concurrentPerform(iterations: names.count) { index in
                let appInfo = LCAppInfo(bundlePath: "\(folder.path)/\(names[index])")!
                appInfo.relativeBundlePath = names[index]
                appInfo.isShared = isShared
                slots[index] = LCAppModel(appInfo: appInfo)
            }
        }
        return models.compactMap { $0 }
    }
    
    var body: some Scene {
        WindowGroup(id: "Main") {
            LCTabView()
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(DataManager.shared.model)
                .environmentObject(LCAppSortManager.shared)
                .environmentObject(flekstoreSharedModel)
        }
        
        if UIApplication.shared.supportsMultipleScenes, #available(iOS 16.1, *) {
            MultitaskScene()
        }
    }

}

/// The multi-window scene, isolated behind its own availability-annotated type.
///
/// `WindowGroup(id:for:)` produces `PresentedWindowContent`, which is iOS 16.0+.
/// Inlined in `body` above, that type would land in the App's `Body` — and
/// SwiftUI resolves `Body` at launch, before any `#available` check runs, so
/// iOS 15 would trap on start rather than skipping the scene. Referencing
/// `MultitaskScene` instead is safe on every version because its metadata lives
/// in our own binary; its `Body` is only resolved if the scene is actually
/// built, which the guard above prevents. There is no `AnyScene`, so this
/// indirection is the Scene-level equivalent of the AnyView erasure used for
/// version-gated views.
@available(iOS 16.1, *)
private struct MultitaskScene: Scene {
    var body: some Scene {
        WindowGroup(id: "appView", for: String.self) { $id in
            if let id {
                MultitaskAppWindow(id: id)
            }
        }
    }
}
