//
//  WritePadApp.swift
//  WritePad
//
//  Created by Stefan Leuker on 06.07.26.
//

import SwiftUI

@main
struct WritePadApp: App {
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
        }
    }
}
