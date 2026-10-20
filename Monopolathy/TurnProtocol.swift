import Foundation

/// Transports return model text, not trusted protocol frames. Accept the first
/// complete JSON object so an otherwise valid decision survives a Markdown
/// fence or a brief explanatory sentence.
enum ProtocolJSON {
    static func firstObjectData(from reply: String) -> Data? {
        let bytes = Array(reply.utf8)
        guard let start = bytes.firstIndex(of: 123) else { return nil } // {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<bytes.endIndex {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true } // \
                else if byte == 34 { inString = false } // "
                continue
            }
            if byte == 34 { inString = true; continue }
            if byte == 123 { depth += 1 }
            if byte == 125 {
                depth -= 1
                if depth == 0 { return Data(bytes[start...index]) }
            }
        }
        return nil
    }
}

struct TurnSnapshot: Codable, Equatable {
    struct PlayerState: Codable, Equatable, Identifiable {
        let id: UUID
        let name: String
        let cash: Int
        let position: Int
        let properties: [Int]
        let bankrupt: Bool
    }

    let currentPlayerID: UUID
    let currentPlayerName: String
    let phase: String
    let lastRoll: [Int]?
    let players: [PlayerState]
    let legalActions: [String]

    @MainActor init(engine: GameEngine) {
        currentPlayerID = engine.currentPlayer?.id ?? UUID()
        currentPlayerName = engine.currentPlayer?.name ?? ""
        phase = engine.phase.rawValue
        lastRoll = engine.lastRoll.map { [$0.0, $0.1] }
        players = engine.players.map { .init(id: $0.id, name: $0.name, cash: $0.cash, position: $0.position, properties: $0.properties.sorted(), bankrupt: $0.bankrupt) }
        legalActions = engine.legalActions.map(TurnProtocol.name(for:))
    }
}

private struct ProposedAction: Decodable { let action: String }

enum TurnProtocolError: LocalizedError, Equatable {
    case malformedReply
    case illegalAction(String)

    var errorDescription: String? {
        switch self {
        case .malformedReply: "The player response was not a JSON action object."
        case let .illegalAction(action): "The proposed action is not legal now: \(action)."
        }
    }
}

enum TurnProtocol {
    static func name(for action: GameAction) -> String {
        switch action {
        case .rollDice: "roll_dice"
        case .buyProperty: "buy_property"
        case .declineProperty: "decline_property"
        case .payJailFine: "pay_jail_fine"
        case .useGetOutOfJailFree: "use_get_out_of_jail_free"
        case .attemptJailRoll: "attempt_jail_roll"
        case .endTurn: "end_turn"
        }
    }

    static func prompt(for snapshot: TurnSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let state = String(data: (try? encoder.encode(snapshot)) ?? Data(), encoding: .utf8) ?? "{}"
        return """
        You are \(snapshot.currentPlayerName), playing a standard-rules Monopoly game. Decide strategy yourself, but never invent a game action.

        Table state JSON:
        \(state)

        Reply with exactly one JSON object and no Markdown or explanation:
        {"action":"one_of_the_legal_actions"}
        """
    }

    static func action(from reply: String, allowed: [GameAction]) throws -> GameAction {
        guard let data = ProtocolJSON.firstObjectData(from: reply),
              let proposal = try? JSONDecoder().decode(ProposedAction.self, from: data) else { throw TurnProtocolError.malformedReply }
        let named = Dictionary(uniqueKeysWithValues: allowed.map { (name(for: $0), $0) })
        guard let action = named[proposal.action] else { throw TurnProtocolError.illegalAction(proposal.action) }
        return action
    }
}

/// Implementations may call a selected Hermes backend or a connected ChatGPT
/// plan. They return text only; they never receive permission to alter game
/// state or invoke tools.
protocol PlayerTurnTransport: Sendable {
    func respond(to prompt: String) async throws -> String
}

enum TurnCoordinatorError: LocalizedError {
    case proposalRejected(TurnProtocolError)
    case engineRejected

    var errorDescription: String? {
        switch self {
        case let .proposalRejected(error): error.errorDescription
        case .engineRejected: "The engine rejected an otherwise parsed action."
        }
    }
}

