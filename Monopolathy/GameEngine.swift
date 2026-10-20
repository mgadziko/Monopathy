import Foundation

struct GameSave: Codable, Equatable {
    let formatVersion: Int
    let players: [Player]
    let currentPlayerIndex: Int
    let phase: TurnPhase
    let pendingAction: PendingAction
    let lastRoll: [Int]?
    let doublesThisTurn: Int
    let buildingsBySpaceID: [Int: Int]
    let mortgagedSpaceIDs: Set<Int>
    let auction: AuctionState?
    let chanceCards: [MonopolyCard]
    let communityChestCards: [MonopolyCard]
    let bankruptcyAuctionQueue: [Int]
    let debtPlayerID: UUID?
    let debtCreditorID: UUID?
    let debtContinuation: String
    let pendingExtraRoll: Bool
    let log: [GameLogEntry]
}

/// The authority for the table. Player endpoints submit one action; this
/// engine alone decides whether that action is legal and applies it.
@MainActor
final class GameEngine: ObservableObject {
    @Published private(set) var board = BoardSpace.standardBoard
    @Published private(set) var players: [Player] = []
    @Published private(set) var currentPlayerIndex = 0
    @Published private(set) var phase: TurnPhase = .awaitingRoll
    @Published private(set) var pendingAction: PendingAction = .none
    @Published private(set) var lastRoll: (Int, Int)?
    @Published private(set) var log: [GameLogEntry] = []
    @Published private(set) var doublesThisTurn = 0
    @Published private(set) var buildingsBySpaceID: [Int: Int] = [:]
    @Published private(set) var mortgagedSpaceIDs: Set<Int> = []
    @Published private(set) var auction: AuctionState?

    var winnerID: UUID? {
        guard case let .gameOver(winner) = pendingAction else { return nil }
        return winner
    }

    /// The win log entry provides a stable per-game identifier, including if a
    /// completed save is later reopened.
    var completionID: UUID? {
        winnerID == nil ? nil : log.first?.id
    }

    private let startingCash = 1_500
    private let dice: () -> (Int, Int)
    private let deckOrder: [MonopolyCard]?
    private var pendingExtraRoll = false
    private var chanceCards: [MonopolyCard] = []
    private var communityChestCards: [MonopolyCard] = []
    /// Properties returned to the Bank by a bankruptcy must be auctioned one
    /// at a time before normal turn flow may resume.
    private var bankruptcyAuctionQueue: [Int] = []
    private struct OutstandingDebt { let playerID: UUID; let creditorID: UUID? }
    private enum DebtContinuation { case awaitRoll, endTurn, extraRoll }
    private var outstandingDebt: OutstandingDebt?
    private var debtContinuation: DebtContinuation = .awaitRoll

    private enum CardRentModifier {
        case normal
        case doubleRailroad
        case tenTimesUtilityRoll
    }

    init(dice: @escaping () -> (Int, Int) = { (Int.random(in: 1...6), Int.random(in: 1...6)) }, deckOrder: [MonopolyCard]? = nil) {
        self.dice = dice
        self.deckOrder = deckOrder
    }

    func makeSave() -> GameSave {
        GameSave(formatVersion: 1, players: players, currentPlayerIndex: currentPlayerIndex, phase: phase, pendingAction: pendingAction, lastRoll: lastRoll.map { [$0.0, $0.1] }, doublesThisTurn: doublesThisTurn, buildingsBySpaceID: buildingsBySpaceID, mortgagedSpaceIDs: mortgagedSpaceIDs, auction: auction, chanceCards: chanceCards, communityChestCards: communityChestCards, bankruptcyAuctionQueue: bankruptcyAuctionQueue, debtPlayerID: outstandingDebt?.playerID, debtCreditorID: outstandingDebt?.creditorID, debtContinuation: String(describing: debtContinuation), pendingExtraRoll: pendingExtraRoll, log: log)
    }

