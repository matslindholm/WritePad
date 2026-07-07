//
//  WritePadApp.swift
//  WritePad
//
//  Created by Stefan Leuker on 06.07.26.
//

import SwiftUI

#if os(macOS)
/// Quits WritePad when its last window closes, matching single-window Mac apps.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

@main
struct WritePadApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: AppSettings
    @State private var library: ProjectLibrary
    @State private var pronunciation: PronunciationSettings
    @State private var narration: NarrationCoordinator

    init() {
        let settings = AppSettings()
        let pronunciation = PronunciationSettings()
        _settings = State(initialValue: settings)
        _library = State(initialValue: ProjectLibrary(settings: settings))
        _pronunciation = State(initialValue: pronunciation)
        _narration = State(initialValue: NarrationCoordinator(pronunciation: pronunciation))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(library)
                .environment(pronunciation)
                .environment(narration)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: narration.handleEnteredBackground()
                    case .active: narration.handleEnteringForeground()
                    default: break
                    }
                }
        }

        #if os(macOS)
        Settings {
            MacSettingsView()
                .environment(settings)
                .environment(library)
                .environment(pronunciation)
                .environment(narration)
        }
        #endif
    }
}
