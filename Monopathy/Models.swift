import Foundation
import SwiftUI

/// A player is a decision-making endpoint. It never owns game state: the
/// Monopathy rules engine remains the sole authority for every action.
enum PlayerEndpoint: String, CaseIterable, Identifiable, Codable {
    case hermesLocal = "hermes-local"
    case whiteLotus = "hermes-whitelotus"
    case blackLotus = "hermes-blacklotus"
    case greenLotus = "hermes-greenlotus"
    case hal = "hermes-hal"
    case cheyenne = "hermes-cheyenne"
    case chatGPT = "ChatGPT"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hermesLocal: "hermes-organon"
        default: rawValue
        }
    }

    var hermesProfileName: String? {
        switch self {
        case .hermesLocal: "local"
        case .whiteLotus: "whitelotus"
        case .blackLotus: "blacklotus"
        case .greenLotus: "greenlotus"
        case .hal: "hal"
        case .cheyenne: "cheyenne"
        case .chatGPT: nil
        }
    }
}

enum PlayerAvailability: Equatable {
    case checking
    case available(detail: String)
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .checking: "Checking…"
        case let .available(detail): detail
        case let .unavailable(reason): reason
        }
    }
}

struct PlayerSlot: Identifiable, Equatable {
    let id: Int
    var endpoint: PlayerEndpoint?
    var token: String
}

/// The complete set of actions an LLM may propose on a turn. The UI and
/// network layer exchange only these serializable proposals; an invalid one is
/// rejected with the current legal-action list rather than applied.
enum GameAction: Codable, Equatable, Hashable {
    case rollDice
    case buyProperty
    case declineProperty
    case payJailFine
    case useGetOutOfJailFree
    case attemptJailRoll
    case endTurn
}

enum PlayerKind: String, CaseIterable, Identifiable, Codable {
    case human = "Human"
    case ai = "AI"

    var id: String { rawValue }
}

enum SpaceKind: String, Codable {
    case go
    case property
    case railroad
    case utility
    case tax
    case chance
    case communityChest
    case jail
    case goToJail
    case freeParking
}

struct BoardSpace: Identifiable, Codable, Equatable {
    let id: Int
    let name: String
    let kind: SpaceKind
    let colorGroup: String?
    let price: Int
    let rent: Int
    let houseCost: Int
    let tax: Int

    var isPurchasable: Bool {
        kind == .property || kind == .railroad || kind == .utility
    }
}

struct PlayerConfig: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var kind: PlayerKind
    var token: String
}

struct Player: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// The selected decision-maker. This is kept separate from `name` so the
    /// table never has to infer a network target from display text.
    var endpoint: PlayerEndpoint
    var kind: PlayerKind
    var token: String
    var position: Int
    var cash: Int
    var properties: Set<Int>
    var inJailTurns: Int
    var getOutOfJailFreeCards: Int
    /// Which decks supplied the held cards, so each can be returned correctly.
    var getOutOfJailFreeDecks: [CardDeck]
    var bankrupt: Bool

    var netWorth: Int {
        cash
    }
}

struct GameLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String

    var displayText: String { Self.displayText(for: text) }

    static func displayText(for text: String) -> String {
        text.replacingOccurrences(of: "hermes-", with: "")
    }

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

struct TradeOffer: Identifiable, Codable, Equatable {
    let id: UUID
    let fromPlayerID: UUID
    let toPlayerID: UUID
    var fromCash: Int
    var toCash: Int
    var fromProperties: Set<Int>
    var toProperties: Set<Int>

    init(id: UUID = UUID(), fromPlayerID: UUID, toPlayerID: UUID, fromCash: Int, toCash: Int, fromProperties: Set<Int>, toProperties: Set<Int>) {
        self.id = id; self.fromPlayerID = fromPlayerID; self.toPlayerID = toPlayerID; self.fromCash = fromCash; self.toCash = toCash; self.fromProperties = fromProperties; self.toProperties = toProperties
    }
}

enum PendingAction: Codable, Equatable {
    case none
    case offerPurchase(spaceID: Int, price: Int)
    case tradeOffer(TradeOffer)
    case gameOver(winner: UUID)
}

struct AuctionState: Codable, Equatable {
    let spaceID: Int
    /// Standard Monopoly auctions are open to every non-bankrupt player,
    /// including the player who declined the initial purchase option.
    let excludedPlayerID: UUID?
    var leadingBidderID: UUID?
    var leadingBid: Int
    var passedPlayerIDs: Set<UUID>
}

enum TurnPhase: String, Codable {
    case awaitingRoll = "Roll"
    case awaitingPurchase = "Purchase"
    case auction = "Auction"
    case trading = "Trade"
    case resolvingAI = "AI"
    case gameOver = "Game Over"
}

