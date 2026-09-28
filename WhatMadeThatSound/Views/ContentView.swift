import SwiftUI
import WhatMadeThatSoundKit

struct ContentView: View {
    @Environment(LogStore.self) private var store
    @State private var selectedSessionIDs = Set<AudioSession.ID>()
    @State private var showsInspector = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                MonitoringBanner()
                SessionListView(selection: $selectedSessionIDs) {
                    showsInspector = true
                }
            }
            .inspector(isPresented: $showsInspector) {
                SessionInspector(session: selectedSession)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "App, process or device")
        .navigationTitle("What Made That Sound")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                MonitoringStatusButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show details of the selected sound")
            }
        }
    }

    private var selectedSession: AudioSession? {
        guard selectedSessionIDs.count == 1, let id = selectedSessionIDs.first else { return nil }
        return store.assembler.session(withID: id)
    }

    private var subtitle: String {
        let count = store.matchingSessionCount
        let sounds = count == 1 ? String(localized: "1 sound") : String(localized: "\(count) sounds")
        switch store.selection {
        case let .day(day):
            return "\(Formatting.dayTitle(day)) · \(sounds)"
        case .all, nil:
            return String(localized: "All Activity · \(sounds)")
        }
    }
}

#Preview {
    ContentView()
        .environment(LogStore())
        .environment(ServiceController())
        .frame(width: 1000, height: 600)
}
