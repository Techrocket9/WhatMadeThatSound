import SwiftUI
import WhatMadeThatSoundKit

/// Days with recorded sounds, newest first. While searching, only days with
/// matches are listed, with their match counts.
struct SidebarView: View {
    @Environment(LogStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Label("All Activity", systemImage: "clock.arrow.circlepath")
                .badge(store.days.reduce(0) { $0 + $1.count })
                .tag(LogStore.Selection.all)

            Section(store.searchText.isEmpty ? "Days" : "Days with Matches") {
                ForEach(store.days) { day in
                    Label(Formatting.dayTitle(day.id), systemImage: "calendar")
                        .badge(day.count)
                        .tag(LogStore.Selection.day(day.id))
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.hasLoaded, store.days.isEmpty, !store.searchText.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