@MainActor
final class TurnCoordinator {
    func playTurn(engine: GameEngine, transport: any PlayerTurnTransport) async throws -> GameAction {
        let snapshot = TurnSnapshot(engine: engine)
        let reply = try await transport.respond(to: TurnProtocol.prompt(for: snapshot))
        do {
            let action = try TurnProtocol.action(from: reply, allowed: engine.legalActions)
            guard engine.submit(action) else { throw TurnCoordinatorError.engineRejected }
            return action
        } catch let error as TurnProtocolError {
            throw TurnCoordinatorError.proposalRejected(error)
        }
    }
}

struct AuctionSnapshot: Codable, Equatable {
    let playerID: UUID
    let playerName: String
    let playerCash: Int
    let propertyName: String
    let currentBid: Int
    let leadingBidderName: String?
    let minimumBid: Int

    @MainActor init(engine: GameEngine, bidder: Player) {
        let auction = engine.auction!
        playerID = bidder.id
        playerName = bidder.name
        playerCash = bidder.cash
        propertyName = engine.board[auction.spaceID].name
        currentBid = auction.leadingBid
        leadingBidderName = auction.leadingBidderID.flatMap { id in engine.players.first(where: { $0.id == id })?.name }
        minimumBid = auction.leadingBid + 1
    }
}

enum AuctionDecision: Equatable {
    case bid(Int)
    case pass
}

private struct ProposedAuctionAction: Decodable {
    let action: String
    let amount: Int?
}

enum AuctionProtocolError: LocalizedError, Equatable {
    case malformedReply
    case illegalAction(String)

    var errorDescription: String? {
        switch self {
        case .malformedReply: "The auction response was not a valid JSON bid or pass object."
        case let .illegalAction(action): "The auction proposal is not legal now: \(action)."
        }
    }
}

enum AuctionProtocol {
    static func prompt(for snapshot: AuctionSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let state = String(data: (try? encoder.encode(snapshot)) ?? Data(), encoding: .utf8) ?? "{}"
        return """
        You are \(snapshot.playerName), participating in a standard-rules Monopoly auction. Decide strategy yourself. You may bid any whole-dollar amount from \(snapshot.minimumBid) through \(snapshot.playerCash), or pass permanently. Do not invent other actions.

        Make a decisive valuation-based choice. If you bid, choose the highest price you would genuinely be willing to pay for this property now; do not mechanically raise the current bid by $1 merely to extend the auction. Another player can outbid you and you will be asked again, so a bid should reflect your actual valuation. Pass if the property is not worth at least the minimum bid to you. Your answer does not set a sealed maximum or constrain later bids; it is only your current standard-rules bid.

        Auction state JSON:
        \(state)

        Reply with exactly one JSON object and no Markdown or explanation:
        {"action":"bid","amount":whole_dollar_amount}
        or
        {"action":"pass"}
        """
    }

    static func decision(from reply: String, minimumBid: Int, availableCash: Int) throws -> AuctionDecision {
        guard let data = ProtocolJSON.firstObjectData(from: reply),
              let proposal = try? JSONDecoder().decode(ProposedAuctionAction.self, from: data) else { throw AuctionProtocolError.malformedReply }
        switch proposal.action {
        case "pass": return .pass
        case "bid":
            guard let amount = proposal.amount, amount >= minimumBid, amount <= availableCash else { throw AuctionProtocolError.illegalAction("bid") }
            return .bid(amount)
        default: throw AuctionProtocolError.illegalAction(proposal.action)
        }
    }
}

enum AuctionCoordinatorError: LocalizedError {
    case proposalRejected(AuctionProtocolError)
    case engineRejected

    var errorDescription: String? {
        switch self {
        case let .proposalRejected(error): error.errorDescription
        case .engineRejected: "The engine rejected an otherwise parsed auction proposal."
        }
    }
}

@MainActor
final class AuctionCoordinator {
    func requestAuctionDecision(engine: GameEngine, bidder: Player, transport: any PlayerTurnTransport) async throws -> AuctionDecision {
        for attempt in 0..<3 {
            guard let auction = engine.auction else { throw AuctionCoordinatorError.engineRejected }
            let snapshot = AuctionSnapshot(engine: engine, bidder: bidder)
            let correction = attempt == 0 ? "" : "Your previous auction reply was invalid. Reply with pass or a bid within the stated range only.\n\n"
            let reply = try await transport.respond(to: correction + AuctionProtocol.prompt(for: snapshot))
            do {
                let decision = try AuctionProtocol.decision(from: reply, minimumBid: auction.leadingBid + 1, availableCash: bidder.cash)
                let applied: Bool
                switch decision {
                case let .bid(amount): applied = engine.placeAuctionBid(amount, by: bidder.id)
                case .pass: applied = engine.passAuction(by: bidder.id)
                }
                guard applied else { throw AuctionCoordinatorError.engineRejected }
                return decision
            } catch let error as AuctionProtocolError where attempt == 2 {
                guard engine.passAuction(by: bidder.id) else { throw AuctionCoordinatorError.proposalRejected(error) }
                return .pass
            } catch is AuctionProtocolError {
                continue
            }
        }
        throw AuctionCoordinatorError.engineRejected
    }
}

