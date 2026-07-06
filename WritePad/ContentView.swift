//
//  ContentView.swift
//  WritePad
//
//  Created by Stefan Leuker on 06.07.26.
//

import SwiftUI

struct ContentView: View {
    @Environment(ProjectLibrary.self) private var library

    @State private var selection: BookProject.ID?
    @State private var showingAdd = false
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(selection: $selection,
                           showingAdd: $showingAdd,
                           showingSettings: $showingSettings)
        } detail: {
            if let project = library.projects.first(where: { $0.id == selection }) {
                ProjectDetailView(project: project)
                    .id(project.id)
            } else {
                ContentUnavailableView(
                    "Select a Book", systemImage: "books.vertical",
                    description: Text("Check out a manuscript repository to start listening."))
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddRepositoryView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}
