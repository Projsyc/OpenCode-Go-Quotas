import SwiftUI

@main
struct OpenCodeGoQuotasApp: App {
    @State private var store = AccountStore()
    @State private var githubStore = GitHubAccountStore()
    @State private var totpClock = TOTPClock()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(githubStore)
                .environment(totpClock)
                .task { totpClock.start() }
                .onDisappear { totpClock.stop() }
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}
