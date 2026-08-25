import SwiftUI

@main
struct OpenCodeGoQuotasApp: App {
    @State private var store = AccountStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}
