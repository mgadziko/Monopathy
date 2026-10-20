import Foundation

/// Fixed data for the current US standard edition. This is deliberately kept
/// apart from the game engine so that an LLM can never redefine the rules by
/// wording a turn request persuasively.
enum StandardRules {
    static let startingCash = 1_500
    static let goSalary = 200
    static let jailFine = 50
    static let totalHouses = 32
    static let totalHotels = 12

    static let propertyRentSchedules: [Int: [Int]] = [
        1: [2, 10, 30, 90, 160, 250], 3: [4, 20, 60, 180, 320, 450],
        6: [6, 30, 90, 270, 400, 550], 8: [6, 30, 90, 270, 400, 550], 9: [8, 40, 100, 300, 450, 600],
        11: [10, 50, 150, 450, 625, 750], 13: [10, 50, 150, 450, 625, 750], 14: [12, 60, 180, 500, 700, 900],
        16: [14, 70, 200, 550, 750, 950], 18: [14, 70, 200, 550, 750, 950], 19: [16, 80, 220, 600, 800, 1_000],
        21: [18, 90, 250, 700, 875, 1_050], 23: [18, 90, 250, 700, 875, 1_050], 24: [20, 100, 300, 750, 925, 1_100],
        26: [22, 110, 330, 800, 975, 1_150], 27: [22, 110, 330, 800, 975, 1_150], 29: [24, 120, 360, 850, 1_025, 1_200],
        31: [26, 130, 390, 900, 1_100, 1_275], 32: [26, 130, 390, 900, 1_100, 1_275], 34: [28, 150, 450, 1_000, 1_200, 1_400],
        37: [35, 175, 500, 1_100, 1_300, 1_500], 39: [50, 200, 600, 1_400, 1_700, 2_000]
    ]

    static func mortgageValue(for space: BoardSpace) -> Int { space.price / 2 }
    static func unmortgageCost(for space: BoardSpace) -> Int { Int((Double(mortgageValue(for: space)) * 1.1).rounded(.up)) }

    static func colorSet(for spaceID: Int) -> Set<Int> {
        Set(BoardSpace.standardBoard.filter { $0.colorGroup == BoardSpace.standardBoard[spaceID].colorGroup && $0.kind == .property }.map(\.id))
    }

    static func baseRent(spaceID: Int, buildings: Int, ownsColorSet: Bool) -> Int {
        guard let schedule = propertyRentSchedules[spaceID] else { return BoardSpace.standardBoard[spaceID].rent }
        guard buildings == 0 else { return schedule[min(buildings, 5)] }
        return ownsColorSet ? schedule[0] * 2 : schedule[0]
    }
}

enum CardDeck: String, Codable, CaseIterable { case chance, communityChest }

enum CardEffect: Codable, Equatable {
    case moveTo(Int, collectGo: Bool)
    case moveBack(Int)
    case nearestRailroad(doubleRent: Bool)
    case nearestUtility
    case collect(Int)
    case payBank(Int)
    case payEachPlayer(Int)
    case collectFromEachPlayer(Int)
    case goToJail
    case getOutOfJailFree
    case propertyRepairs(perHouse: Int, perHotel: Int)
}

struct MonopolyCard: Identifiable, Codable, Equatable {
    let id: String
    let deck: CardDeck
    let effect: CardEffect
}

extension MonopolyCard {
    /// Effects and quantities match the standard US game deck. Descriptive
    /// prose remains in the UI layer, avoiding a hard-coded reproduction of
    /// card artwork or formatting.
    static let standardDeck: [MonopolyCard] = [
        .init(id: "chance-go", deck: .chance, effect: .moveTo(0, collectGo: true)),
        .init(id: "chance-illinois", deck: .chance, effect: .moveTo(24, collectGo: true)),
        .init(id: "chance-st-charles", deck: .chance, effect: .moveTo(11, collectGo: true)),
        .init(id: "chance-utility", deck: .chance, effect: .nearestUtility),
        .init(id: "chance-railroad-1", deck: .chance, effect: .nearestRailroad(doubleRent: true)),
        .init(id: "chance-railroad-2", deck: .chance, effect: .nearestRailroad(doubleRent: true)),
        .init(id: "chance-dividend", deck: .chance, effect: .collect(50)),
        .init(id: "chance-jail-card", deck: .chance, effect: .getOutOfJailFree),
        .init(id: "chance-back-three", deck: .chance, effect: .moveBack(3)),
        .init(id: "chance-jail", deck: .chance, effect: .goToJail),
        .init(id: "chance-repairs", deck: .chance, effect: .propertyRepairs(perHouse: 25, perHotel: 100)),
        .init(id: "chance-tax", deck: .chance, effect: .payBank(15)),
        .init(id: "chance-reading", deck: .chance, effect: .moveTo(5, collectGo: true)),
        .init(id: "chance-chairman", deck: .chance, effect: .payEachPlayer(50)),
        .init(id: "chance-loan", deck: .chance, effect: .collect(150)),
        .init(id: "chance-crossword", deck: .chance, effect: .collect(100)),
        .init(id: "chest-go", deck: .communityChest, effect: .moveTo(0, collectGo: true)),
        .init(id: "chest-bank-error", deck: .communityChest, effect: .collect(200)),
        .init(id: "chest-doctor", deck: .communityChest, effect: .payBank(50)),
        .init(id: "chest-sale", deck: .communityChest, effect: .collect(50)),
        .init(id: "chest-jail-card", deck: .communityChest, effect: .getOutOfJailFree),
        .init(id: "chest-jail", deck: .communityChest, effect: .goToJail),
        .init(id: "chest-income", deck: .communityChest, effect: .collect(100)),
        .init(id: "chest-holiday", deck: .communityChest, effect: .collect(100)),
        .init(id: "chest-refund", deck: .communityChest, effect: .collect(20)),
        .init(id: "chest-birthday", deck: .communityChest, effect: .collectFromEachPlayer(10)),
        .init(id: "chest-life-insurance", deck: .communityChest, effect: .collect(100)),
        .init(id: "chest-hospital", deck: .communityChest, effect: .payBank(100)),
        .init(id: "chest-school", deck: .communityChest, effect: .payBank(150)),
        .init(id: "chest-consultancy", deck: .communityChest, effect: .collect(25)),
        .init(id: "chest-repairs", deck: .communityChest, effect: .propertyRepairs(perHouse: 40, perHotel: 115)),
        .init(id: "chest-beauty", deck: .communityChest, effect: .collect(10))
    ]
}
