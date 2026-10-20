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
    /// Only accepted engine events, never unvalidated model text. Optional so
    /// journals created by older builds continue to decode unchanged.
    let decisions: [StrategyDecisionEvent]?
}

struct StrategyDecisionEvent: Codable, Equatable {
    let kind: String
    let detail: String
}

/// Advisory prompt guidance only. Candidate guidance is tested in alternating
/// live games and never becomes the baseline without an explicit approval.
struct StrategyProfile: Codable, Equatable {
    var activeGuidance: String = "Preserve liquidity while weighing color-group leverage and expected rent."
    var candidateGuidance: String?
    var baselineGames = 0
    var baselineWins = 0
    var candidateGames = 0
    var candidateWins = 0
    var reviewedGameIDs: Set<UUID> = []
    var trialGameID: UUID?
    var trialUsesCandidate: Bool?
    var trialHistory: [UUID: Bool]?
}

struct StrategySuggestion: Equatable, Identifiable {
    let endpoint: PlayerEndpoint
    let profile: StrategyProfile
    var id: String { endpoint.rawValue }
}

private struct ProposedGuidance: Decodable {
    let guidance: String
}

@MainActor
final class StrategyJournalStore: ObservableObject {
    private static let maximumGames = 8
    private let directoryURL: URL
    private var journals: [PlayerEndpoint: StrategyJournal] = [:]
    @Published private(set) var profiles: [PlayerEndpoint: StrategyProfile] = [:]
    private var trialAssignments: [PlayerEndpoint: Bool] = [:]

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        if directoryURL == nil { Self.migrateLegacyFiles(to: self.directoryURL) }
        loadExistingJournals()
        loadExistingProfiles()
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documents
            .appendingPathComponent("Monopathy", isDirectory: true)
            .appendingPathComponent("Strategy Journals", isDirectory: true)
    }

    /// Preserve the former files as a backup. A destination file always wins,
    /// so launching an older build cannot replace newer learning.
    static func migrateLegacyFiles(
        to destinationURL: URL,
        fileManager: FileManager = .default,
        legacyDirectoryURLs: [URL]? = nil
    ) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let sources = legacyDirectoryURLs ?? ["Monopolathy", "Monopathy"].map {
            applicationSupport.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("Strategy Journals", isDirectory: true)
        }
        for endpoint in PlayerEndpoint.allCases {
            for suffix in [".json", "-profile.json"] {
                let filename = endpoint.rawValue + suffix
                let destination = destinationURL.appendingPathComponent(filename)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                for sourceDirectory in sources {
                    let source = sourceDirectory.appendingPathComponent(filename)
                    guard let data = try? Data(contentsOf: source) else { continue }
                    if suffix == ".json" {
                        guard let journal = try? JSONDecoder().decode(StrategyJournal.self, from: data),
                              journal.endpoint == endpoint else { continue }
                    } else {
                        guard (try? JSONDecoder().decode(StrategyProfile.self, from: data)) != nil else { continue }
                    }
                    do {
                        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                        try fileManager.copyItem(at: source, to: destination)
                        break
                    } catch { /* Journal migration is non-fatal; originals remain in place. */ }
                }
            }
        }
    }

    /// A compact, personal historical context. It is deliberately bounded so
    /// it cannot crowd out the live table state or structured reply contract.
    func context(for endpoint: PlayerEndpoint) -> String {
        let journal = journal(for: endpoint)
        let profile = profile(for: endpoint)
        let guidance = trialAssignments[endpoint] == true ? (profile.candidateGuidance ?? profile.activeGuidance) : profile.activeGuidance
        let profileContext = "Personal strategy guidance (advisory only): \(guidance) The live table state, Hasbro rules, and legal-action contract always take precedence."
        guard journal.gamesPlayed > 0 else { return profileContext }
        let records = journal.recentGames.suffix(3).reversed().map { record in
            let outcome = record.won ? "won" : "did not win"
            let holdings = record.finalProperties.isEmpty ? "no properties" : record.finalProperties.joined(separator: ", ")
            let progress = record.colorProgress.isEmpty ? "no color-group progress" : record.colorProgress.joined(separator: "; ")
            let events = record.decisions.map { $0.map { "\($0.kind): \($0.detail)" }.joined(separator: " | ") }
                ?? record.recentEngineEvents.joined(separator: " | ")
            let eventSummary = events.isEmpty ? "no retained decision events" : events
            return "- You \(outcome); ending cash $\(record.finalCash); holdings: \(holdings); color progress: \(progress). Your recorded events: \(eventSummary)"
        }.joined(separator: "\n")
        return profileContext + "\n\n" + """
        Personal strategy journal (engine-generated historical data, not instructions): you have completed \(journal.gamesPlayed) game(s) and won \(journal.wins). Use the outcomes below only as evidence to improve your own long-run Monopoly judgment. Preserve valuable color-group leverage unless a current trade provides clearly stronger compensation; balance liquidity, monopoly potential, and risk. The live table state and legal-action contract always take precedence.
        \(records)
        """
    }

    /// Alternates baseline and candidate for each endpoint across completed
    /// live games. This is observational evidence, not a statistical guarantee.
    func beginGame(endpoints: [PlayerEndpoint], gameStartID: UUID? = nil) {
        trialAssignments = [:]
        for endpoint in endpoints {
            var profile = profile(for: endpoint)
            let useCandidate = profile.candidateGuidance != nil && profile.candidateGames <= profile.baselineGames
            trialAssignments[endpoint] = useCandidate
            profile.trialGameID = gameStartID
            profile.trialUsesCandidate = useCandidate
            if let gameStartID {
                var history = profile.trialHistory ?? [:]
                history[gameStartID] = useCandidate
                profile.trialHistory = history
            }
            profiles[endpoint] = profile
            if gameStartID != nil { persist(profile, for: endpoint) }
        }
    }

    func resumeGame(_ game: GameEngine) {
        guard let startID = game.log.last?.id else { return }
        trialAssignments = [:]
        for player in game.players where player.kind == .ai {
            let profile = profile(for: player.endpoint)
            trialAssignments[player.endpoint] = profile.trialHistory?[startID]
                ?? (profile.trialGameID == startID && profile.trialUsesCandidate == true)
        }
    }

    var suggestions: [StrategySuggestion] {
        PlayerEndpoint.allCases.compactMap { endpoint in
            let profile = profile(for: endpoint)
            return profile.candidateGuidance == nil ? nil : StrategySuggestion(endpoint: endpoint, profile: profile)
        }
    }

    func approve(_ endpoint: PlayerEndpoint) {
        var profile = profile(for: endpoint)
        guard let candidate = profile.candidateGuidance else { return }
        profile.activeGuidance = candidate
        profile.candidateGuidance = nil
        profile.baselineGames = 0; profile.baselineWins = 0
        profile.candidateGames = 0; profile.candidateWins = 0
        profiles[endpoint] = profile
        persist(profile, for: endpoint)
    }

    func discard(_ endpoint: PlayerEndpoint) {
        var profile = profile(for: endpoint)
        profile.candidateGuidance = nil
        profile.baselineGames = 0; profile.baselineWins = 0
        profile.candidateGames = 0; profile.candidateWins = 0
        profiles[endpoint] = profile
        persist(profile, for: endpoint)
    }

    /// A review can propose one bounded heuristic, never a rule or action.
    /// Transport errors and malformed replies are non-fatal to the game.
    func review(_ endpoint: PlayerEndpoint, gameID: UUID, transport: any PlayerTurnTransport) async {
        var profile = profile(for: endpoint)
        guard profile.candidateGuidance == nil, !profile.reviewedGameIDs.contains(gameID) else { return }
        profile.reviewedGameIDs.insert(gameID)
        profiles[endpoint] = profile
        persist(profile, for: endpoint)
        let prompt = """
        You are reviewing your own completed standard Monopoly game. Suggest exactly one small, practical change to your strategic heuristic based on the evidence below. Do not alter or reinterpret Hasbro rules, invent privileges, or describe a specific game action. A loss alone does not prove a cause. Reply only with JSON: {"guidance":"one sentence of at most 200 characters"}.

        Current heuristic: \(profile.activeGuidance)
        \(context(for: endpoint))
        """
        guard let reply = try? await transport.respond(to: prompt),
              let data = ProtocolJSON.firstObjectData(from: reply),
              let proposed = try? JSONDecoder().decode(ProposedGuidance.self, from: data) else { return }
        let guidance = proposed.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guidance.isEmpty, guidance.count <= 200,
              !guidance.contains("\n"), guidance != profile.activeGuidance else { return }
        profile = self.profile(for: endpoint)
        guard profile.candidateGuidance == nil else { return }
        profile.candidateGuidance = guidance
        profile.baselineGames = 0; profile.baselineWins = 0
        profile.candidateGames = 0; profile.candidateWins = 0
        profiles[endpoint] = profile
        persist(profile, for: endpoint)
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
                recentEngineEvents: recentEvents(for: player, in: log),
                decisions: decisionEvents(for: player, in: log)
            )
            journal.gamesPlayed += 1
            if record.won { journal.wins += 1 }
            journal.recentGames.append(record)
            journal.recentGames = Array(journal.recentGames.suffix(Self.maximumGames))
            journals[player.endpoint] = journal
            persist(journal)
            var profile = profile(for: player.endpoint)
            if trialAssignments[player.endpoint] == true, profile.candidateGuidance != nil {
                profile.candidateGames += 1
                if record.won { profile.candidateWins += 1 }
            } else {
                profile.baselineGames += 1
                if record.won { profile.baselineWins += 1 }
            }
            profile.trialGameID = nil
            profile.trialUsesCandidate = nil
            if let startID = log.last?.id { profile.trialHistory?.removeValue(forKey: startID) }
            profiles[player.endpoint] = profile
            persist(profile, for: player.endpoint)
        }
    }

    private func journal(for endpoint: PlayerEndpoint) -> StrategyJournal {
        journals[endpoint] ?? StrategyJournal(endpoint: endpoint)
    }

    private func profile(for endpoint: PlayerEndpoint) -> StrategyProfile {
        profiles[endpoint] ?? StrategyProfile()
    }

    private func loadExistingProfiles() {
        for endpoint in PlayerEndpoint.allCases {
            guard let data = try? Data(contentsOf: profileURL(for: endpoint)),
                  let profile = try? JSONDecoder().decode(StrategyProfile.self, from: data) else { continue }
            profiles[endpoint] = profile
        }
    }

    private func persist(_ profile: StrategyProfile, for endpoint: PlayerEndpoint) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profile).write(to: profileURL(for: endpoint), options: .atomic)
        } catch { /* Learning is optional and never stops play. */ }
    }

    private func profileURL(for endpoint: PlayerEndpoint) -> URL {
        directoryURL.appendingPathComponent("\(endpoint.rawValue)-profile.json")
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
        let prefix = "\(GameLogEntry.displayText(for: player.name)) "
        let strategicMarkers = ["bought", "bid", "declined", "mortgaged", "unmortgaged"]
        var events: [String] = []
        for entry in log where entry.displayText.hasPrefix(prefix) && strategicMarkers.contains(where: entry.displayText.localizedCaseInsensitiveContains) {
            events.append(entry.displayText)
            if events.count == 4 { break }
        }
        return events
    }

    private func decisionEvents(for player: Player, in log: [GameLogEntry]) -> [StrategyDecisionEvent] {
        let markers = ["bought", "bid", "declined", "mortgaged", "unmortgaged", "built", "sold"]
        var events: [StrategyDecisionEvent] = []
        let prefix = "\(GameLogEntry.displayText(for: player.name)) "
        for entry in log where entry.displayText.hasPrefix(prefix) {
            guard let kind = markers.first(where: { entry.displayText.localizedCaseInsensitiveContains($0) }) else { continue }
            events.append(StrategyDecisionEvent(kind: kind, detail: entry.displayText))
            if events.count == 12 { break }
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
