import SwiftUI

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No games yet",
                systemImage: "gamecontroller",
                description: Text("Import a game to get started. The library, GRDB store and playability grades arrive in Phase 0/1.")
            )
            .navigationTitle("Library")
        }
    }
}
