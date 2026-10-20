import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class GameSession: ObservableObject {
    let game = GameEngine()
    let strategyJournal = StrategyJournalStore()
    var decisionWaitClock = DecisionWaitClock()
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
            strategyJournal.resumeGame(game)
        } catch { present(error) }
    }

    func reviewStrategies() {
        guard game.players.isEmpty || game.phase == .gameOver else {
            let alert = NSAlert()
            alert.messageText = "Finish or leave the current game first"
            alert.informativeText = "Strategy variants are fixed for each game so their results remain attributable."
            alert.runModal()
            return
        }
        pauseAutomaticPlay?()
        let suggestions = strategyJournal.suggestions
        guard !suggestions.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No strategy suggestions are pending"
            alert.informativeText = "Suggestions are proposed after completed games. Current profiles remain unchanged."
            alert.runModal()
            return
        }
        for suggestion in suggestions {
            let profile = suggestion.profile
            let alert = NSAlert()
            alert.messageText = "Strategy suggestion: \(suggestion.endpoint.displayName)"
            alert.informativeText = "Current: \(profile.activeGuidance)\n\nCandidate: \(profile.candidateGuidance ?? "")\n\nLive-game evidence — current: \(profile.baselineWins)/\(profile.baselineGames) wins; candidate: \(profile.candidateWins)/\(profile.candidateGames) wins. Small samples are inconclusive."
            alert.addButton(withTitle: "Keep Testing")
            alert.addButton(withTitle: "Approve Candidate")
            alert.addButton(withTitle: "Discard Candidate")
            switch alert.runModal() {
            case .alertSecondButtonReturn: strategyJournal.approve(suggestion.endpoint)
            case .alertThirdButtonReturn: strategyJournal.discard(suggestion.endpoint)
            default: break
            }
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

@main
struct MonopathyApp: App {
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
                Button("Review Strategy Suggestions…") { session.reviewStrategies() }
            }
        }
    }
}