struct TradeSnapshot: Codable, Equatable {
    struct PlayerState: Codable, Equatable {
        let id: UUID
        let name: String
        let cash: Int
        let properties: [Int]
    }

    let proposerID: UUID
    let proposerName: String
    let players: [PlayerState]
    let propertyNames: [Int: String]

    @MainActor init(engine: GameEngine, proposer: Player) {
        proposerID = proposer.id
        proposerName = proposer.name
        players = engine.players.filter { !$0.bankrupt }.map { .init(id: $0.id, name: $0.name, cash: $0.cash, properties: $0.properties.sorted()) }
        propertyNames = Dictionary(uniqueKeysWithValues: engine.board.filter(\.isPurchasable).map { ($0.id, $0.name) })
    }
}

enum TradeNegotiation: Equatable {
    case noOffer
    case declined
    case completed
}

private struct ProposedTradeAction: Decodable {
    let action: String
    let toPlayerID: UUID?
    let giveCash: Int?
    let requestCash: Int?
    let giveProperties: [Int]?
    let requestProperties: [Int]?

    enum CodingKeys: String, CodingKey {
        case action
        case toPlayerID = "to_player_id"
        case giveCash = "give_cash"
        case requestCash = "request_cash"
        case giveProperties = "give_properties"
        case requestProperties = "request_properties"
    }
}

private struct ProposedTradeResponse: Decodable { let action: String }

enum TradeProtocolError: LocalizedError, Equatable {
    case malformedReply
    case illegalProposal(String)

    var errorDescription: String? {
        switch self {
        case .malformedReply: "The trade response was not a valid JSON object."
        case let .illegalProposal(reason): "The trade proposal is not legal: \(reason)."
        }
    }
}

enum TradeProtocol {
    static func proposalPrompt(for snapshot: TradeSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let state = String(data: (try? encoder.encode(snapshot)) ?? Data(), encoding: .utf8) ?? "{}"
        return """
        You are \(snapshot.proposerName), playing standard-rules Monopoly. If your cash is negative, this is your opportunity to raise funds before bankruptcy; otherwise, before your turn you may make exactly one voluntary trade offer, or make no offer. Strategy is entirely yours. The game will validate ownership, cash, unimproved properties, and mortgage-transfer costs.

        Table state JSON:
        \(state)

        Reply with exactly one JSON object and no Markdown or explanation:
        {"action":"no_trade"}
        or
        {"action":"propose_trade","to_player_id":"UUID from table state","give_cash":0,"request_cash":0,"give_properties":[property_ids],"request_properties":[property_ids]}
        """
    }

    @MainActor static func responsePrompt(for offer: TradeOffer, engine: GameEngine) -> String {
        let propertyNames = Dictionary(uniqueKeysWithValues: engine.board.filter(\.isPurchasable).map { ($0.id, $0.name) })
        let offered = offer.fromProperties.sorted().map { propertyNames[$0] ?? "#\($0)" }.joined(separator: ", ")
        let requested = offer.toProperties.sorted().map { propertyNames[$0] ?? "#\($0)" }.joined(separator: ", ")
        let proposer = engine.players.first(where: { $0.id == offer.fromPlayerID })?.name ?? "Opponent"
        return """
        You are considering a standard-rules Monopoly trade offered by \(proposer).
        You receive: $\(offer.fromCash), properties [\(offered)].
        You give: $\(offer.toCash), properties [\(requested)].
        Decide strategy yourself. The game validates the offer; you can only accept this exact offer or decline it.

        Reply with exactly one JSON object and no Markdown or explanation:
        {"action":"accept"}
        or
        {"action":"decline"}
        """
    }