    @discardableResult
    func restore(from save: GameSave) -> Bool {
        guard save.formatVersion == 1, save.players.count >= 2, save.currentPlayerIndex >= 0, save.currentPlayerIndex < save.players.count else { return false }
        players = save.players; currentPlayerIndex = save.currentPlayerIndex; phase = save.phase; pendingAction = save.pendingAction
        lastRoll = save.lastRoll.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil }; doublesThisTurn = save.doublesThisTurn
        buildingsBySpaceID = save.buildingsBySpaceID; mortgagedSpaceIDs = save.mortgagedSpaceIDs; auction = save.auction
        chanceCards = save.chanceCards; communityChestCards = save.communityChestCards; bankruptcyAuctionQueue = save.bankruptcyAuctionQueue
        if let debtor = save.debtPlayerID { outstandingDebt = OutstandingDebt(playerID: debtor, creditorID: save.debtCreditorID) } else { outstandingDebt = nil }
        debtContinuation = save.debtContinuation == "extraRoll" ? .extraRoll : save.debtContinuation == "endTurn" ? .endTurn : .awaitRoll
        pendingExtraRoll = save.pendingExtraRoll; log = save.log
        return true
    }

    var currentPlayer: Player? {
        players.indices.contains(currentPlayerIndex) ? players[currentPlayerIndex] : nil
    }

    var playerNeedingDebtResolution: Player? {
        guard let debt = outstandingDebt else { return nil }
        return player(withID: debt.playerID)
    }

    var ownerBySpaceID: [Int: Player] {
        Dictionary(uniqueKeysWithValues: players.flatMap { player in player.properties.map { ($0, player) } })
    }

    var availableHouses: Int {
        StandardRules.totalHouses - buildingsBySpaceID.values.filter { (1...4).contains($0) }.reduce(0, +)
    }

    var availableHotels: Int {
        StandardRules.totalHotels - buildingsBySpaceID.values.filter { $0 == 5 }.count
    }

    var legalActions: [GameAction] {
        guard let player = currentPlayer, !player.bankrupt else { return [] }
        switch phase {
        case .awaitingRoll:
            if player.inJailTurns > 0 {
                var actions: [GameAction] = [.payJailFine, .attemptJailRoll]
                if player.getOutOfJailFreeCards > 0 { actions.append(.useGetOutOfJailFree) }
                return actions
            }
            return [.rollDice]
        case .awaitingPurchase: return [.buyProperty, .declineProperty]
        case .trading, .auction: return []
        case .resolvingAI, .gameOver: return []
        }
    }

    func start(endpoints: [PlayerEndpoint]) {
        let unique = Array(Set(endpoints)).sorted { $0.rawValue < $1.rawValue }
        guard unique.count == 4 else {
            append("Choose four distinct, reachable players before starting.")
            return
        }
        let tokens = ["car", "hat", "dog", "ship"]
        players = unique.enumerated().map { index, endpoint in
            Player(id: UUID(), name: endpoint.displayName, endpoint: endpoint, kind: .ai, token: tokens[index], position: 0, cash: startingCash, properties: [], inJailTurns: 0, getOutOfJailFreeCards: 0, getOutOfJailFreeDecks: [], bankrupt: false)
        }
        currentPlayerIndex = 0
        phase = .awaitingRoll
        pendingAction = .none
        lastRoll = nil
        doublesThisTurn = 0
        pendingExtraRoll = false
        buildingsBySpaceID = [:]
        mortgagedSpaceIDs = []
        auction = nil
        bankruptcyAuctionQueue = []
        outstandingDebt = nil
        chanceCards = (deckOrder ?? MonopolyCard.standardDeck).filter { $0.deck == .chance }
        communityChestCards = (deckOrder ?? MonopolyCard.standardDeck).filter { $0.deck == .communityChest }
        if deckOrder == nil { chanceCards.shuffle(); communityChestCards.shuffle() }
        log = [GameLogEntry(text: "Standard-rules game started with four players.")]
    }

    func returnToLobby() {
        players = []
        currentPlayerIndex = 0
        phase = .awaitingRoll
        pendingAction = .none
        lastRoll = nil
        doublesThisTurn = 0
        pendingExtraRoll = false
        buildingsBySpaceID = [:]
        mortgagedSpaceIDs = []
        auction = nil
        bankruptcyAuctionQueue = []
        outstandingDebt = nil
        log = []
    }

    /// Entry point for the local controls and, later, a structured LLM reply.
    @discardableResult
    func submit(_ action: GameAction) -> Bool {
        guard legalActions.contains(action) else {
            append("Rejected illegal action: \(String(describing: action)).")
            return false
        }
        switch action {
        case .rollDice, .attemptJailRoll: rollDice()
        case .buyProperty: buyPendingProperty()
        case .declineProperty: declinePendingProperty()
        case .payJailFine: payJailFine()
        case .useGetOutOfJailFree: useGetOutOfJailFree()
        case .endTurn: endTurn()
        }
        return true
    }

    private func rollDice() {
        guard var player = currentPlayer else { return }
        let roll = dice()
        lastRoll = roll
        let doubles = roll.0 == roll.1
        var leftJailByDoubles = false

        if player.inJailTurns > 0 {
            guard doubles else {
                player.inJailTurns += 1
                update(player)
                append("\(player.name) did not roll doubles in jail.")
                if player.inJailTurns > 3 {
                    charge(playerID: player.id, amount: StandardRules.jailFine, reason: "third failed jail roll")
                    guard var released = self.player(withID: player.id), !released.bankrupt else { endTurn(); return }
                    released.inJailTurns = 0
                    update(released)
                    append("\(released.name) paid $50 after a third failed jail roll and left jail.")
                    move(playerID: released.id, by: roll.0 + roll.1)
                    resolveLanding(for: released.id, extraRoll: false)
                } else {
                    endTurn()
                }
                return
            }
            player.inJailTurns = 0
            update(player)
            append("\(player.name) rolled doubles and left jail.")
            leftJailByDoubles = true
        }

        doublesThisTurn = doubles ? doublesThisTurn + 1 : 0
        if doublesThisTurn == 3 {
            sendToJail(playerID: player.id, reason: "three consecutive doubles")
            endTurn()
            return
        }

        move(playerID: player.id, by: roll.0 + roll.1)
        resolveLanding(for: player.id, extraRoll: doubles && !leftJailByDoubles)
    }

    private func move(playerID: UUID, by spaces: Int) {
        guard var player = player(withID: playerID) else { return }
        let prior = player.position
        player.position = (player.position + spaces) % board.count
        if prior + spaces >= board.count { player.cash += 200; append("\(player.name) passed GO and collected $200.") }
        update(player)
        append("\(player.name) rolled \(lastRoll?.0 ?? 0)+\(lastRoll?.1 ?? 0) and landed on \(board[player.position].name).")
    }

    private func resolveLanding(for playerID: UUID, extraRoll: Bool) {
        guard let player = player(withID: playerID) else { return }
        let space = board[player.position]
        switch space.kind {
        case .go, .jail, .freeParking: extraRoll ? beginExtraRoll() : endTurn()
        case .goToJail: sendToJail(playerID: playerID, reason: "Go To Jail"); endTurn()
        case .tax: charge(playerID: playerID, amount: space.tax, reason: space.name); extraRoll ? beginExtraRoll() : endTurn()
        case .property, .railroad, .utility:
            let spaceOwner = owner(of: space.id)
            if let spaceOwner, spaceOwner.id != playerID {
                transfer(amount: rentFor(space: space, ownerID: spaceOwner.id), from: playerID, to: spaceOwner.id)
                extraRoll ? beginExtraRoll() : endTurn()
            } else if spaceOwner == nil {
                pendingAction = .offerPurchase(spaceID: space.id, price: space.price)
                pendingExtraRoll = extraRoll
                phase = .awaitingPurchase
            } else { extraRoll ? beginExtraRoll() : endTurn() }
        case .chance:
            if !drawCard(from: .chance, for: playerID) { extraRoll ? beginExtraRoll() : endTurn() }
        case .communityChest:
            if !drawCard(from: .communityChest, for: playerID) { extraRoll ? beginExtraRoll() : endTurn() }
        }
    }

    private func buyPendingProperty() {
        guard case let .offerPurchase(spaceID, price) = pendingAction, let index = players.indices.contains(currentPlayerIndex) ? currentPlayerIndex : nil, players[index].cash >= price else { return }
        players[index].cash -= price
        players[index].properties.insert(spaceID)
        append("\(players[index].name) bought \(board[spaceID].name) for $\(price).")
        pendingAction = .none
        pendingExtraRoll ? beginExtraRoll() : endTurn()
        pendingExtraRoll = false
    }

    private func declinePendingProperty() {
        guard case let .offerPurchase(spaceID, _) = pendingAction, let player = currentPlayer else { return }
        append("\(player.name) declined \(board[spaceID].name). Auction opened.")
        pendingAction = .none
        auction = AuctionState(spaceID: spaceID, excludedPlayerID: nil, leadingBidderID: nil, leadingBid: 0, passedPlayerIDs: [])
        phase = .auction
    }

    @discardableResult
    func placeAuctionBid(_ amount: Int, by playerID: UUID) -> Bool {
        guard var auction, let bidder = player(withID: playerID), !bidder.bankrupt,
              auction.excludedPlayerID != playerID, !auction.passedPlayerIDs.contains(playerID),
              amount > auction.leadingBid, amount <= bidder.cash else { return false }
        auction.leadingBidderID = playerID
        auction.leadingBid = amount
        self.auction = auction
        append("\(bidder.name) bid $\(amount) for \(board[auction.spaceID].name).")
        return true
    }

    @discardableResult
    func passAuction(by playerID: UUID) -> Bool {
        guard var auction, playerID != auction.leadingBidderID else { return false }
        auction.passedPlayerIDs.insert(playerID)
        let remaining = players.filter { !$0.bankrupt && auction.excludedPlayerID != $0.id && $0.id != auction.leadingBidderID && !auction.passedPlayerIDs.contains($0.id) }
        if remaining.isEmpty {
            if let winnerID = auction.leadingBidderID, let index = players.firstIndex(where: { $0.id == winnerID }) {
                players[index].cash -= auction.leadingBid
                players[index].properties.insert(auction.spaceID)
                append("\(players[index].name) won \(board[auction.spaceID].name) for $\(auction.leadingBid).")
            } else { append("No bids for \(board[auction.spaceID].name).") }
            self.auction = nil
            if !bankruptcyAuctionQueue.isEmpty {
                bankruptcyAuctionQueue.removeFirst()
                if !bankruptcyAuctionQueue.isEmpty {
                    beginNextBankruptcyAuction()
                    return true
                }
            }
            pendingExtraRoll ? beginExtraRoll() : endTurn()
            pendingExtraRoll = false
        } else { self.auction = auction }
        return true
    }

    func canMortgage(spaceID: Int, by playerID: UUID) -> Bool {
        guard let player = player(withID: playerID), player.properties.contains(spaceID),
              board[spaceID].isPurchasable, !mortgagedSpaceIDs.contains(spaceID),
              buildingsBySpaceID[spaceID, default: 0] == 0 else { return false }
        let group = StandardRules.colorSet(for: spaceID)
        return group.allSatisfy { buildingsBySpaceID[$0, default: 0] == 0 }
    }

    @discardableResult
    func mortgage(spaceID: Int, by playerID: UUID) -> Bool {
        guard canMortgage(spaceID: spaceID, by: playerID), let index = players.firstIndex(where: { $0.id == playerID }) else { return false }
        players[index].cash += StandardRules.mortgageValue(for: board[spaceID])
        mortgagedSpaceIDs.insert(spaceID)
        append("\(players[index].name) mortgaged \(board[spaceID].name).")
        return true
    }

    @discardableResult
    func unmortgage(spaceID: Int, by playerID: UUID) -> Bool {
        guard outstandingDebt == nil, mortgagedSpaceIDs.contains(spaceID), let index = players.firstIndex(where: { $0.id == playerID }), players[index].properties.contains(spaceID) else { return false }
        let cost = StandardRules.unmortgageCost(for: board[spaceID])
        guard players[index].cash >= cost else { return false }
        players[index].cash -= cost
        mortgagedSpaceIDs.remove(spaceID)
        append("\(players[index].name) unmortgaged \(board[spaceID].name).")
        return true
    }

    func canBuild(on spaceID: Int, by playerID: UUID) -> Bool {
        guard outstandingDebt == nil, board.indices.contains(spaceID), let player = player(withID: playerID),
              board[spaceID].kind == .property, player.properties.contains(spaceID),
              let group = board[spaceID].colorGroup else { return false }
        let spaces = board.filter { $0.kind == .property && $0.colorGroup == group }.map(\.id)
        guard Set(spaces).isSubset(of: player.properties), !spaces.contains(where: mortgagedSpaceIDs.contains) else { return false }
        let current = buildingsBySpaceID[spaceID, default: 0]
        guard current < 5 else { return false }
        let groupCounts = spaces.map { buildingsBySpaceID[$0, default: 0] }
        guard current == (groupCounts.min() ?? 0), player.cash >= board[spaceID].houseCost else { return false }
        return current == 4 ? availableHotels > 0 : availableHouses > 0
    }

    @discardableResult
    func buyBuilding(on spaceID: Int, by playerID: UUID) -> Bool {
        guard canBuild(on: spaceID, by: playerID), let index = players.firstIndex(where: { $0.id == playerID }) else { return false }
        players[index].cash -= board[spaceID].houseCost
        let next = buildingsBySpaceID[spaceID, default: 0] + 1
        buildingsBySpaceID[spaceID] = next
        append("\(players[index].name) built \(next == 5 ? "a hotel" : "a house") on \(board[spaceID].name).")
        return true
    }

    @discardableResult
    func sellBuilding(on spaceID: Int, by playerID: UUID) -> Bool {
        guard canSellBuilding(on: spaceID, by: playerID), let index = players.firstIndex(where: { $0.id == playerID }) else { return false }
        let current = buildingsBySpaceID[spaceID, default: 0]
        buildingsBySpaceID[spaceID] = current - 1
        players[index].cash += board[spaceID].houseCost / 2
        append("\(players[index].name) sold \(current == 5 ? "a hotel" : "a house") on \(board[spaceID].name).")
        return true
    }

    func canSellBuilding(on spaceID: Int, by playerID: UUID) -> Bool {
        guard let player = player(withID: playerID), player.properties.contains(spaceID),
              let group = board[spaceID].colorGroup else { return false }
        let spaces = board.filter { $0.kind == .property && $0.colorGroup == group }.map(\.id)
        let current = buildingsBySpaceID[spaceID, default: 0]
        let maximum = spaces.map { buildingsBySpaceID[$0, default: 0] }.max() ?? 0
        guard current > 0, current == maximum else { return false }
        if current == 5 && availableHouses < 4 { return false }
        return true
    }

    func canExecuteTrade(_ offer: TradeOffer) -> Bool {
        guard offer.fromPlayerID != offer.toPlayerID, offer.fromCash >= 0, offer.toCash >= 0,
              let from = player(withID: offer.fromPlayerID), let to = player(withID: offer.toPlayerID),
              !from.bankrupt, !to.bankrupt,
              (from.cash >= offer.fromCash || (outstandingDebt?.playerID == from.id && offer.fromCash == 0)), to.cash >= offer.toCash,
              offer.fromProperties.isSubset(of: from.properties), offer.toProperties.isSubset(of: to.properties) else { return false }
        let traded = offer.fromProperties.union(offer.toProperties)
        return traded.allSatisfy { buildingsBySpaceID[$0, default: 0] == 0 }
    }

    /// Called only after both player endpoints have accepted the exact offer.
    /// Mortgaged properties transfer with the standard immediate 10% interest.
    @discardableResult
    func executeTrade(_ offer: TradeOffer) -> Bool {
        guard canExecuteTrade(offer), let fromIndex = players.firstIndex(where: { $0.id == offer.fromPlayerID }), let toIndex = players.firstIndex(where: { $0.id == offer.toPlayerID }) else { return false }
        let incomingToFrom = offer.toProperties.filter(mortgagedSpaceIDs.contains).reduce(0) { $0 + StandardRules.mortgageValue(for: board[$1]) / 10 }
        let incomingToTo = offer.fromProperties.filter(mortgagedSpaceIDs.contains).reduce(0) { $0 + StandardRules.mortgageValue(for: board[$1]) / 10 }
        guard players[fromIndex].cash - offer.fromCash + offer.toCash >= incomingToFrom,
              players[toIndex].cash - offer.toCash + offer.fromCash >= incomingToTo else { return false }
        players[fromIndex].cash += offer.toCash - offer.fromCash - incomingToFrom
        players[toIndex].cash += offer.fromCash - offer.toCash - incomingToTo
        players[fromIndex].properties.subtract(offer.fromProperties)
        players[fromIndex].properties.formUnion(offer.toProperties)
        players[toIndex].properties.subtract(offer.toProperties)
        players[toIndex].properties.formUnion(offer.fromProperties)
        let fromTerms = tradeTerms(cash: offer.fromCash, properties: offer.fromProperties)
        let toTerms = tradeTerms(cash: offer.toCash, properties: offer.toProperties)
        append("Trade completed: \(players[fromIndex].name) gave \(fromTerms) to \(players[toIndex].name); \(players[toIndex].name) gave \(toTerms) to \(players[fromIndex].name).")
        return true
    }

    private func tradeTerms(cash: Int, properties: Set<Int>) -> String {
        var terms: [String] = []
        if cash > 0 { terms.append("$\(cash)") }
        let propertyNames = properties.sorted().map { board[$0].name }
        terms.append(contentsOf: propertyNames)
        return terms.isEmpty ? "nothing" : terms.joined(separator: " and ")
    }

    private func payJailFine() {
        guard let player = currentPlayer else { return }
        charge(playerID: player.id, amount: 50, reason: "jail fine")
        guard var released = currentPlayer else { return }
        released.inJailTurns = 0
        update(released)
        append("\(released.name) paid $50 and left jail.")
    }

    private func useGetOutOfJailFree() {
        guard var player = currentPlayer, let deck = player.getOutOfJailFreeDecks.first else { return }
        player.getOutOfJailFreeDecks.removeFirst()
        player.getOutOfJailFreeCards -= 1
        player.inJailTurns = 0
        update(player)
        returnGetOutOfJailFreeCard(to: deck)
        append("\(player.name) used a Get Out of Jail Free card.")
    }

    /// Returns true when the card placed the player in a purchase decision.
    private func drawCard(from deck: CardDeck, for playerID: UUID) -> Bool {
        var cards = deck == .chance ? chanceCards : communityChestCards
        guard !cards.isEmpty else { return false }
        let card = cards.removeFirst()
        let held = card.effect == .getOutOfJailFree
        if !held { cards.append(card) }
        if deck == .chance { chanceCards = cards } else { communityChestCards = cards }
        append("\(deck == .chance ? "Chance" : "Community Chest") card: \(card.id).")
        return resolve(card.effect, for: playerID, getOutOfJailFreeDeck: held ? deck : nil)
    }

    /// Returns true when a card-directed landing is awaiting a purchase choice.
    private func resolve(_ effect: CardEffect, for playerID: UUID, getOutOfJailFreeDeck: CardDeck? = nil) -> Bool {
        guard let player = player(withID: playerID) else { return false }
        switch effect {
        case let .moveTo(destination, collectGo):
            return moveByCard(player: player, to: destination, collectGo: collectGo, rentModifier: .normal)
        case let .moveBack(spaces):
            var moved = player
            moved.position = (moved.position - spaces + board.count) % board.count
            update(moved)
            append("\(moved.name) moved back \(spaces) spaces.")
            return resolveCardLanding(for: moved.id, rentModifier: .normal)
        case let .nearestRailroad(doubleRent):
            let railroads = [5, 15, 25, 35]
            let destination = railroads.first(where: { $0 > player.position }) ?? 5
            return moveByCard(player: player, to: destination, collectGo: true, rentModifier: doubleRent ? .doubleRailroad : .normal)
        case .nearestUtility:
            let destination = [12, 28].first(where: { $0 > player.position }) ?? 12
            return moveByCard(player: player, to: destination, collectGo: true, rentModifier: .tenTimesUtilityRoll)
        case let .collect(amount):
            var updated = player; updated.cash += amount; update(updated); append("\(updated.name) collected $\(amount).")
        case let .payBank(amount): charge(playerID: playerID, amount: amount, reason: "card")
        case let .payEachPlayer(amount):
            for recipient in players where recipient.id != playerID && !recipient.bankrupt {
                guard outstandingDebt == nil, players.first(where: { $0.id == playerID })?.bankrupt == false else { break }
                transfer(amount: amount, from: playerID, to: recipient.id)
            }
        case let .collectFromEachPlayer(amount):
            for payer in players where payer.id != playerID && !payer.bankrupt { transfer(amount: amount, from: payer.id, to: playerID) }
        case .goToJail: sendToJail(playerID: playerID, reason: "card")
        case .getOutOfJailFree:
            guard let getOutOfJailFreeDeck else { return false }
            var updated = player
            updated.getOutOfJailFreeCards += 1
            updated.getOutOfJailFreeDecks.append(getOutOfJailFreeDeck)
            update(updated)
            append("\(updated.name) received a Get Out of Jail Free card.")
        case let .propertyRepairs(perHouse, perHotel):
            let amount = player.properties.reduce(0) { partial, spaceID in
                let buildings = buildingsBySpaceID[spaceID, default: 0]
                return partial + (buildings == 5 ? perHotel : buildings * perHouse)
            }
            if amount > 0 { charge(playerID: playerID, amount: amount, reason: "property repairs") }
        }
        return false
    }

    private func moveByCard(player: Player, to destination: Int, collectGo: Bool, rentModifier: CardRentModifier) -> Bool {
        var moved = player
        if collectGo && destination < moved.position { moved.cash += StandardRules.goSalary }
        moved.position = destination
        update(moved)
        append("\(moved.name) moved to \(board[destination].name).")
        return resolveCardLanding(for: moved.id, rentModifier: rentModifier)
    }

    private func resolveCardLanding(for playerID: UUID, rentModifier: CardRentModifier) -> Bool {
        guard let player = player(withID: playerID) else { return false }
        let space = board[player.position]
        switch space.kind {
        case .go, .jail, .freeParking: return false
        case .goToJail: sendToJail(playerID: playerID, reason: "card-directed Go To Jail"); return false
        case .tax: charge(playerID: playerID, amount: space.tax, reason: space.name); return false
        case .property, .railroad, .utility:
            if let owner = owner(of: space.id), owner.id != playerID {
                let amount: Int
                switch rentModifier {
                case .normal: amount = rentFor(space: space, ownerID: owner.id)
                case .doubleRailroad: amount = rentFor(space: space, ownerID: owner.id) * 2
                case .tenTimesUtilityRoll:
                    let roll = dice()
                    lastRoll = roll
                    amount = 10 * (roll.0 + roll.1)
                    append("\(player.name) rolled \(roll.0)+\(roll.1) for utility rent.")
                }
                transfer(amount: amount, from: playerID, to: owner.id)
                return false
            }
            if owner(of: space.id) == nil {
                pendingAction = .offerPurchase(spaceID: space.id, price: space.price)
                pendingExtraRoll = false
                phase = .awaitingPurchase
                return true
            }
            return false
        case .chance: return drawCard(from: .chance, for: playerID)
        case .communityChest: return drawCard(from: .communityChest, for: playerID)
        }
    }

    private func beginExtraRoll() {
        if outstandingDebt != nil { debtContinuation = .extraRoll; return }
        guard currentPlayer?.bankrupt != true else { endTurn(); return }
        phase = .awaitingRoll
        append("\(currentPlayer?.name ?? "Player") rolls again.")
    }

    private func endTurn() {
        if outstandingDebt != nil { debtContinuation = .endTurn; return }
        // A bankruptcy may have opened a mandatory Bank auction while the
        // previous landing was resolving. Keep that auction in control.
        guard auction == nil else { return }
        if !bankruptcyAuctionQueue.isEmpty {
            beginNextBankruptcyAuction()
            return
        }
        let activeIndices = players.indices.filter { !players[$0].bankrupt }
        guard let winnerIndex = activeIndices.first else { return }
        doublesThisTurn = 0
        pendingAction = .none
        guard activeIndices.count > 1 else {
            currentPlayerIndex = winnerIndex
            phase = .gameOver
            pendingAction = .gameOver(winner: players[winnerIndex].id)
            append("\(players[winnerIndex].name) wins the game.")
            return
        }
        var nextIndex = currentPlayerIndex
        repeat { nextIndex = (nextIndex + 1) % players.count } while players[nextIndex].bankrupt
        currentPlayerIndex = nextIndex
        phase = .awaitingRoll
    }
    private func charge(playerID: UUID, amount: Int, reason: String) {
        guard let index = players.firstIndex(where: { $0.id == playerID }) else { return }
        players[index].cash -= amount
        append("\(players[index].name) paid $\(amount) for \(reason).")
        recordDebtIfNeeded(playerID: playerID, creditorID: nil)
    }
    private func transfer(amount: Int, from payerID: UUID, to ownerID: UUID) {
        guard let payer = players.firstIndex(where: { $0.id == payerID }), let owner = players.firstIndex(where: { $0.id == ownerID }) else { return }
        players[payer].cash -= amount
        players[owner].cash += amount
        append("\(players[payer].name) paid \(players[owner].name) $\(amount) rent.")
        recordDebtIfNeeded(playerID: payerID, creditorID: ownerID)
    }

    /// Called after an endpoint has finished selling buildings and mortgaging
    /// assets. A negative balance is a voluntary declaration of bankruptcy.
    @discardableResult
    func resolveOutstandingDebt(by playerID: UUID) -> Bool {
        guard let debt = outstandingDebt, debt.playerID == playerID else { return false }
        outstandingDebt = nil
        if player(withID: playerID)?.cash ?? 0 < 0 {
            resolveBankruptcyIfNeeded(playerID: playerID, creditorID: debt.creditorID)
        }
        switch debtContinuation {
        case .awaitRoll: phase = .awaitingRoll
        case .endTurn: endTurn()
        case .extraRoll: beginExtraRoll()
        }
        return true
    }

    /// After any voluntary trade opportunity, a player with no legal way to
    /// sell buildings or mortgage property has exhausted the asset-management
    /// choices Monopoly permits and must proceed to bankruptcy.
    @discardableResult
    func declareBankruptcyIfNoLiquidationOptions(by playerID: UUID) -> Bool {
        guard let debt = outstandingDebt, debt.playerID == playerID,
              let player = player(withID: playerID), player.cash < 0,
              !player.properties.contains(where: { canSellBuilding(on: $0, by: playerID) || canMortgage(spaceID: $0, by: playerID) }) else {
            return false
        }
        return resolveOutstandingDebt(by: playerID)
    }

    private func recordDebtIfNeeded(playerID: UUID, creditorID: UUID?) {
        guard let player = player(withID: playerID), player.cash < 0 else { return }
        outstandingDebt = OutstandingDebt(playerID: playerID, creditorID: creditorID)
        debtContinuation = .awaitRoll
        phase = .resolvingAI
        append("\(player.name) must sell buildings or mortgage property before declaring bankruptcy.")
    }
    private func rentFor(space: BoardSpace, ownerID: UUID) -> Int {
        guard !mortgagedSpaceIDs.contains(space.id) else { return 0 }
        switch space.kind {
        case .railroad:
            let count = player(withID: ownerID)?.properties.filter { board[$0].kind == .railroad }.count ?? 0
            return [25, 50, 100, 200][max(0, min(count - 1, 3))]
        case .utility:
            let count = player(withID: ownerID)?.properties.filter { board[$0].kind == .utility }.count ?? 0
            return (count == 2 ? 10 : 4) * ((lastRoll?.0 ?? 0) + (lastRoll?.1 ?? 0))
        case .property:
            let set = StandardRules.colorSet(for: space.id)
            let ownsSet = set.isSubset(of: player(withID: ownerID)?.properties ?? [])
            return StandardRules.baseRent(spaceID: space.id, buildings: buildingsBySpaceID[space.id, default: 0], ownsColorSet: ownsSet)
        default: return space.rent
        }
    }
    private func sendToJail(playerID: UUID, reason: String) { guard var player = player(withID: playerID) else { return }; player.position = 10; player.inJailTurns = 1; update(player); append("\(player.name) went to jail (\(reason)).") }
    private func owner(of spaceID: Int) -> Player? { players.first { $0.properties.contains(spaceID) } }
    private func player(withID id: UUID) -> Player? { players.first { $0.id == id } }
    private func update(_ player: Player) { if let index = players.firstIndex(where: { $0.id == player.id }) { players[index] = player } }
    private func append(_ text: String) { log.insert(GameLogEntry(text: text), at: 0) }

    private func returnGetOutOfJailFreeCard(to deck: CardDeck) {
        guard let card = MonopolyCard.standardDeck.first(where: { $0.deck == deck && $0.effect == .getOutOfJailFree }) else { return }
        if deck == .chance { chanceCards.append(card) } else { communityChestCards.append(card) }
    }

    private func resolveBankruptcyIfNeeded(playerID: UUID, creditorID: UUID?) {
        guard let debtorIndex = players.firstIndex(where: { $0.id == playerID }), players[debtorIndex].cash < 0 else { return }
        let properties = players[debtorIndex].properties
        let jailCardDecks = players[debtorIndex].getOutOfJailFreeDecks
        for spaceID in properties { buildingsBySpaceID[spaceID] = nil }
        players[debtorIndex].properties.removeAll()
        players[debtorIndex].getOutOfJailFreeCards = 0
        players[debtorIndex].getOutOfJailFreeDecks.removeAll()
        players[debtorIndex].cash = 0
        players[debtorIndex].bankrupt = true
        if let creditorID, let creditorIndex = players.firstIndex(where: { $0.id == creditorID }) {
            players[creditorIndex].properties.formUnion(properties)
            append("\(players[debtorIndex].name) went bankrupt; assets transferred to \(players[creditorIndex].name).")
            let inheritedMortgageInterest = properties
                .filter(mortgagedSpaceIDs.contains)
                .reduce(0) { $0 + StandardRules.mortgageValue(for: board[$1]) / 10 }
            if inheritedMortgageInterest > 0 {
                players[creditorIndex].cash -= inheritedMortgageInterest
                append("\(players[creditorIndex].name) paid $\(inheritedMortgageInterest) mortgage interest to the Bank.")
                resolveBankruptcyIfNeeded(playerID: creditorID, creditorID: nil)
            }
        } else {
            mortgagedSpaceIDs.subtract(properties)
            append("\(players[debtorIndex].name) went bankrupt; properties returned to the bank.")
            bankruptcyAuctionQueue = properties.sorted()
            beginNextBankruptcyAuction()
        }
        jailCardDecks.forEach { returnGetOutOfJailFreeCard(to: $0) }
    }

    private func beginNextBankruptcyAuction() {
        guard let spaceID = bankruptcyAuctionQueue.first else { return }
        auction = AuctionState(spaceID: spaceID, excludedPlayerID: nil, leadingBidderID: nil, leadingBid: 0, passedPlayerIDs: [])
        phase = .auction
        append("Bank auction opened for \(board[spaceID].name).")
    }

    #if DEBUG
    func grantPropertiesForTesting(_ spaces: Set<Int>, to playerID: UUID) {
        guard let index = players.firstIndex(where: { $0.id == playerID }) else { return }
        players[index].properties.formUnion(spaces)
    }
    func setCashForTesting(_ cash: Int, for playerID: UUID) {
        guard let index = players.firstIndex(where: { $0.id == playerID }) else { return }
        players[index].cash = cash
    }
    func sendToJailForTesting(_ playerID: UUID) { sendToJail(playerID: playerID, reason: "test") }
    func makeCurrentForTesting(_ playerID: UUID) {
        guard let index = players.firstIndex(where: { $0.id == playerID }) else { return }
        currentPlayerIndex = index
        phase = .awaitingRoll
    }
    func bankruptForTesting(_ playerID: UUID) {
        guard let index = players.firstIndex(where: { $0.id == playerID }) else { return }
        players[index].cash = -1
        resolveBankruptcyIfNeeded(playerID: playerID, creditorID: nil)
    }
    func cardCountForTesting(_ deck: CardDeck) -> Int { deck == .chance ? chanceCards.count : communityChestCards.count }
    #endif
}
