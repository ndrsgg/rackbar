import SwiftUI

@main
struct RackbarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // The menu bar is where Rackbar lives day to day; it has no Dock icon
        // (LSUIElement) until the settings window asks for one.
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            Image(systemName: "server.rack")
                .accessibilityLabel("Rackbar")
        }
        .menuBarExtraStyle(.window)

        // Tokens and the ssh setup get a real window: a popover closes the
        // moment you switch to the browser to create a token.
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