    @MainActor static func offer(from reply: String, proposer: Player, engine: GameEngine) throws -> TradeOffer? {
        guard let data = ProtocolJSON.firstObjectData(from: reply),
              let proposal = try? JSONDecoder().decode(ProposedTradeAction.self, from: data) else { throw TradeProtocolError.malformedReply }
        guard proposal.action == "no_trade" || proposal.action == "propose_trade" else { throw TradeProtocolError.illegalProposal(proposal.action) }
        guard proposal.action == "propose_trade" else { return nil }
        guard let recipientID = proposal.toPlayerID, recipientID != proposer.id,
              let giveCash = proposal.giveCash, let requestCash = proposal.requestCash,
              let giveProperties = proposal.giveProperties, let requestProperties = proposal.requestProperties,
              giveCash >= 0, requestCash >= 0,
              Set(giveProperties).count == giveProperties.count, Set(requestProperties).count == requestProperties.count else {
            throw TradeProtocolError.illegalProposal("invalid trade fields")
        }
        let offer = TradeOffer(fromPlayerID: proposer.id, toPlayerID: recipientID, fromCash: giveCash, toCash: requestCash, fromProperties: Set(giveProperties), toProperties: Set(requestProperties))
        guard engine.canExecuteTrade(offer) else { throw TradeProtocolError.illegalProposal("engine validation failed") }
        return offer
    }

    static func accepted(from reply: String) throws -> Bool {
        guard let data = ProtocolJSON.firstObjectData(from: reply),
              let response = try? JSONDecoder().decode(ProposedTradeResponse.self, from: data) else { throw TradeProtocolError.malformedReply }
        switch response.action {
        case "accept": return true
        case "decline": return false
        default: throw TradeProtocolError.illegalProposal(response.action)
        }
    }
}

enum TradeCoordinatorError: LocalizedError {
    case proposalRejected(TradeProtocolError)
    case engineRejected

    var errorDescription: String? {
        switch self {
        case let .proposalRejected(error): error.errorDescription
        case .engineRejected: "The engine rejected an otherwise validated trade."
        }
    }
}

@MainActor
final class TradeCoordinator {
    func negotiate(engine: GameEngine, proposer: Player, proposerTransport: any PlayerTurnTransport, recipientTransport: (PlayerEndpoint) -> any PlayerTurnTransport) async throws -> TradeNegotiation {
        let reply = try await proposerTransport.respond(to: TradeProtocol.proposalPrompt(for: TradeSnapshot(engine: engine, proposer: proposer)))
        do {
            guard let offer = try TradeProtocol.offer(from: reply, proposer: proposer, engine: engine) else { return .noOffer }
            guard let recipient = engine.players.first(where: { $0.id == offer.toPlayerID }) else { throw TradeCoordinatorError.engineRejected }
            let recipientReply = try await recipientTransport(recipient.endpoint).respond(to: TradeProtocol.responsePrompt(for: offer, engine: engine))
            guard try TradeProtocol.accepted(from: recipientReply) else { return .declined }
            guard engine.executeTrade(offer) else { throw TradeCoordinatorError.engineRejected }
            return .completed
        } catch let error as TradeProtocolError {
            throw TradeCoordinatorError.proposalRejected(error)
        }
    }
}

struct AssetSnapshot: Codable, Equatable {
    let playerName: String
    let cash: Int
    let propertyNames: [Int: String]
    let ownedProperties: [Int]
    let mortgagedProperties: [Int]
    let buildings: [Int: Int]
    let buildableProperties: [Int]
    let sellableProperties: [Int]
    let mortgageableProperties: [Int]
    let unmortgageableProperties: [Int]
    let availableHouses: Int
    let availableHotels: Int

    @MainActor init(engine: GameEngine, player: Player) {
        playerName = player.name
        cash = player.cash
        propertyNames = Dictionary(uniqueKeysWithValues: engine.board.filter(\.isPurchasable).map { ($0.id, $0.name) })
        ownedProperties = player.properties.sorted()
        mortgagedProperties = player.properties.filter(engine.mortgagedSpaceIDs.contains).sorted()
        buildings = Dictionary(uniqueKeysWithValues: player.properties.map { ($0, engine.buildingsBySpaceID[$0, default: 0]) })
        buildableProperties = player.properties.filter { engine.canBuild(on: $0, by: player.id) }.sorted()
        sellableProperties = player.properties.filter { engine.canSellBuilding(on: $0, by: player.id) }.sorted()
        mortgageableProperties = player.properties.filter { engine.canMortgage(spaceID: $0, by: player.id) }.sorted()
        unmortgageableProperties = player.properties.filter { engine.mortgagedSpaceIDs.contains($0) }.sorted()
        availableHouses = engine.availableHouses
        availableHotels = engine.availableHotels
    }

