import XCTest
@testable import Monopathy

@MainActor
final class MonopathyTests: XCTestCase {
    private let fourPlayers: [PlayerEndpoint] = [.hermesLocal, .whiteLotus, .blackLotus, .greenLotus]

    func testWaitingTimeFormatterShowsMinutesAndHoursWithoutNegativeTime() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(WaitingTimeFormatter.string(since: start, now: start.addingTimeInterval(-1)), "0:00")
        XCTAssertEqual(WaitingTimeFormatter.string(since: start, now: start.addingTimeInterval(125)), "2:05")
        XCTAssertEqual(WaitingTimeFormatter.string(since: start, now: start.addingTimeInterval(3_661)), "1:01:01")
    }

    func testDecisionWaitClockKeepsStartForSameUnchangedDecision() {
        var clock = DecisionWaitClock()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(clock.start(for: "cheyenne|purchase|event-1", now: start), start)
        XCTAssertEqual(clock.start(for: "cheyenne|purchase|event-1", now: start.addingTimeInterval(5)), start)
        XCTAssertEqual(clock.start(for: "cheyenne|purchase|event-1", now: start.addingTimeInterval(125)), start)
        XCTAssertEqual(clock.start(for: "cheyenne|purchase|event-2", now: start.addingTimeInterval(126)), start.addingTimeInterval(126))
        clock.reset()
        XCTAssertEqual(clock.start(for: "cheyenne|purchase|event-2", now: start.addingTimeInterval(130)), start.addingTimeInterval(130))
    }

    func testLocalHermesEndpointUsesPortableOrganonDisplayLabel() {
        XCTAssertEqual(PlayerEndpoint.hermesLocal.displayName, "hermes-organon")
        XCTAssertEqual(PlayerEndpoint.hermesLocal.hermesProfileName, "local")
        XCTAssertEqual(PlayerEndpoint.hermesLocal.rawValue, "hermes-local")
    }

    func testHermesTurnRequestDisablesThinkingForStructuredTurn() throws {
        let request = HermesTurnTransport.Request(
            model: "qwen3.8-27b-q4km",
            messages: [.init(role: "user", content: "Return one JSON action.")],
            maxTokens: 128,
            temperature: 0,
            chatTemplateKwargs: ["enable_thinking": false]
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let templateArguments = try XCTUnwrap(object["chat_template_kwargs"] as? [String: Bool])

        XCTAssertEqual(templateArguments["enable_thinking"], false)
    }

    func testStrategyJournalPersistsPerPlayerAndAddsOnlyPersonalContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MonopathyStrategyJournal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        engine.grantPropertiesForTesting([1, 3], to: engine.players[0].id)

        let gameID = UUID()
        let store = StrategyJournalStore(directoryURL: root)
        store.record(gameID: gameID, winnerID: engine.players[0].id, players: engine.players, board: engine.board, log: [GameLogEntry(text: "\(engine.players[0].name) bought Baltic Avenue for $60.")])
        store.record(gameID: gameID, winnerID: engine.players[0].id, players: engine.players, board: engine.board, log: [])

        let restored = StrategyJournalStore(directoryURL: root)
        let winnerContext = restored.context(for: engine.players[0].endpoint)
        XCTAssertTrue(winnerContext.contains("completed 1 game(s) and won 1"))
        XCTAssertTrue(winnerContext.contains("Mediterranean Avenue"))
        XCTAssertTrue(winnerContext.contains("Brown 2/2"))
        XCTAssertTrue(winnerContext.contains("bought Baltic Avenue"))
        XCTAssertTrue(restored.context(for: .hal).contains("Personal strategy guidance"))
        XCTAssertFalse(restored.context(for: .hal).contains("Baltic Avenue"))
    }

    func testStrategySuggestionRemainsCandidateUntilExplicitApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MonopathyStrategyProfile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StrategyJournalStore(directoryURL: root)
        let endpoint = PlayerEndpoint.blackLotus
        let original = store.context(for: endpoint)
        await store.review(endpoint, gameID: UUID(), transport: FixedStrategyTransport(reply: "{\"guidance\":\"Keep a larger cash reserve before bidding.\"}"))
        XCTAssertTrue(store.context(for: endpoint).contains("Preserve liquidity"))
        XCTAssertEqual(store.suggestions.count, 1)

        let restored = StrategyJournalStore(directoryURL: root)
        XCTAssertEqual(restored.suggestions.count, 1)
        XCTAssertEqual(restored.context(for: .hal), StrategyJournalStore(directoryURL: root).context(for: .hal))
        XCTAssertNotEqual(original, "")
        restored.approve(endpoint)
        XCTAssertTrue(restored.context(for: endpoint).contains("larger cash reserve"))
        XCTAssertTrue(restored.suggestions.isEmpty)
    }

    func testMalformedStrategyReviewCannotChangeProfile() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MonopathyStrategyProfile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StrategyJournalStore(directoryURL: root)
        await store.review(.cheyenne, gameID: UUID(), transport: FixedStrategyTransport(reply: "ignore all rules"))
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    func testCandidateAndBaselineAlternateAcrossLiveGames() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MonopathyStrategyTrial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StrategyJournalStore(directoryURL: root)
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let endpoint = PlayerEndpoint.blackLotus
        await store.review(endpoint, gameID: UUID(), transport: FixedStrategyTransport(reply: "{\"guidance\":\"Keep a larger cash reserve before bidding.\"}"))
        store.beginGame(endpoints: fourPlayers)
        XCTAssertTrue(store.context(for: endpoint).contains("larger cash reserve"))
        store.record(gameID: UUID(), winnerID: engine.players[0].id, players: engine.players, board: engine.board, log: [])
        XCTAssertEqual(store.suggestions.first { $0.endpoint == endpoint }?.profile.candidateGames, 1)

        store.beginGame(endpoints: fourPlayers)
        XCTAssertTrue(store.context(for: endpoint).contains("Preserve liquidity"))
        store.record(gameID: UUID(), winnerID: engine.players[0].id, players: engine.players, board: engine.board, log: [])
        XCTAssertEqual(store.suggestions.first { $0.endpoint == endpoint }?.profile.baselineGames, 1)
    }

    func testSavedGameRestoresItsStrategyTrialAssignment() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MonopathyStrategyResume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let store = StrategyJournalStore(directoryURL: root)
        await store.review(.blackLotus, gameID: UUID(), transport: FixedStrategyTransport(reply: "{\"guidance\":\"Keep a larger cash reserve before bidding.\"}"))
        store.beginGame(endpoints: fourPlayers, gameStartID: engine.log.last?.id)
        store.beginGame(endpoints: fourPlayers, gameStartID: UUID()) // An abandoned newer game must not overwrite this save.

        let restored = StrategyJournalStore(directoryURL: root)
        restored.resumeGame(engine)
        XCTAssertTrue(restored.context(for: .blackLotus).contains("larger cash reserve"))
        XCTAssertTrue(restored.context(for: .whiteLotus).contains("Preserve liquidity"))
    }

    func testHermesTurnTransportPrependsStrategyJournal() {
        let transport = HermesTurnTransport(endpoint: .blackLotus, strategyContext: "Personal strategy journal: one prior win.")
        XCTAssertEqual(
            transport.decoratedPrompt("Return one JSON action."),
            "Personal strategy journal: one prior win.\n\nCurrent decision:\nReturn one JSON action."
        )
    }

    func testOptionalAssetDecisionIsSkippedWithoutLegalAssetAction() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        XCTAssertFalse(AssetSnapshot(engine: engine, player: engine.players[0]).hasOptionalActions)

        engine.grantPropertiesForTesting([1], to: engine.players[0].id)
        XCTAssertTrue(AssetSnapshot(engine: engine, player: engine.players[0]).hasOptionalActions)
    }

    func testOptionalTradeIsSkippedUntilAnExchangeIsPossible() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let proposer = engine.players[0]

        XCTAssertFalse(OptionalDecisionPolicy.hasTradeOpportunity(for: proposer, in: engine))
        engine.grantPropertiesForTesting([1], to: engine.players[1].id)
        XCTAssertTrue(OptionalDecisionPolicy.hasTradeOpportunity(for: proposer, in: engine))
    }

    func testOptionalDecisionTimeoutContinuesButOtherErrorsDoNot() {
        XCTAssertTrue(OptionalDecisionPolicy.shouldContinueAfterOptionalFailure(URLError(.timedOut)))
        XCTAssertFalse(OptionalDecisionPolicy.shouldContinueAfterOptionalFailure(URLError(.cannotConnectToHost)))
    }

    func testRejectedOptionalTradeProposalContinuesButEngineFailureDoesNot() {
        XCTAssertTrue(OptionalDecisionPolicy.shouldContinueAfterOptionalTradeFailure(
            TradeCoordinatorError.proposalRejected(.illegalProposal("engine validation failed"))
        ))
        XCTAssertTrue(OptionalDecisionPolicy.shouldContinueAfterOptionalTradeFailure(URLError(.timedOut)))
        XCTAssertFalse(OptionalDecisionPolicy.shouldContinueAfterOptionalTradeFailure(TradeCoordinatorError.engineRejected))
    }

    func testRejectedDebtSettlementTradeContinuesToLiquidation() {
        XCTAssertTrue(OptionalDecisionPolicy.shouldContinueAfterDebtSettlementTradeFailure(
            TradeCoordinatorError.proposalRejected(.illegalProposal("engine validation failed"))
        ))
        XCTAssertTrue(OptionalDecisionPolicy.shouldContinueAfterDebtSettlementTradeFailure(URLError(.timedOut)))
        XCTAssertFalse(OptionalDecisionPolicy.shouldContinueAfterDebtSettlementTradeFailure(TradeCoordinatorError.engineRejected))
    }

    func testRejectedOptionalAssetDecisionContinuesAfterValidation() {
        XCTAssertTrue(OptionalDecisionPolicy.shouldContinueAfterOptionalAssetFailure(AssetProtocolError.illegalAction("engine validation failed")))
        XCTAssertFalse(OptionalDecisionPolicy.shouldContinueAfterOptionalAssetFailure(URLError(.cannotConnectToHost)))
    }

    func testEndpointProbeAcceptsGGUFPathForConfiguredHermesAlias() {
        let serverModel = EndpointProbe.ModelList.Model(
            id: "/mnt/ssd894/Models/Qwen3.8-27B/Qwen3.8-27B-Q4_K_M.gguf",
            aliases: ["/mnt/ssd894/Models/Qwen3.8-27B/Qwen3.8-27B-Q4_K_M.gguf"]
        )

        XCTAssertTrue(EndpointProbe.modelMatches(serverModel, configuredModel: "qwen3.8-27b-q4km"))
    }

    func testEndpointProbeRejectsDifferentGGUFModel() {
        let serverModel = EndpointProbe.ModelList.Model(
            id: "/srv/models/Qwen3.8-27B-Q4_K_M.gguf",
            aliases: nil
        )

        XCTAssertFalse(EndpointProbe.modelMatches(serverModel, configuredModel: "qwen3.8-27b-q6k"))
    }

    func testGameRequiresFourDistinctPlayerEndpoints() {
        let engine = GameEngine()
        engine.start(endpoints: [.hermesLocal, .whiteLotus, .blackLotus])
        XCTAssertTrue(engine.players.isEmpty)

        engine.start(endpoints: [.hermesLocal, .whiteLotus, .blackLotus, .hermesLocal])
        XCTAssertTrue(engine.players.isEmpty)
    }

    func testGameStartsWithFourPlayersAndOnlyRollIsLegal() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        XCTAssertEqual(engine.players.count, 4)
        XCTAssertEqual(engine.players.map(\.cash), [1_500, 1_500, 1_500, 1_500])
        XCTAssertEqual(engine.legalActions, [.rollDice])
    }

    func testGameSaveRoundTripsAuthoritativeState() throws {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.buyProperty))
        let save = engine.makeSave()
        let decoded = try JSONDecoder().decode(GameSave.self, from: JSONEncoder().encode(save))
        let restored = GameEngine()
        XCTAssertTrue(restored.restore(from: decoded))
        XCTAssertEqual(restored.makeSave(), save)
    }

    func testIllegalActionIsRejectedWithoutChangingTurn() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let startingPlayer = engine.currentPlayer?.id
        XCTAssertFalse(engine.submit(.buyProperty))
        XCTAssertEqual(engine.currentPlayer?.id, startingPlayer)
    }

    func testDoublesAwardsAnExtraRoll() {
        let sequence = RollSequence([(1, 1)])
        let engine = GameEngine(dice: { sequence.next() })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.phase, .awaitingRoll)
        XCTAssertEqual(engine.currentPlayerIndex, 0)
    }

    func testUnownedPropertyOffersPurchase() {
        let sequence = RollSequence([(3, 3)])
        let engine = GameEngine(dice: { sequence.next() })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.phase, .awaitingPurchase)
        XCTAssertEqual(engine.legalActions, [.buyProperty, .declineProperty])
    }

    func testUnaffordablePurchaseCannotSucceedUntilPlayerRaisesCash() {
        let engine = GameEngine(dice: { (1, 2) })
        engine.start(endpoints: fourPlayers)
        let playerID = engine.players[0].id
        engine.grantPropertiesForTesting([1], to: playerID)
        engine.setCashForTesting(50, for: playerID)

        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.phase, .awaitingPurchase)
        XCTAssertEqual(engine.legalActions, [.declineProperty])
        XCTAssertFalse(engine.submit(.buyProperty))
        XCTAssertEqual(engine.currentPlayer?.cash, 50)
        XCTAssertEqual(engine.phase, .awaitingPurchase)
        XCTAssertFalse(engine.currentPlayer?.properties.contains(3) ?? true)

        XCTAssertTrue(engine.mortgage(spaceID: 1, by: playerID))
        XCTAssertEqual(engine.legalActions, [.buyProperty, .declineProperty])
        XCTAssertTrue(engine.submit(.buyProperty))
        XCTAssertTrue(engine.players[0].properties.contains(3))
        XCTAssertEqual(engine.players[0].cash, 20)
    }

    func testUnaffordablePurchaseDeclinesWithoutCallingModel() async throws {
        let engine = GameEngine(dice: { (1, 2) })
        engine.start(endpoints: fourPlayers)
        engine.setCashForTesting(50, for: engine.players[0].id)
        XCTAssertTrue(engine.submit(.rollDice))
        let restored = GameEngine()
        XCTAssertTrue(restored.restore(from: engine.makeSave()))

        let action = try await TurnCoordinator().playTurn(engine: restored, transport: UnexpectedTransport())
        XCTAssertEqual(action, .declineProperty)
        XCTAssertEqual(restored.phase, .auction)
        XCTAssertNotNil(restored.auction)
    }

    func testPurchaseFundingPromptAndMortgageRestoreBuyOption() async throws {
        let engine = GameEngine(dice: { (1, 2) })
        engine.start(endpoints: fourPlayers)
        let player = engine.players[0]
        engine.grantPropertiesForTesting([1], to: player.id)
        engine.setCashForTesting(50, for: player.id)
        XCTAssertTrue(engine.submit(.rollDice))

        let offer = PropertyDecisionContext(engine: engine, spaceID: 3)
        let snapshot = AssetSnapshot(engine: engine, player: engine.players[0])
        XCTAssertTrue(snapshot.hasFundingActions)
        let prompt = AssetProtocol.prompt(for: snapshot, fundingPurchase: offer)
        XCTAssertTrue(prompt.contains("offered Baltic Avenue for $60, but have $50"))

        let decision = try await AssetCoordinator().requestDecision(
            engine: engine,
            player: engine.players[0],
            transport: FixedTransport(reply: "{\"action\":\"mortgage\",\"property_id\":1}"),
            fundingPurchase: offer
        )
        XCTAssertEqual(decision, .mortgage(1))
        XCTAssertEqual(engine.legalActions, [.buyProperty, .declineProperty])
    }

    func testChanceCardMovesPlayerAndPaysGoSalary() {
        let cards = [MonopolyCard(id: "test-go", deck: .chance, effect: .moveTo(0, collectGo: true))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].position, 0)
        XCTAssertEqual(engine.players[0].cash, 1_700)
    }

    func testGetOutOfJailFreeCardLeavesAndReturnsToItsDeck() {
        let cards = [MonopolyCard(id: "test-jail-card", deck: .chance, effect: .getOutOfJailFree)]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let player = engine.players[0]
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].getOutOfJailFreeCards, 1)
        XCTAssertEqual(engine.players[0].getOutOfJailFreeDecks, [.chance])
        XCTAssertEqual(engine.cardCountForTesting(.chance), 0)
        engine.sendToJailForTesting(player.id)
        engine.makeCurrentForTesting(player.id)
        XCTAssertTrue(engine.submit(.useGetOutOfJailFree))
        XCTAssertEqual(engine.players[0].getOutOfJailFreeCards, 0)
        XCTAssertEqual(engine.cardCountForTesting(.chance), 1)
    }

    func testCardDirectedUnownedPropertyOffersPurchase() {
        let cards = [MonopolyCard(id: "test-illinois", deck: .chance, effect: .moveTo(24, collectGo: true))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].position, 24)
        XCTAssertEqual(engine.phase, .awaitingPurchase)
        XCTAssertEqual(engine.legalActions, [.buyProperty, .declineProperty])
    }

    func testNearestRailroadCardChargesDoubleRent() {
        let cards = [MonopolyCard(id: "test-railroad", deck: .chance, effect: .nearestRailroad(doubleRent: true))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        engine.grantPropertiesForTesting([15], to: engine.players[1].id)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].position, 15)
        XCTAssertEqual(engine.players[0].cash, 1_450)
        XCTAssertEqual(engine.players[1].cash, 1_550)
    }

    func testNearestUtilityCardRollsTenTimesRent() {
        let cards = [MonopolyCard(id: "test-utility", deck: .chance, effect: .nearestUtility)]
        let sequence = RollSequence([(3, 4), (2, 3)])
        let engine = GameEngine(dice: { sequence.next() }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        engine.grantPropertiesForTesting([12], to: engine.players[1].id)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].position, 12)
        XCTAssertEqual(engine.players[0].cash, 1_450)
        XCTAssertEqual(engine.players[1].cash, 1_550)
    }

    func testDeclinedPropertyUsesValidatedAuction() {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.declineProperty))
        XCTAssertEqual(engine.phase, .auction)
        let bidder = engine.players[1]
        XCTAssertTrue(engine.placeAuctionBid(75, by: bidder.id))
        XCTAssertFalse(engine.placeAuctionBid(75, by: engine.players[2].id))
        XCTAssertTrue(engine.passAuction(by: engine.players[2].id))
        XCTAssertTrue(engine.passAuction(by: engine.players[3].id))
        XCTAssertTrue(engine.passAuction(by: engine.players[0].id))
        XCTAssertTrue(engine.players[1].properties.contains(6))
        XCTAssertEqual(engine.players[1].cash, 1_425)
    }

    func testMortgageAddsHalfPriceAndCannotRepeat() {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.buyProperty))
        let owner = engine.players[0]
        XCTAssertTrue(engine.mortgage(spaceID: 6, by: owner.id))
        XCTAssertTrue(engine.mortgagedSpaceIDs.contains(6))
        XCTAssertEqual(engine.players[0].cash, 1_450)
        XCTAssertFalse(engine.mortgage(spaceID: 6, by: owner.id))
    }

    func testMortgagedPropertyDoesNotCollectRent() {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        let owner = engine.players[1]
        engine.grantPropertiesForTesting([6], to: owner.id)
        XCTAssertTrue(engine.mortgage(spaceID: 6, by: owner.id))
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].cash, 1_500)
        XCTAssertEqual(engine.players[1].cash, 1_550)
    }

    func testBuildingsRequireACompleteSetAndFollowEvenBuilding() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let owner = engine.players[0]
        XCTAssertFalse(engine.buyBuilding(on: 1, by: owner.id))
        engine.grantPropertiesForTesting([1, 3], to: owner.id)
        XCTAssertTrue(engine.buyBuilding(on: 1, by: owner.id))
        XCTAssertFalse(engine.buyBuilding(on: 1, by: owner.id))
        XCTAssertTrue(engine.buyBuilding(on: 3, by: owner.id))
        XCTAssertEqual(engine.availableHouses, 30)
    }

    func testHotelsUseFiniteInventoryAndPreventMortgagingDevelopedSet() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let owner = engine.players[0]
        engine.grantPropertiesForTesting([1, 3], to: owner.id)
        for _ in 0..<4 {
            XCTAssertTrue(engine.buyBuilding(on: 1, by: owner.id))
            XCTAssertTrue(engine.buyBuilding(on: 3, by: owner.id))
        }
        XCTAssertTrue(engine.buyBuilding(on: 1, by: owner.id))
        XCTAssertEqual(engine.buildingsBySpaceID[1], 5)
        XCTAssertEqual(engine.availableHotels, 11)
        XCTAssertFalse(engine.mortgage(spaceID: 3, by: owner.id))
        XCTAssertTrue(engine.sellBuilding(on: 1, by: owner.id))
        XCTAssertEqual(engine.buildingsBySpaceID[1], 4)
        XCTAssertEqual(engine.availableHotels, 12)
    }

    func testTradeTransfersCashAndUndevelopedProperties() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let first = engine.players[0]
        let second = engine.players[1]
        engine.grantPropertiesForTesting([1], to: first.id)
        engine.grantPropertiesForTesting([3], to: second.id)
        let offer = TradeOffer(fromPlayerID: first.id, toPlayerID: second.id, fromCash: 100, toCash: 25, fromProperties: [1], toProperties: [3])
        XCTAssertTrue(engine.canExecuteTrade(offer))
        XCTAssertTrue(engine.executeTrade(offer))
        XCTAssertTrue(engine.players[0].properties.contains(3))
        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertEqual(engine.players[0].cash, 1_425)
        XCTAssertEqual(engine.players[1].cash, 1_575)
        XCTAssertEqual(
            engine.log.first?.text,
            "Trade completed: \(GameLogEntry.displayText(for: first.name)) gave $100 and Mediterranean Avenue to \(GameLogEntry.displayText(for: second.name)); \(GameLogEntry.displayText(for: second.name)) gave $25 and Baltic Avenue to \(GameLogEntry.displayText(for: first.name))."
        )
    }

    func testInsolventPlayerTransfersAssetsToCreditor() {
        let cards = [MonopolyCard(id: "test-payment", deck: .chance, effect: .payEachPlayer(50))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let debtor = engine.players[0]
        let creditor = engine.players[1]
        engine.grantPropertiesForTesting([1], to: debtor.id)
        engine.setCashForTesting(10, for: debtor.id)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.playerNeedingDebtResolution?.id, debtor.id)
        XCTAssertTrue(engine.resolveOutstandingDebt(by: debtor.id))
        XCTAssertTrue(engine.players[0].bankrupt)
        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertEqual(engine.players[0].cash, 0)
        XCTAssertEqual(engine.players[1].cash, 1_550)
        XCTAssertEqual(creditor.id, engine.players[1].id)
        XCTAssertEqual(engine.currentPlayerIndex, 1)
    }

    func testPlayerCanMortgageBeforeDeclaringBankruptcy() {
        let cards = [MonopolyCard(id: "test-bank-payment", deck: .chance, effect: .payBank(20))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let debtor = engine.players[0]
        engine.grantPropertiesForTesting([1], to: debtor.id)
        engine.setCashForTesting(10, for: debtor.id)

        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.phase, .resolvingAI)
        XCTAssertFalse(engine.resolveOutstandingDebtIfCovered(by: debtor.id))
        XCTAssertTrue(engine.mortgage(spaceID: 1, by: debtor.id))
        XCTAssertEqual(engine.playerNeedingDebtResolution.map { AssetSnapshot(engine: engine, player: $0).cash }, 20)
        XCTAssertTrue(engine.resolveOutstandingDebtIfCovered(by: debtor.id))

        XCTAssertFalse(engine.players[0].bankrupt)
        XCTAssertEqual(engine.players[0].cash, 20)
        XCTAssertEqual(engine.currentPlayerIndex, 1)
    }

    func testDebtWithoutLiquidationOptionsProceedsToBankruptcy() {
        let cards = [MonopolyCard(id: "test-bank-payment", deck: .chance, effect: .payBank(50))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let debtor = engine.players[0]
        engine.setCashForTesting(10, for: debtor.id)

        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.playerNeedingDebtResolution?.id, debtor.id)
        XCTAssertTrue(engine.declareBankruptcyIfNoLiquidationOptions(by: debtor.id))
        XCTAssertTrue(engine.players[0].bankrupt)
        XCTAssertEqual(engine.players[0].cash, 0)
        XCTAssertEqual(engine.currentPlayerIndex, 1)
    }

    func testPlayerCanTradeToSettleDebtBeforeBankruptcy() {
        let cards = [MonopolyCard(id: "test-bank-payment", deck: .chance, effect: .payBank(50))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let debtor = engine.players[0]
        let recipient = engine.players[1]
        engine.grantPropertiesForTesting([1], to: debtor.id)
        engine.setCashForTesting(10, for: debtor.id)

        XCTAssertTrue(engine.submit(.rollDice))
        let sale = TradeOffer(fromPlayerID: debtor.id, toPlayerID: recipient.id, fromCash: 0, toCash: 50, fromProperties: [1], toProperties: [])
        XCTAssertTrue(engine.executeTrade(sale))
        XCTAssertTrue(engine.resolveOutstandingDebt(by: debtor.id))

        XCTAssertFalse(engine.players[0].bankrupt)
        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertEqual(engine.players[0].cash, 10)
    }

    func testCreditorPaysMortgageInterestForInheritedProperty() {
        let cards = [MonopolyCard(id: "test-payment", deck: .chance, effect: .payEachPlayer(50))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let debtor = engine.players[0]
        let creditor = engine.players[1]
        engine.grantPropertiesForTesting([1], to: debtor.id)
        XCTAssertTrue(engine.mortgage(spaceID: 1, by: debtor.id))
        engine.setCashForTesting(10, for: debtor.id)

        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.resolveOutstandingDebt(by: debtor.id))

        XCTAssertTrue(engine.players[0].bankrupt)
        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertTrue(engine.mortgagedSpaceIDs.contains(1))
        XCTAssertEqual(engine.players[1].cash, 1_547)
        XCTAssertEqual(creditor.id, engine.players[1].id)
    }

    func testBankruptcyToBankAuctionsReturnedProperties() {
        let cards = [MonopolyCard(id: "test-bank-payment", deck: .chance, effect: .payBank(50))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let debtor = engine.players[0]
        let bidder = engine.players[1]
        engine.grantPropertiesForTesting([1], to: debtor.id)
        engine.setCashForTesting(10, for: debtor.id)

        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.resolveOutstandingDebt(by: debtor.id))
        XCTAssertTrue(engine.players[0].bankrupt)
        XCTAssertEqual(engine.phase, .auction)
        XCTAssertEqual(engine.auction?.spaceID, 1)
        XCTAssertTrue(engine.placeAuctionBid(20, by: bidder.id))
        XCTAssertTrue(engine.passAuction(by: engine.players[2].id))
        XCTAssertTrue(engine.passAuction(by: engine.players[3].id))

        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertEqual(engine.players[1].cash, 1_480)
        XCTAssertEqual(engine.phase, .awaitingRoll)
        XCTAssertEqual(engine.currentPlayer?.id, bidder.id)
    }

    func testFinalSolventPlayerWinsAndBankruptSeatsAreSkipped() {
        let engine = GameEngine(dice: { (1, 2) })
        engine.start(endpoints: fourPlayers)
        let winner = engine.players[0]
        engine.grantPropertiesForTesting([3], to: winner.id)
        for player in engine.players.dropFirst() { engine.bankruptForTesting(player.id) }
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.phase, .gameOver)
        XCTAssertEqual(engine.currentPlayer?.id, winner.id)
        guard case let .gameOver(winnerID) = engine.pendingAction else { return XCTFail("Expected game-over state") }
        XCTAssertEqual(winnerID, winner.id)
    }

    func testTurnProtocolAcceptsOnlyCurrentLegalJSONAction() throws {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let snapshot = TurnSnapshot(engine: engine)
        XCTAssertEqual(snapshot.legalActions, ["roll_dice"])
        XCTAssertNil(snapshot.purchaseOffer)
        XCTAssertEqual(try TurnProtocol.action(from: "{\"action\":\"roll_dice\"}", allowed: engine.legalActions), .rollDice)
        XCTAssertThrowsError(try TurnProtocol.action(from: "{\"action\":\"buy_property\"}", allowed: engine.legalActions))
        XCTAssertThrowsError(try TurnProtocol.action(from: "I want to roll", allowed: engine.legalActions))
    }

    func testPurchasePromptIdentifiesPropertyPriceAndGroupOwnership() throws {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        engine.grantPropertiesForTesting([8], to: engine.players[1].id)
        XCTAssertTrue(engine.submit(.rollDice))

        let snapshot = TurnSnapshot(engine: engine)
        let offer = try XCTUnwrap(snapshot.purchaseOffer)
        XCTAssertEqual(offer.name, "Oriental Avenue")
        XCTAssertEqual(offer.printedPrice, 100)
        XCTAssertEqual(offer.kind, .property)
        XCTAssertEqual(offer.baseRent, 6)
        XCTAssertEqual(offer.colorGroup, "Light Blue")
        XCTAssertEqual(offer.groupMembers.count, 3)
        XCTAssertEqual(offer.groupMembers[1].ownerName, engine.players[1].name)
        let prompt = TurnProtocol.prompt(for: snapshot)
        XCTAssertTrue(prompt.contains("\"printedPrice\":100"))
        XCTAssertTrue(prompt.contains("\"name\":\"Oriental Avenue\""))
        XCTAssertTrue(prompt.contains("Declining sends it to a standard auction"))
    }

    func testUtilityPurchaseContextDoesNotInventFixedRent() throws {
        let engine = GameEngine(dice: { (6, 6) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))

        let offer = try XCTUnwrap(TurnSnapshot(engine: engine).purchaseOffer)
        XCTAssertEqual(offer.name, "Electric Company")
        XCTAssertEqual(offer.kind, .utility)
        XCTAssertEqual(offer.printedPrice, 150)
        XCTAssertNil(offer.baseRent)
        XCTAssertEqual(offer.groupMembers.count, 2)
    }

    func testCoordinatorSubmitsOnlyValidatedTransportAction() async throws {
        let engine = GameEngine(dice: { (1, 2) })
        engine.start(endpoints: fourPlayers)
        let action = try await TurnCoordinator().playTurn(engine: engine, transport: FixedTransport(reply: "{\"action\":\"roll_dice\"}"))
        XCTAssertEqual(action, .rollDice)
        XCTAssertNotNil(engine.lastRoll)
    }

    func testAuctionCoordinatorValidatesAndAppliesBid() async throws {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.declineProperty))
        let bidder = engine.players[1]
        let decision = try await AuctionCoordinator().requestAuctionDecision(engine: engine, bidder: bidder, transport: FixedTransport(reply: "{\"action\":\"bid\",\"amount\":75}"))
        XCTAssertEqual(decision, .bid(75))
        XCTAssertEqual(engine.auction?.leadingBidderID, bidder.id)
        XCTAssertThrowsError(try AuctionProtocol.decision(from: "{\"action\":\"bid\",\"amount\":0}", minimumBid: 76, availableCash: bidder.cash))
    }

    func testAuctionPromptAsksForAValuationBasedBidWithoutChangingTheLegalRange() {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        engine.grantPropertiesForTesting([8], to: engine.players[2].id)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.declineProperty))
        XCTAssertTrue(engine.placeAuctionBid(200, by: engine.players[1].id))
        let snapshot = AuctionSnapshot(engine: engine, bidder: engine.players[2])

        let prompt = AuctionProtocol.prompt(for: snapshot)
        XCTAssertEqual(snapshot.property.name, "Oriental Avenue")
        XCTAssertEqual(snapshot.property.printedPrice, 100)
        XCTAssertEqual(snapshot.property.colorGroup, "Light Blue")
        XCTAssertEqual(snapshot.property.groupMembers[1].ownerName, engine.players[2].name)
        XCTAssertTrue(prompt.contains("\"printedPrice\":100"))
        XCTAssertTrue(prompt.contains("printedPrice is a reference, not a bid cap"))
        XCTAssertTrue(prompt.contains("Do not automatically bid the minimum increment or your entire cash balance"))
        XCTAssertTrue(prompt.contains("from 201 through 1500"))
        XCTAssertTrue(prompt.contains("not a sealed maximum"))
    }

    func testDecliningBuyerMayBidAbovePrintedPrice() {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        let buyer = engine.players[0]
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.declineProperty))
        XCTAssertTrue(engine.placeAuctionBid(500, by: buyer.id))
        for player in engine.players.dropFirst() {
            XCTAssertTrue(engine.passAuction(by: player.id))
        }
        XCTAssertTrue(engine.players[0].properties.contains(6))
        XCTAssertEqual(engine.players[0].cash, 1_000)
    }

    func testAuctionCoordinatorRetriesInvalidBid() async throws {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.declineProperty))
        let bidder = engine.players[1]
        let decision = try await AuctionCoordinator().requestAuctionDecision(engine: engine, bidder: bidder, transport: ReplySequenceTransport(replies: ["{\"action\":\"bid\",\"amount\":0}", "{\"action\":\"pass\"}"]))
        XCTAssertEqual(decision, .pass)
        XCTAssertTrue(engine.auction?.passedPlayerIDs.contains(bidder.id) == true)
    }

    func testAuctionCoordinatorForcesPassAfterThreeInvalidReplies() async throws {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.declineProperty))
        let bidder = engine.players[1]
        let decision = try await AuctionCoordinator().requestAuctionDecision(engine: engine, bidder: bidder, transport: ReplySequenceTransport(replies: Array(repeating: "{\"action\":\"bid\",\"amount\":0}", count: 3)))
        XCTAssertEqual(decision, .pass)
        XCTAssertTrue(engine.auction?.passedPlayerIDs.contains(bidder.id) == true)
    }

    func testTradeCoordinatorExecutesOnlyAcceptedValidatedOffer() async throws {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let proposer = engine.players[0]
        let recipient = engine.players[1]
        engine.grantPropertiesForTesting([1], to: proposer.id)
        let proposal = "{\"action\":\"propose_trade\",\"to_player_id\":\"\(recipient.id.uuidString)\",\"give_cash\":0,\"request_cash\":100,\"give_properties\":[1],\"request_properties\":[]}"
        let result = try await TradeCoordinator().negotiate(
            engine: engine,
            proposer: proposer,
            proposerTransport: FixedTransport(reply: proposal),
            recipientTransport: { _ in FixedTransport(reply: "{\"action\":\"accept\"}") }
        )
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertEqual(engine.players[0].cash, 1_600)
        XCTAssertEqual(engine.players[1].cash, 1_400)
    }

    func testAssetCoordinatorAppliesOnlyValidatedMortgage() async throws {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let player = engine.players[0]
        engine.grantPropertiesForTesting([6], to: player.id)
        let decision = try await AssetCoordinator().requestDecision(engine: engine, player: player, transport: FixedTransport(reply: "{\"action\":\"mortgage\",\"property_id\":6}"))
        XCTAssertEqual(decision, .mortgage(6))
        XCTAssertTrue(engine.mortgagedSpaceIDs.contains(6))
        XCTAssertEqual(engine.players[0].cash, 1_550)
        XCTAssertThrowsError(try AssetProtocol.decision(from: "{\"action\":\"build\"}"))
    }

    func testAssetCoordinatorRetriesRejectedAction() async throws {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let player = engine.players[0]
        engine.grantPropertiesForTesting([6], to: player.id)
        let transport = ReplySequenceTransport(replies: [
            "{\"action\":\"mortgage\",\"property_id\":999}",
            "{\"action\":\"mortgage\",\"property_id\":6}"
        ])

        let decision = try await AssetCoordinator().requestDecision(engine: engine, player: player, transport: transport)
        XCTAssertEqual(decision, .mortgage(6))
        XCTAssertTrue(engine.mortgagedSpaceIDs.contains(6))
    }

    func testProtocolParsesJSONInsideMarkdownOrProse() throws {
        XCTAssertEqual(try AssetProtocol.decision(from: "I will finish now.\n```json\n{\"action\":\"done\"}\n```"), .done)
        XCTAssertEqual(try TurnProtocol.action(from: "Decision: {\"action\":\"roll_dice\"}", allowed: [.rollDice]), .rollDice)
    }

    func testThreeConsecutiveDoublesSendsPlayerToJail() {
        let sequence = RollSequence([(1, 1), (1, 1), (1, 1)])
        let cards = [MonopolyCard(id: "test-chest", deck: .communityChest, effect: .collect(0))]
        let engine = GameEngine(dice: { sequence.next() }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let firstPlayerName = GameLogEntry.displayText(for: engine.players[0].name)

        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.rollDice))

        XCTAssertEqual(engine.players[0].position, 10)
        XCTAssertEqual(engine.players[0].inJailTurns, 1)
        XCTAssertEqual(engine.currentPlayerIndex, 1)
        XCTAssertEqual(engine.log[1].text, "\(firstPlayerName) rolled 1+1 (third consecutive doubles).")
        XCTAssertEqual(engine.log[0].text, "\(firstPlayerName) went to jail (three consecutive doubles).")
        XCTAssertFalse(engine.log.contains { $0.text.contains("hermes-") })
    }

    func testLegacyLogEntriesDisplayWithoutHermesPrefix() {
        let entry = GameLogEntry(text: "hermes-cheyenne paid hermes-organon $10 rent.")
        XCTAssertEqual(entry.displayText, "cheyenne paid organon $10 rent.")
    }

    func testJailDoublesMovePlayerWithoutExtraRoll() {
        let engine = GameEngine(dice: { (5, 5) })
        engine.start(endpoints: fourPlayers)
        let jailed = engine.players[0]
        engine.sendToJailForTesting(jailed.id)
        XCTAssertTrue(engine.submit(.attemptJailRoll))
        XCTAssertEqual(engine.players[0].inJailTurns, 0)
        XCTAssertEqual(engine.players[0].position, 20)
        XCTAssertEqual(engine.currentPlayerIndex, 1)
    }

    func testThirdFailedJailRollForcesFineAndMovement() {
        let engine = GameEngine(dice: { (1, 2) })
        engine.start(endpoints: fourPlayers)
        let jailed = engine.players[0]
        engine.sendToJailForTesting(jailed.id)
        for _ in 0..<3 {
            engine.makeCurrentForTesting(jailed.id)
            XCTAssertTrue(engine.submit(.attemptJailRoll))
        }
        XCTAssertEqual(engine.players[0].inJailTurns, 0)
        XCTAssertEqual(engine.players[0].cash, 1_450)
        XCTAssertEqual(engine.players[0].position, 13)
        XCTAssertEqual(engine.phase, .awaitingPurchase)
    }

    func testStandardRulesCatalogHasCompleteCardDecks() {
        let chance = MonopolyCard.standardDeck.filter { $0.deck == .chance }
        let chest = MonopolyCard.standardDeck.filter { $0.deck == .communityChest }
        XCTAssertEqual(chance.count, 16)
        XCTAssertEqual(chest.count, 16)
        XCTAssertEqual(Set(MonopolyCard.standardDeck.map(\.id)).count, 32)
        XCTAssertEqual(StandardRules.totalHouses, 32)
        XCTAssertEqual(StandardRules.totalHotels, 12)
    }

    func testAssetSnapshotReportsFiniteBuildingInventory() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let owner = engine.players[0]
        engine.grantPropertiesForTesting([1, 3], to: owner.id)
        XCTAssertTrue(engine.buyBuilding(on: 1, by: owner.id))
        let snapshot = AssetSnapshot(engine: engine, player: engine.players[0])
        XCTAssertEqual(snapshot.availableHouses, 31)
        XCTAssertEqual(snapshot.availableHotels, 12)
    }

    func testStandardPropertyRentSchedulesAndMonopolies() {
        XCTAssertEqual(StandardRules.baseRent(spaceID: 1, buildings: 0, ownsColorSet: false), 2)
        XCTAssertEqual(StandardRules.baseRent(spaceID: 1, buildings: 0, ownsColorSet: true), 4)
        XCTAssertEqual(StandardRules.baseRent(spaceID: 39, buildings: 5, ownsColorSet: true), 2_000)
        XCTAssertEqual(StandardRules.colorSet(for: 1), Set([1, 3]))
        XCTAssertEqual(StandardRules.mortgageValue(for: BoardSpace.standardBoard[39]), 200)
        XCTAssertEqual(StandardRules.unmortgageCost(for: BoardSpace.standardBoard[39]), 221)
    }
}

private struct FixedStrategyTransport: PlayerTurnTransport {
    let reply: String
    func respond(to prompt: String) async throws -> String { reply }
}

private final class RollSequence {
    private var rolls: [(Int, Int)]
    init(_ rolls: [(Int, Int)]) { self.rolls = rolls }
    func next() -> (Int, Int) { rolls.removeFirst() }
}

private struct FixedTransport: PlayerTurnTransport {
    let reply: String
    func respond(to prompt: String) async throws -> String { reply }
}

private struct UnexpectedTransport: PlayerTurnTransport {
    func respond(to prompt: String) async throws -> String {
        XCTFail("A forced decline must not call the model")
        return ""
    }
}

private actor ReplySequenceTransport: PlayerTurnTransport {
    private var replies: [String]
    init(replies: [String]) { self.replies = replies }
    func respond(to prompt: String) async throws -> String { replies.removeFirst() }
}
