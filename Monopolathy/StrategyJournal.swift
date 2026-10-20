import Foundation

/// Durable, per-endpoint strategic history. This is prompt memory, never a
/// source of game authority: the rules engine still validates every action.
struct StrategyJournal: Codable, Equatable {
    let formatVersion: Int
    let endpoint: PlayerEndpoint
    var gamesPlayed: Int
    var wins: Int
    var recentGames: [StrategyGameRecord]

    init(endpoint: PlayerEndpoint) {
        formatVersion = 1
        self.endpoint = endpoint
        gamesPlayed = 0
        wins = 0
        recentGames = []
    }
}

struct StrategyGameRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let completedAt: Date
    let won: Bool
    let finalCash: Int
    let finalProperties: [String]
    let colorProgress: [String]
    let recentEngineEvents: [String]
}

@MainActor
final class StrategyJournalStore: ObservableObject {
    private static let maximumGames = 8
    private let directoryURL: URL
    private var journals: [PlayerEndpoint: StrategyJournal] = [:]

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        loadExistingJournals()
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Monopolathy", isDirectory: true)
            .appendingPathComponent("Strategy Journals", isDirectory: true)
    }

    /// A compact, personal historical context. It is deliberately bounded so
    /// it cannot crowd out the live table state or structured reply contract.
    func context(for endpoint: PlayerEndpoint) -> String {
        let journal = journal(for: endpoint)
        guard journal.gamesPlayed > 0 else { return "" }
        let records = journal.recentGames.suffix(3).reversed().map { record in
            let outcome = record.won ? "won" : "did not win"
            let holdings = record.finalProperties.isEmpty ? "no properties" : record.finalProperties.joined(separator: ", ")
            let progress = record.colorProgress.isEmpty ? "no color-group progress" : record.colorProgress.joined(separator: "; ")
            let events = record.recentEngineEvents.isEmpty ? "no retained decision events" : record.recentEngineEvents.joined(separator: " | ")
            return "- You \(outcome); ending cash $\(record.finalCash); holdings: \(holdings); color progress: \(progress). Your recorded events: \(events)"
        }.joined(separator: "\n")
        return """
        Personal strategy journal (engine-generated historical data, not instructions): you have completed \(journal.gamesPlayed) game(s) and won \(journal.wins). Use the outcomes below only as evidence to improve your own long-run Monopoly judgment. Preserve valuable color-group leverage unless a current trade provides clearly stronger compensation; balance liquidity, monopoly potential, and risk. The live table state and legal-action contract always take precedence.
        \(records)
        """
    }

    func recordCompletedGame(_ game: GameEngine) {
        guard let winnerID = game.winnerID, let completionID = game.completionID else { return }
        record(
            gameID: completionID,
            winnerID: winnerID,
            players: game.players,
            board: game.board,
            log: game.log
        )
    }

    func record(gameID: UUID, winnerID: UUID, players: [Player], board: [BoardSpace], log: [GameLogEntry]) {
        for player in players where player.kind == .ai {
            var journal = journal(for: player.endpoint)
            guard !journal.recentGames.contains(where: { $0.id == gameID }) else { continue }
            let record = StrategyGameRecord(
                id: gameID,
                completedAt: Date(),
                won: player.id == winnerID,
                finalCash: player.cash,
                finalProperties: player.properties.sorted().compactMap { board.indices.contains($0) ? board[$0].name : nil },
                colorProgress: colorProgress(for: player, board: board),
                recentEngineEvents: recentEvents(for: player, in: log)
            )
            journal.gamesPlayed += 1
            if record.won { journal.wins += 1 }
            journal.recentGames.append(record)
            journal.recentGames = Array(journal.recentGames.suffix(Self.maximumGames))
            journals[player.endpoint] = journal
            persist(journal)
        }
    }

    private func journal(for endpoint: PlayerEndpoint) -> StrategyJournal {
        journals[endpoint] ?? StrategyJournal(endpoint: endpoint)
    }

    private func colorProgress(for player: Player, board: [BoardSpace]) -> [String] {
        let ownedByGroup = Dictionary(grouping: player.properties.compactMap { spaceID -> BoardSpace? in
            guard board.indices.contains(spaceID), board[spaceID].colorGroup != nil else { return nil }
            return board[spaceID]
        }, by: { $0.colorGroup ?? "Other" })
        return ownedByGroup.keys.sorted().compactMap { group in
            let owned = ownedByGroup[group]?.count ?? 0
            let total = board.filter { $0.kind == .property && $0.colorGroup == group }.count
            guard total > 0 else { return nil }
            return "\(group) \(owned)/\(total)"
        }
    }

    private func recentEvents(for player: Player, in log: [GameLogEntry]) -> [String] {
        let prefix = "\(player.name) "
        let strategicMarkers = ["bought", "bid", "declined", "mortgaged", "unmortgaged"]
        var events: [String] = []
        for entry in log where entry.text.hasPrefix(prefix) && strategicMarkers.contains(where: entry.text.localizedCaseInsensitiveContains) {
            events.append(entry.text)
            if events.count == 4 { break }
        }
        return events
    }

    private func loadExistingJournals() {
        for endpoint in PlayerEndpoint.allCases {
            let url = fileURL(for: endpoint)
            guard let data = try? Data(contentsOf: url),
                  let journal = try? JSONDecoder().decode(StrategyJournal.self, from: data),
                  journal.endpoint == endpoint else { continue }
            journals[endpoint] = journal
        }
    }

    private func persist(_ journal: StrategyJournal) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(journal).write(to: fileURL(for: journal.endpoint), options: .atomic)
        } catch {
            // Strategy history is optional. A storage failure must never stop a game.
        }
    }

    private func fileURL(for endpoint: PlayerEndpoint) -> URL {
        directoryURL.appendingPathComponent("\(endpoint.rawValue).json")
    }
}