    var hasOptionalActions: Bool {
        !buildableProperties.isEmpty || !sellableProperties.isEmpty ||
            !mortgageableProperties.isEmpty || !unmortgageableProperties.isEmpty
    }
}

enum OptionalDecisionPolicy {
    @MainActor
    static func hasTradeOpportunity(for proposer: Player, in engine: GameEngine) -> Bool {
        guard !proposer.bankrupt else { return false }
        let proposerHasCash = proposer.cash > 0
        let proposerHasProperties = !proposer.properties.isEmpty
        guard proposerHasCash || proposerHasProperties else { return false }

        return engine.players.contains { counterparty in
            guard counterparty.id != proposer.id, !counterparty.bankrupt else { return false }
            let counterpartyHasCash = counterparty.cash > 0
            let counterpartyHasProperties = !counterparty.properties.isEmpty
            return (proposerHasCash && counterpartyHasProperties) ||
                (proposerHasProperties && (counterpartyHasCash || counterpartyHasProperties))
        }
    }

    static func shouldContinueAfterOptionalFailure(_ error: Error) -> Bool {
        (error as? URLError)?.code == .timedOut
    }

    /// A voluntary trade is not required to advance the turn.  Keep a bad
    /// model proposal from freezing the table, while preserving a real engine
    /// failure as a visible stop condition.
    static func shouldContinueAfterOptionalTradeFailure(_ error: Error) -> Bool {
        if shouldContinueAfterOptionalFailure(error) { return true }
        guard let error = error as? TradeCoordinatorError else { return false }
        if case .proposalRejected = error { return true }
        return false
    }

    /// An insolvent player may still mortgage or sell buildings after an
    /// unusable rescue-trade proposal. Do not turn a bad model reply into a
    /// table-wide stop or an immediate bankruptcy.
    static func shouldContinueAfterDebtSettlementTradeFailure(_ error: Error) -> Bool {
        shouldContinueAfterOptionalTradeFailure(error)
    }

    static func shouldContinueAfterOptionalAssetFailure(_ error: Error) -> Bool {
        shouldContinueAfterOptionalFailure(error) || error is AssetProtocolError
    }
}

enum AssetDecision: Equatable { case done, mortgage(Int), unmortgage(Int), build(Int), sellBuilding(Int) }
private struct ProposedAssetAction: Decodable { let action: String; let propertyID: Int?; enum CodingKeys: String, CodingKey { case action; case propertyID = "property_id" } }

enum AssetProtocolError: LocalizedError, Equatable {
    case malformedReply, illegalAction(String)
    var errorDescription: String? { switch self { case .malformedReply: "The asset-management response was not valid JSON."; case let .illegalAction(action): "The asset-management action is not legal: \(action)." } }
}

enum AssetProtocol {
    static func prompt(for snapshot: AssetSnapshot, correctingMalformedReply: Bool = false) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let state = String(data: (try? encoder.encode(snapshot)) ?? Data(), encoding: .utf8) ?? "{}"
        let instruction = snapshot.cash < 0
            ? "You owe money. Sell buildings or mortgage legal property until you can pay; reply done only to declare bankruptcy or after restoring a non-negative balance."
            : "Before rolling, you may make one legal asset-management action or finish."
        let correction = correctingMalformedReply ? "Your prior reply was not usable. Reply with one JSON object only—no Markdown or explanation." : ""
        return """
        You are \(snapshot.playerName), playing standard-rules Monopoly. \(instruction) \(correction) Strategy is entirely yours; the game validates everything.

        Asset state JSON:
        \(state)

        Reply with exactly one JSON object and no Markdown or explanation:
        {"action":"done"}
        {"action":"mortgage","property_id":id}
        {"action":"unmortgage","property_id":id}
        {"action":"build","property_id":id}
        {"action":"sell_building","property_id":id}
        """
    }

    static func decision(from reply: String) throws -> AssetDecision {
        guard let data = ProtocolJSON.firstObjectData(from: reply),
              let proposal = try? JSONDecoder().decode(ProposedAssetAction.self, from: data) else { throw AssetProtocolError.malformedReply }
        switch proposal.action {
        case "done": return .done
        case "mortgage", "unmortgage", "build", "sell_building":
            guard let id = proposal.propertyID else { throw AssetProtocolError.illegalAction(proposal.action) }
            switch proposal.action { case "mortgage": return .mortgage(id); case "unmortgage": return .unmortgage(id); case "build": return .build(id); default: return .sellBuilding(id) }
        default: throw AssetProtocolError.illegalAction(proposal.action)
        }
    }
}

