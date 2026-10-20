import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class GameSession: ObservableObject {
    let game = GameEngine()
    let strategyJournal = StrategyJournalStore()
    var pauseAutomaticPlay: (() -> Void)?

    func saveGame() {
        pauseAutomaticPlay?()
        let panel = NSSavePanel()
        panel.title = "Save Monopathy Game"
        panel.nameFieldStringValue = "Monopathy Game.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(game.makeSave()).write(to: url, options: .atomic)
        } catch { present(error) }
    }

    func loadGame() {
        pauseAutomaticPlay?()
        let panel = NSOpenPanel()
        panel.title = "Load Monopathy Game"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let save = try JSONDecoder().decode(GameSave.self, from: Data(contentsOf: url))
            guard game.restore(from: save) else { throw CocoaError(.fileReadCorruptFile) }
        } catch { present(error) }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

@main
struct MonopolathyApp: App {
    @StateObject private var session = GameSession()

    var body: some Scene {
        WindowGroup {
            ContentView(game: session.game)
                .environmentObject(session)
                .frame(minWidth: 1100, minHeight: 760)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Monopathy") { AboutBoxController.shared.show() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Game…") { session.saveGame() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Load Game…") { session.loadGame() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
