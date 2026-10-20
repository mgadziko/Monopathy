import SwiftUI

struct ContentView: View {
    @ObservedObject var game: GameEngine
    @EnvironmentObject private var session: GameSession
    @State private var slots = [
        PlayerSlot(id: 0, endpoint: nil, token: "Car"),
        PlayerSlot(id: 1, endpoint: nil, token: "Hat"),
        PlayerSlot(id: 2, endpoint: nil, token: "Dog"),
        PlayerSlot(id: 3, endpoint: nil, token: "Ship")
    ]
    @State private var availability = Dictionary(uniqueKeysWithValues: PlayerEndpoint.allCases.map { ($0, PlayerAvailability.checking) })
    @State private var isAskingPlayer = false
    @State private var isAutoPlaying = false
    @State private var tradeWindowPlayerID: UUID?
    @State private var assetWindowPlayerID: UUID?
    @State private var playerTurnStatus: String?
    @State private var selectedSpaceID: Int?

    private var activeEndpoints: [PlayerEndpoint] {
        PlayerEndpoint.allCases.filter { availability[$0]?.isAvailable == true }
    }

    private var canStart: Bool {
        let choices = slots.compactMap(\.endpoint)
        return choices.count == 4 && Set(choices).count == 4 && choices.allSatisfy { availability[$0]?.isAvailable == true }
    }

    var body: some View {
        Group {
            if game.players.isEmpty { lobby } else { table }
        }
        .task { await refreshPlayers() }
        .onAppear { session.pauseAutomaticPlay = { isAutoPlaying = false } }
        .onChange(of: game.phase) { phase in
            if phase == .gameOver { session.strategyJournal.recordCompletedGame(game) }
        }
    }