@MainActor
final class AssetCoordinator {
    func requestDecision(engine: GameEngine, player: Player, transport: any PlayerTurnTransport) async throws -> AssetDecision {
        for attempt in 0..<3 {
            do {
                let reply = try await transport.respond(to: AssetProtocol.prompt(for: AssetSnapshot(engine: engine, player: player), correctingMalformedReply: attempt > 0))
                let decision = try AssetProtocol.decision(from: reply)
                let applied: Bool
                switch decision {
                case .done: return .done
                case let .mortgage(id): applied = engine.mortgage(spaceID: id, by: player.id)
                case let .unmortgage(id): applied = engine.unmortgage(spaceID: id, by: player.id)
                case let .build(id): applied = engine.buyBuilding(on: id, by: player.id)
                case let .sellBuilding(id): applied = engine.sellBuilding(on: id, by: player.id)
                }
                guard applied else { throw AssetProtocolError.illegalAction("engine validation failed") }
                return decision
            } catch let error as AssetProtocolError {
                if attempt == 2 { throw error }
            }
        }
        throw AssetProtocolError.malformedReply
    }
}

enum HermesTurnTransportError: LocalizedError {
    case profileUnavailable
    case invalidResponse

    var errorDescription: String? { self == .profileUnavailable ? "The selected Hermes profile is unavailable." : "The Hermes model returned no usable response." }
}

/// A deliberately narrow adapter for Triopathy-compatible Hermes profiles.
/// It sends exactly one prompt to the selected model endpoint; it does not run
/// Hermes tools, sessions, memory, or terminal workflows.
struct HermesTurnTransport: PlayerTurnTransport {
    let endpoint: PlayerEndpoint
    let strategyContext: String

    init(endpoint: PlayerEndpoint, strategyContext: String = "") {
        self.endpoint = endpoint
        self.strategyContext = strategyContext
    }

    func respond(to prompt: String) async throws -> String {
        guard let profile = endpoint.hermesProfileName,
              let text = try? String(contentsOf: URL(fileURLWithPath: NSString(string: "~/.hermes/profiles/\(profile)/config.yaml").expandingTildeInPath)),
              let backend = Self.selectedBackend(in: text) else { throw HermesTurnTransportError.profileUnavailable }
        var url = backend.api
        url.appendPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(
            model: backend.model,
            messages: [.init(role: "user", content: decoratedPrompt(prompt))],
            maxTokens: 128,
            temperature: 0,
            chatTemplateKwargs: ["enable_thinking": false]
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let reply = try? JSONDecoder().decode(Response.self, from: data).choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { throw HermesTurnTransportError.invalidResponse }
        return reply
    }

    func decoratedPrompt(_ prompt: String) -> String {
        guard !strategyContext.isEmpty else { return prompt }
        return "\(strategyContext)\n\nCurrent decision:\n\(prompt)"
    }

    private static func selectedBackend(in text: String) -> (api: URL, model: String)? {
        let lines = text.components(separatedBy: .newlines)
        var provider: String?; var model: String?; var inModel = false
        for line in lines { if line == "model:" { inModel = true; continue }; if inModel && !line.hasPrefix(" ") { break }; if inModel { let t = line.trimmingCharacters(in: .whitespaces); if t.hasPrefix("provider:") { provider = value(t) }; if t.hasPrefix("default:") { model = value(t) } } }
        guard let provider, let model else { return nil }
        var api: String?; var inside = false
        for line in lines { if line == "  \(provider):" { inside = true; continue }; if inside && line.hasPrefix("  ") && !line.hasPrefix("    ") { break }; if inside && line.trimmingCharacters(in: .whitespaces).hasPrefix("api:") { api = value(line.trimmingCharacters(in: .whitespaces)) } }
        guard let api, let url = URL(string: api) else { return nil }
        return (url, model)
    }
    private static func value(_ text: String) -> String { text.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces) }
    struct Request: Encodable {
        struct Message: Encodable { let role: String; let content: String }

        let model: String
        let messages: [Message]
        let maxTokens: Int
        let temperature: Double
        let chatTemplateKwargs: [String: Bool]

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
            case chatTemplateKwargs = "chat_template_kwargs"
        }
    }
    private struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }; let choices: [Choice] }
}
