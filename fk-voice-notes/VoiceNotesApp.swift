import SwiftUI

@main
struct VoiceNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = TranscriptionStore()

    var body: some Scene {
        Window("fk-voice-notes", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear { appDelegate.store = store }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audio…") { store.showImporter = true }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: TranscriptionStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Files dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in store?.add(urls) }
    }
}