    private var lobby: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Monopathy").font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("A standard-rules Monopoly table for four LAN decision-makers.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await refreshPlayers() } } label: { Label("Refresh Players", systemImage: "arrow.clockwise") }
            }

            GroupBox("Players") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        Text("Seat").foregroundStyle(.secondary)
                        Text("Connected player").foregroundStyle(.secondary)
                        Text("Token").foregroundStyle(.secondary)
                    }
                    ForEach($slots) { $slot in
                        GridRow {
                            Text("Player \(slot.id + 1)").fontWeight(.medium)
                            Picker("Player \(slot.id + 1)", selection: $slot.endpoint) {
                                Text("Choose active player").tag(PlayerEndpoint?.none)
                                ForEach(activeEndpoints) { endpoint in
                                    Text(endpoint.displayName).tag(PlayerEndpoint?.some(endpoint))
                                }
                            }
                            .labelsHidden().frame(width: 260)
                            Text(slot.token).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Availability") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(PlayerEndpoint.allCases) { endpoint in
                        HStack {
                            Image(systemName: availability[endpoint]?.isAvailable == true ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(availability[endpoint]?.isAvailable == true ? .green : .secondary)
                            Text(endpoint.displayName).frame(width: 190, alignment: .leading)
                            Text(availability[endpoint]?.label ?? "Not checked").foregroundStyle(.secondary)
                        }
                    }
                }.padding(8)
            }

            HStack {
                Text("Only live, configured player services appear in the four menus. The game will validate every proposed move.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    game.start(endpoints: slots.compactMap(\.endpoint))
                    tradeWindowPlayerID = nil
                    assetWindowPlayerID = nil
                    beginAutomaticPlay()
                } label: { Label("Start Game", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(!canStart)
            }
        }
        .padding(36).frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Monopathy").font(.largeTitle.bold())
                    Text("Current player: \(game.currentPlayer.map(shortName) ?? "—") • \(game.phase.rawValue)").foregroundStyle(.secondary)
                }
                Spacer()
                if let roll = game.lastRoll { Text("Last roll: \(roll.0) + \(roll.1)").monospacedDigit() }
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Players").font(.headline)
                    ForEach(game.players) { player in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(player.token).foregroundStyle(tokenColor(for: player.id))
                                    Text("\(shortName(player)): $\(player.cash)")
                                }
                                Text(game.board[player.position].name)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            ownershipDots(for: player)
                        }
                    }
                }.frame(width: 230, alignment: .leading)
                board
                    .frame(minWidth: 560, maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Table log").font(.headline)
                    ScrollView { LazyVStack(alignment: .leading, spacing: 6) { ForEach(game.log) { Text($0.text).font(.callout) } } }
                        .frame(minHeight: 400)
                }.frame(width: 300, alignment: .leading)
            }
            if let playerTurnStatus {
                Text(playerTurnStatus).foregroundStyle(.secondary)
            }
            HStack {
                ForEach(game.legalActions, id: \.self) { action in
                    Button(actionTitle(action)) { game.submit(action) }.buttonStyle(.borderedProminent)
                }
                Spacer()
                Button {
                    Task { _ = await askCurrentPlayer() }
                } label: {
                    Label(isAskingPlayer ? "Waiting for Player…" : "Ask Current Player", systemImage: "person.crop.circle.badge.play")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAskingPlayer || isAutoPlaying || game.phase == .auction || game.phase == .trading || game.phase == .gameOver)
                Button {
                    if isAutoPlaying { isAutoPlaying = false } else { beginAutomaticPlay() }
                } label: {
                    Label(isAutoPlaying ? "Stop Automatic Play" : "Resume Automatic Play", systemImage: isAutoPlaying ? "stop.fill" : "play.fill")
                }
                .disabled(isAskingPlayer || game.phase == .trading || game.phase == .gameOver)
                Button("New Game") {
                    isAutoPlaying = false
                    tradeWindowPlayerID = nil
                    assetWindowPlayerID = nil
                    game.returnToLobby()
                }
            }
        }.padding(28)
    }

    private var board: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(0..<11, id: \.self) { row in
                GridRow {
                    ForEach(0..<11, id: \.self) { column in
                        if let spaceID = boardSpaceID(row: row, column: column) {
                            boardSpace(spaceID)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(4)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.35)))
        .overlay(boardDashboard.padding(24))
    }

    private var boardDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MONOPATHY").font(.system(size: 21, weight: .bold, design: .rounded))
            Text("\(game.phase.rawValue) • \(game.currentPlayer.map(shortName) ?? "—")")
                .font(.callout).foregroundStyle(.secondary)
            Text("Bank: \(game.availableHouses) houses • \(game.availableHotels) hotels")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(game.players) { player in
                HStack(spacing: 6) {
                    Circle().fill(tokenColor(for: player.id)).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shortName(player)).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("$\(player.cash) • \(game.board[player.position].name)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .opacity(player.bankrupt ? 0.45 : 1)
            }
            if let roll = game.lastRoll {
                Divider()
                Text("Last roll  \(roll.0) + \(roll.1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let selectedSpaceID {
                let space = game.board[selectedSpaceID]
                Divider()
                Text(space.name).font(.callout.weight(.semibold))
                Text(spaceDetail(for: selectedSpaceID))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: 245, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.35)))
    }

    private func ownershipDots(for player: Player) -> some View {
        let groups = ownershipDotGroups(for: player)
        return HStack(alignment: .top, spacing: 2) {
            ForEach(groups.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    ForEach(groups[index], id: \.self) { spaceID in
                        Circle().fill(boardColor(for: spaceID)).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 0.5))
                    }
                }
            }
        }
        .frame(minWidth: 30, alignment: .trailing)
    }

    private func ownershipDotGroups(for player: Player) -> [[Int]] {
        let grouped = Dictionary(grouping: player.properties.sorted(), by: ownershipDotGroup)
        return grouped.values.sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }
    }

    private func ownershipDotGroup(for spaceID: Int) -> String {
        switch spaceID {
        case 1, 3: return "purple"
        case 6, 8, 9: return "cyan"
        case 11, 13, 14: return "pink"
        case 16, 18, 19: return "orange"
        case 21, 23, 24: return "red"
        case 26, 27, 29: return "yellow"
        case 31, 32, 34: return "green"
        case 37, 39: return "blue"
        case 5, 15, 25, 35: return "railroad"
        case 12, 28: return "water"
        default: return "other"
        }
    }

    private func shortName(_ player: Player) -> String {
        player.name.replacingOccurrences(of: "hermes-", with: "")
    }

    @ViewBuilder private func boardSpace(_ spaceID: Int) -> some View {
        let space = game.board[spaceID]
        ZStack(alignment: .top) {
            Rectangle().fill(boardColor(for: spaceID).opacity(0.18))
            VStack(spacing: 2) {
                Rectangle().fill(boardColor(for: spaceID)).frame(height: 5)
                Text(space.name).font(.system(size: 12, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center).padding(.horizontal, 2)
                if let owner = game.ownerBySpaceID[spaceID] {
                    HStack(spacing: 2) {
                        Circle().fill(tokenColor(for: owner.id)).frame(width: 6, height: 6)
                        if game.mortgagedSpaceIDs.contains(spaceID) {
                            Text("M").font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
                        } else if let buildings = game.buildingsBySpaceID[spaceID], buildings > 0 {
                            Text(buildings == 5 ? "H" : String(buildings)).font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    ForEach(game.players.filter { !$0.bankrupt && $0.position == spaceID }) { player in
                        Circle().fill(tokenColor(for: player.id)).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(.white, lineWidth: 0.8))
                    }
                }.padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Rectangle().stroke(.secondary.opacity(0.3), lineWidth: 0.5))
        .onTapGesture { selectedSpaceID = spaceID }
    }

    private func spaceDetail(for spaceID: Int) -> String {
        let space = game.board[spaceID]
        guard space.isPurchasable else { return space.kind.rawValue }
        var details = ["Price $\(space.price)"]
        if let owner = game.ownerBySpaceID[spaceID] { details.append("Owner \(owner.name)") }
        else { details.append("Unowned") }
        if game.mortgagedSpaceIDs.contains(spaceID) { details.append("Mortgaged") }
        let buildings = game.buildingsBySpaceID[spaceID, default: 0]
        if buildings > 0 { details.append(buildings == 5 ? "Hotel" : "\(buildings) house\(buildings == 1 ? "" : "s")") }
        return details.joined(separator: " • ")
    }

    private func boardSpaceID(row: Int, column: Int) -> Int? {
        if row == 10 { return 10 - column }
        if column == 0, row < 10 { return 20 - row }
        if row == 0, column > 0 { return 20 + column }
        if column == 10, row > 0, row < 10 { return 30 + row }
        return nil
    }

    private func boardColor(for spaceID: Int) -> Color {
        switch spaceID {
        case 1, 3: .purple
        case 6, 8, 9: .cyan
        case 11, 13, 14: .pink
        case 16, 18, 19: .orange
        case 21, 23, 24: .red
        case 26, 27, 29: .yellow
        case 31, 32, 34: .green
        case 37, 39: .blue
        case 5, 15, 25, 35: .black
        case 12, 28: .brown
        default: .gray
        }
    }

    private func tokenColor(for playerID: UUID) -> Color {
        let index = game.players.firstIndex(where: { $0.id == playerID }) ?? 0
        return [.red, .blue, .green, .orange][index % 4]
    }

    private func actionTitle(_ action: GameAction) -> String {
        switch action {
        case .rollDice: "Roll Dice"; case .buyProperty: "Buy"; case .declineProperty: "Decline"; case .payJailFine: "Pay $50"; case .useGetOutOfJailFree: "Use Card"; case .attemptJailRoll: "Roll for Doubles"; case .endTurn: "End Turn"
        }
    }

    @MainActor private func refreshPlayers() async {
        for endpoint in PlayerEndpoint.allCases { availability[endpoint] = .checking }
        await withTaskGroup(of: (PlayerEndpoint, PlayerAvailability).self) { group in
            for endpoint in PlayerEndpoint.allCases { group.addTask { (endpoint, await EndpointProbe.check(endpoint)) } }
            for await (endpoint, result) in group { availability[endpoint] = result }
        }
    }

    @MainActor private func askCurrentPlayer() async -> Bool {
        guard let player = game.currentPlayer else { return false }
        guard player.endpoint.hermesProfileName != nil else {
            playerTurnStatus = "ChatGPT connection is not configured yet."
            return false
        }
        isAskingPlayer = true
        playerTurnStatus = "Waiting for \(player.name)'s legal move…"
        defer { isAskingPlayer = false }
        do {
            let action = try await TurnCoordinator().playTurn(engine: game, transport: strategyTransport(for: player.endpoint))
            playerTurnStatus = "\(player.name) chose \(actionTitle(action))."
            return true
        } catch {
            playerTurnStatus = error.localizedDescription
            return false
        }
    }

    @MainActor private func beginAutomaticPlay() {
        guard !isAutoPlaying, game.phase != .trading, game.phase != .gameOver else { return }
        isAutoPlaying = true
        Task { await playAutomatically() }
    }

    /// Every model still receives only one validated decision at a time. There
    /// is intentionally no delay: a player may immediately take a further
    /// roll after doubles, as standard Monopoly permits.
    @MainActor private func playAutomatically() async {
        defer { isAutoPlaying = false }
        var decisions = 0
        while isAutoPlaying, !Task.isCancelled, decisions < 10_000 {
            if game.phase == .auction {
                guard await askNextAuctionBidder() else { break }
            } else if game.playerNeedingDebtResolution != nil {
                guard await settleOutstandingDebt() else { break }
            } else {
                guard game.phase != .trading, game.phase != .gameOver else { break }
                guard await manageAssetsIfNeeded() else { break }
                guard await negotiateTradeIfNeeded() else { break }
                guard await askCurrentPlayer() else { break }
            }
            decisions += 1
        }
        if game.phase == .trading {
            playerTurnStatus = "Automatic play paused for a trade."
        } else if decisions == 10_000 {
            playerTurnStatus = "Automatic play stopped after 10,000 decisions."
        }
    }

    @MainActor private func askNextAuctionBidder() async -> Bool {
        guard let auction = game.auction else { return false }
        guard let bidder = game.players.first(where: {
            !$0.bankrupt && $0.id != auction.excludedPlayerID && $0.id != auction.leadingBidderID && !auction.passedPlayerIDs.contains($0.id)
        }) else {
            playerTurnStatus = "Auction could not find an eligible bidder."
            return false
        }
        guard bidder.endpoint.hermesProfileName != nil else {
            playerTurnStatus = "ChatGPT connection is not configured yet."
            return false
        }
        isAskingPlayer = true
        playerTurnStatus = "Waiting for \(bidder.name)'s auction decision…"
        defer { isAskingPlayer = false }
        do {
            let decision = try await AuctionCoordinator().requestAuctionDecision(engine: game, bidder: bidder, transport: strategyTransport(for: bidder.endpoint))
            switch decision {
            case let .bid(amount): playerTurnStatus = "\(bidder.name) bid $\(amount)."
            case .pass: playerTurnStatus = "\(bidder.name) passed."
            }
            return true
        } catch {
            playerTurnStatus = error.localizedDescription
            return false
        }
    }

    @MainActor private func negotiateTradeIfNeeded() async -> Bool {
        guard let proposer = game.currentPlayer else { return false }
        guard tradeWindowPlayerID != proposer.id else { return true }
        tradeWindowPlayerID = proposer.id
        guard OptionalDecisionPolicy.hasTradeOpportunity(for: proposer, in: game) else { return true }
        guard proposer.endpoint.hermesProfileName != nil else {
            playerTurnStatus = "ChatGPT connection is not configured yet."
            return false
        }
        isAskingPlayer = true
        playerTurnStatus = "Waiting for \(proposer.name)'s trade decision…"
        defer { isAskingPlayer = false }
        do {
            let result = try await TradeCoordinator().negotiate(
                engine: game,
                proposer: proposer,
                proposerTransport: strategyTransport(for: proposer.endpoint),
                recipientTransport: { strategyTransport(for: $0) }
            )
            switch result {
            case .noOffer: playerTurnStatus = "\(proposer.name) made no trade offer."
            case .declined: playerTurnStatus = "\(proposer.name)'s trade offer was declined."
            case .completed: playerTurnStatus = "\(proposer.name)'s trade was completed."
            }
            return true
        } catch {
            if OptionalDecisionPolicy.shouldContinueAfterOptionalTradeFailure(error) {
                let outcome = OptionalDecisionPolicy.shouldContinueAfterOptionalFailure(error) ? "timed out" : "was rejected"
                playerTurnStatus = "\(proposer.name)'s optional trade proposal \(outcome); continuing play."
                return true
            }
            playerTurnStatus = error.localizedDescription
            return false
        }
    }

    @MainActor private func manageAssetsIfNeeded() async -> Bool {
        guard let player = game.currentPlayer else { return false }
        guard assetWindowPlayerID != player.id else { return true }
        assetWindowPlayerID = player.id
        guard player.endpoint.hermesProfileName != nil else { playerTurnStatus = "ChatGPT connection is not configured yet."; return false }
        var seenAssetStates = Set<String>()
        for _ in 0..<40 {
            guard let currentPlayer = game.currentPlayer else { return false }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let snapshot = AssetSnapshot(engine: game, player: currentPlayer)
            guard snapshot.hasOptionalActions else { return true }
            let state = String(data: (try? encoder.encode(snapshot)) ?? Data(), encoding: .utf8) ?? ""
            guard seenAssetStates.insert(state).inserted else {
                playerTurnStatus = "\(player.name) repeated an optional asset state; continuing play."
                return true
            }
            isAskingPlayer = true
            playerTurnStatus = "Waiting for \(player.name)'s asset decision…"
            defer { isAskingPlayer = false }
            do {
                let decision = try await AssetCoordinator().requestDecision(engine: game, player: currentPlayer, transport: strategyTransport(for: currentPlayer.endpoint))
                if decision == .done { return true }
            } catch {
                if OptionalDecisionPolicy.shouldContinueAfterOptionalAssetFailure(error) {
                    let outcome = OptionalDecisionPolicy.shouldContinueAfterOptionalFailure(error) ? "timed out" : "was rejected"
                    playerTurnStatus = "\(player.name)'s optional asset decision \(outcome); continuing play."
                    return true
                }
                playerTurnStatus = error.localizedDescription
                return false
            }
        }
        playerTurnStatus = "Optional asset-management limit reached for \(player.name); continuing play."
        return true
    }

    @MainActor private func settleOutstandingDebt() async -> Bool {
        guard let player = game.playerNeedingDebtResolution else { return false }
        guard player.endpoint.hermesProfileName != nil else {
            playerTurnStatus = "ChatGPT connection is not configured yet."
            return false
        }
        isAskingPlayer = true
        playerTurnStatus = "Waiting for \(player.name)'s debt-settlement trade…"
        do {
            _ = try await TradeCoordinator().negotiate(
                engine: game,
                proposer: player,
                proposerTransport: strategyTransport(for: player.endpoint),
                recipientTransport: { strategyTransport(for: $0) }
            )
            if game.playerNeedingDebtResolution?.cash ?? 0 >= 0 {
                isAskingPlayer = false
                return game.resolveOutstandingDebt(by: player.id)
            }
        } catch {
            isAskingPlayer = false
            guard OptionalDecisionPolicy.shouldContinueAfterDebtSettlementTradeFailure(error) else {
                playerTurnStatus = error.localizedDescription
                return false
            }
            let outcome = OptionalDecisionPolicy.shouldContinueAfterOptionalFailure(error) ? "timed out" : "was rejected"
            playerTurnStatus = "\(player.name)'s debt-settlement trade proposal \(outcome); continuing to liquidation."
        }
        isAskingPlayer = false
        if game.declareBankruptcyIfNoLiquidationOptions(by: player.id) {
            playerTurnStatus = "\(player.name) has no assets left to liquidate and is bankrupt."
            return true
        }
        for _ in 0..<40 {
            isAskingPlayer = true
            playerTurnStatus = "Waiting for \(player.name) to settle debt…"
            defer { isAskingPlayer = false }
            do {
                let decision = try await AssetCoordinator().requestDecision(engine: game, player: player, transport: strategyTransport(for: player.endpoint))
                if decision == .done {
                    return game.resolveOutstandingDebt(by: player.id)
                }
            } catch {
                playerTurnStatus = error.localizedDescription
                return false
            }
        }
        playerTurnStatus = "Debt-settlement limit reached for \(player.name)."
        return false
    }

    private func strategyTransport(for endpoint: PlayerEndpoint) -> HermesTurnTransport {
        HermesTurnTransport(endpoint: endpoint, strategyContext: session.strategyJournal.context(for: endpoint))
    }
}

enum EndpointProbe {
    static func check(_ endpoint: PlayerEndpoint) async -> PlayerAvailability {
        guard let profile = endpoint.hermesProfileName else { return .unavailable(reason: "ChatGPT connection not configured") }
        let config = URL(fileURLWithPath: NSString(string: "~/.hermes/profiles/\(profile)/config.yaml").expandingTildeInPath)
        guard let text = try? String(contentsOf: config), let backend = selectedBackend(in: text) else { return .unavailable(reason: "Profile not configured") }
        var modelsURL = backend.api
        modelsURL.appendPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return .unavailable(reason: "Model service unavailable") }
            let models = try JSONDecoder().decode(ModelList.self, from: data)
            guard models.data.contains(where: { modelMatches($0, configuredModel: backend.model) }) else {
                return .unavailable(reason: "Expected model not loaded")
            }
            return .available(detail: "Model ready")
        } catch { return .unavailable(reason: "Model service not reachable") }
    }

    /// llama.cpp may publish a loaded GGUF under its absolute file path rather
    /// than the shorter alias configured in Hermes. Compare canonical complete
    /// identifiers only; this never affects action or rules validation.
    static func modelMatches(_ serverModel: ModelList.Model, configuredModel: String) -> Bool {
        let configured = canonicalModelIdentifier(configuredModel)
        guard !configured.isEmpty else { return false }
        return ([serverModel.id] + (serverModel.aliases ?? [])).contains {
            canonicalModelIdentifier($0) == configured
        }
    }

    private static func canonicalModelIdentifier(_ identifier: String) -> String {
        let filename = URL(fileURLWithPath: identifier).lastPathComponent
        let basename = filename.lowercased().hasSuffix(".gguf")
            ? String(filename.dropLast(5))
            : filename
        return basename.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    private static func selectedBackend(in text: String) -> (api: URL, model: String)? {
        let lines = text.components(separatedBy: .newlines)
        var selectedProvider: String?
        var defaultModel: String?
        var inModel = false
        for line in lines {
            if line == "model:" { inModel = true; continue }
            if inModel && !line.hasPrefix(" ") { break }
            guard inModel else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("provider:") { selectedProvider = value(after: ":", in: trimmed) }
            if trimmed.hasPrefix("default:") { defaultModel = value(after: ":", in: trimmed) }
        }
        guard let selectedProvider, let defaultModel else { return nil }
        let header = "  \(selectedProvider):"
        var inProvider = false
        var api: String?
        for line in lines {
            if line == header { inProvider = true; continue }
            if inProvider && line.hasPrefix("  ") && !line.hasPrefix("    ") { break }
            guard inProvider else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("api:") { api = value(after: ":", in: trimmed) }
        }
        guard let api, let url = URL(string: api) else { return nil }
        return (url, defaultModel)
    }

    private static func value(after separator: Character, in text: String) -> String {
        text.split(separator: separator, maxSplits: 1).dropFirst().joined(separator: String(separator)).trimmingCharacters(in: .whitespaces)
    }

    struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
            let aliases: [String]?
        }

        let data: [Model]
    }
}