extension BoardSpace {
    static let standardBoard: [BoardSpace] = [
        .init(id: 0, name: "GO", kind: .go, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 1, name: "Mediterranean Avenue", kind: .property, colorGroup: "Brown", price: 60, rent: 2, houseCost: 50, tax: 0),
        .init(id: 2, name: "Community Chest", kind: .communityChest, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 3, name: "Baltic Avenue", kind: .property, colorGroup: "Brown", price: 60, rent: 4, houseCost: 50, tax: 0),
        .init(id: 4, name: "Income Tax", kind: .tax, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 200),
        .init(id: 5, name: "Reading Railroad", kind: .railroad, colorGroup: "Railroad", price: 200, rent: 25, houseCost: 0, tax: 0),
        .init(id: 6, name: "Oriental Avenue", kind: .property, colorGroup: "Light Blue", price: 100, rent: 6, houseCost: 50, tax: 0),
        .init(id: 7, name: "Chance", kind: .chance, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 8, name: "Vermont Avenue", kind: .property, colorGroup: "Light Blue", price: 100, rent: 6, houseCost: 50, tax: 0),
        .init(id: 9, name: "Connecticut Avenue", kind: .property, colorGroup: "Light Blue", price: 120, rent: 8, houseCost: 50, tax: 0),
        .init(id: 10, name: "Jail / Just Visiting", kind: .jail, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 11, name: "St. Charles Place", kind: .property, colorGroup: "Pink", price: 140, rent: 10, houseCost: 100, tax: 0),
        .init(id: 12, name: "Electric Company", kind: .utility, colorGroup: "Utility", price: 150, rent: 30, houseCost: 0, tax: 0),
        .init(id: 13, name: "States Avenue", kind: .property, colorGroup: "Pink", price: 140, rent: 10, houseCost: 100, tax: 0),
        .init(id: 14, name: "Virginia Avenue", kind: .property, colorGroup: "Pink", price: 160, rent: 12, houseCost: 100, tax: 0),
        .init(id: 15, name: "Pennsylvania Railroad", kind: .railroad, colorGroup: "Railroad", price: 200, rent: 25, houseCost: 0, tax: 0),
        .init(id: 16, name: "St. James Place", kind: .property, colorGroup: "Orange", price: 180, rent: 14, houseCost: 100, tax: 0),
        .init(id: 17, name: "Community Chest", kind: .communityChest, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 18, name: "Tennessee Avenue", kind: .property, colorGroup: "Orange", price: 180, rent: 14, houseCost: 100, tax: 0),
        .init(id: 19, name: "New York Avenue", kind: .property, colorGroup: "Orange", price: 200, rent: 16, houseCost: 100, tax: 0),
        .init(id: 20, name: "Free Parking", kind: .freeParking, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 21, name: "Kentucky Avenue", kind: .property, colorGroup: "Red", price: 220, rent: 18, houseCost: 150, tax: 0),
        .init(id: 22, name: "Chance", kind: .chance, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 23, name: "Indiana Avenue", kind: .property, colorGroup: "Red", price: 220, rent: 18, houseCost: 150, tax: 0),
        .init(id: 24, name: "Illinois Avenue", kind: .property, colorGroup: "Red", price: 240, rent: 20, houseCost: 150, tax: 0),
        .init(id: 25, name: "B. & O. Railroad", kind: .railroad, colorGroup: "Railroad", price: 200, rent: 25, houseCost: 0, tax: 0),
        .init(id: 26, name: "Atlantic Avenue", kind: .property, colorGroup: "Yellow", price: 260, rent: 22, houseCost: 150, tax: 0),
        .init(id: 27, name: "Ventnor Avenue", kind: .property, colorGroup: "Yellow", price: 260, rent: 22, houseCost: 150, tax: 0),
        .init(id: 28, name: "Water Works", kind: .utility, colorGroup: "Utility", price: 150, rent: 30, houseCost: 0, tax: 0),
        .init(id: 29, name: "Marvin Gardens", kind: .property, colorGroup: "Yellow", price: 280, rent: 24, houseCost: 150, tax: 0),
        .init(id: 30, name: "Go To Jail", kind: .goToJail, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 31, name: "Pacific Avenue", kind: .property, colorGroup: "Green", price: 300, rent: 26, houseCost: 200, tax: 0),
        .init(id: 32, name: "North Carolina Avenue", kind: .property, colorGroup: "Green", price: 300, rent: 26, houseCost: 200, tax: 0),
        .init(id: 33, name: "Community Chest", kind: .communityChest, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 34, name: "Pennsylvania Avenue", kind: .property, colorGroup: "Green", price: 320, rent: 28, houseCost: 200, tax: 0),
        .init(id: 35, name: "Short Line", kind: .railroad, colorGroup: "Railroad", price: 200, rent: 25, houseCost: 0, tax: 0),
        .init(id: 36, name: "Chance", kind: .chance, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 0),
        .init(id: 37, name: "Park Place", kind: .property, colorGroup: "Dark Blue", price: 350, rent: 35, houseCost: 200, tax: 0),
        .init(id: 38, name: "Luxury Tax", kind: .tax, colorGroup: nil, price: 0, rent: 0, houseCost: 0, tax: 100),
        .init(id: 39, name: "Boardwalk", kind: .property, colorGroup: "Dark Blue", price: 400, rent: 50, houseCost: 200, tax: 0)
    ]
}
