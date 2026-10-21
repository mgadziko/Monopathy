# Monopathy

Monopathy is a native macOS SwiftUI game where four connected AI players play
standard US Monopoly over a LAN. You can watch the board and table log, save
and resume a game, and review each player's developing strategy journal. The
players propose actions; the app's rules engine alone decides what is legal.

## Project history

The game began under the name Monopolathy as an experiment connecting Hermes
players to a shared, rules-authoritative Monopoly table. It was renamed
Monopathy in October 2026 and moved to this public repository. The original
Monopolathy repository is now a private, end-of-life archive; new development
and releases happen here.

## Current foundation

- Four required player seats sourced from live Hermes profiles or ChatGPT.
- A reachability-only player lobby: only configured and reachable endpoints are
  selectable.
- Deterministic, testable turn authority with legal-action validation,
  doubles/three-doubles handling, GO salary, basic property purchase, rent,
  taxes, and standard jail release rules.
- A separately tested standard-rule catalog: all 32 card effects, the 22
  property rent schedules, monopoly double rent, mortgage arithmetic, and
  the finite 32-house / 12-hotel bank supply.
- Shuffled Chance and Community Chest deck state with tested action resolution
  for movement, payments, player-to-player card transfers, repairs, jail, and
  Get Out of Jail Free ownership. Card-directed movement resolves its
  destination normally, including purchase decisions, chained card spaces,
  double railroad rent, and the utility card's fresh rent roll.
- A held Get Out of Jail Free card is removed from its originating deck and is
  returned only when used or when its holder leaves the game.
- Validated auction state for declined properties, plus mortgage state that
  pays half the purchase price, suppresses rent, and blocks invalid repeat mortgages. Auctions
  follow the standard rule that the player who declined the property may still
  bid.
- Purchase and auction prompts identify the property, printed price, type,
  relevant group ownership, and current cash. The printed price informs the
  model's choice but does not cap a legal auction bid; the engine still
  validates every proposed action and bid.
- Full-set, unmortgaged-only house and hotel construction with even-building
  and selling enforcement, finite bank inventory, and mortgage restrictions.
- Before each turn, the player endpoint may make validated asset-management
  decisions—build, sell a building, mortgage, or unmortgage—until it replies
  that it is finished. The app never chooses those actions for it. A malformed,
  illegal, or timed-out optional asset decision is rejected without stopping
  automatic play.
- If a payment makes a player insolvent, play pauses for that player to sell
  buildings, mortgage eligible property, or make one exact trade offer. The
  engine resumes the interrupted turn as soon as current cash covers the debt;
  otherwise it waits for further legal liquidation or a bankruptcy decision.
  It never eliminates a player merely for a temporary negative balance.
- Validated cash/property trades, including the immediate interest required on
  transferred mortgaged property, and creditor/bank bankruptcy asset handling.
  A creditor inheriting a mortgaged property through bankruptcy likewise pays
  the standard immediate 10% mortgage interest to the Bank.
- Trade proposals and responses include color-group holdings, property prices,
  mortgages, and improvements. The prompts encourage both players to consider
  mutually useful set-building exchanges instead of reflexively passing, but
  never force a trade or change the engine's legality checks.
- If a player owes the Bank and goes bankrupt, their returned properties are
  automatically auctioned to the remaining players before normal turn flow
  resumes; a mortgage on a returned property is cleared by its return.
  Once per turn, a player may make one exact offer; its recipient separately
  accepts or declines that validated offer.
- A rejected or timed-out voluntary trade is reported and skipped rather than
  freezing the table. If an insolvent player makes a rejected rescue-trade
  proposal, play continues to legal liquidation (selling buildings or
  mortgaging property) before bankruptcy is considered.
- Completed-trade entries identify the cash and properties each player gave,
  rather than only naming the two participants.
- Bankruptcy removes the player from turn rotation; the engine records a
  game-over winner when only one solvent player remains.
- A strict, JSON-only turn-proposal protocol: endpoints receive a table
  snapshot and their current legal actions; malformed or illegal proposals are
  rejected before they can touch game state.
- A tested turn coordinator that keeps network transports separate from the
  rules engine; transports return text only and cannot invoke game tools.
- A narrow Hermes turn transport reads the selected profile's configured model
  endpoint and sends it a current JSON decision prompt plus that endpoint's
  bounded, engine-generated strategy journal. It cannot use Hermes tools,
  terminals, external Hermes memories, or alter the rules engine directly.
- Starting a game begins unthrottled automatic play: each active Hermes player
  receives one strict turn request at a time and the next request is made as
  soon as its legal action resolves. **Stop Automatic Play** is available
  between requests, and **Ask Current Player** supports manual prompting;
  an in-flight model request cannot yet be cancelled from the UI. Auctions use
  a separate strict `bid` or `pass` JSON proposal per eligible player, and
  therefore continue
  automatically. The optional trade window uses a separate proposal followed
  by an exact-offer acceptance, so automatic play continues afterward. While a
  player decision is pending, the status line shows elapsed time; this is
  observability only, not a hard timeout or cancellation control.
- The live table includes a complete board view: player tokens move around the
  standard 40 spaces. Its central live scoreboard keeps the current phase,
  player, player-color key, cash, locations, and last roll visible, while the
  side panel retains the chronological table log. Select a board space to
  inspect its price, owner, mortgage state, and development. The Pink group
  uses vivid magenta, visibly separate from the Red group's dots.
- There is no deterministic built-in AI strategy and no ChatGPT connection yet:
  each connected endpoint decides its own legal strategy, informed only by the
  live table and its own local journal.

The remaining work is a user-authorized ChatGPT sign-in flow and continued
rule-edge-case auditing. No endpoint will receive general tool access.

## Build and test

```sh
xcodebuild -project Monopathy.xcodeproj -scheme Monopathy -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

The project targets macOS 14 or later and does not require a powered-on remote
machine to build or run its offline lobby.

## Per-player strategy journals

After a completed game, Monopathy records a compact, personal outcome for
each AI endpoint: win/loss, ending cash and holdings, color-group progress, and
up to twelve categorized, engine-accepted strategic decisions (older journals
retain their four-event summaries). The next time that endpoint is
asked to make a turn, auction, trade, or asset decision, the most recent three
outcomes are included as bounded historical context. The journal is durable
prompt memory, not model retraining, and it never changes the rules engine or
shares one player's history with another.

On the Mac running Monopathy, journals are stored outside the repository at:

`~/Documents/Monopathy/Strategy Journals/`

On first launch, valid journals and strategy profiles from the previous
`Application Support` locations are copied into this folder if a destination
file does not already exist. The originals remain as backups, and an existing
file in the new folder is never overwritten. Game-save JSON files in
`~/Documents/Monopathy/` are unaffected.

There is one JSON file per endpoint, and each file retains at most eight game
records. Deleting one of these files resets only that player's accumulated
history.

Each endpoint also has a separate `-profile.json` file with advisory strategy
guidance. After a completed game, that endpoint's configured model may propose
one short heuristic change. Proposals are kept as candidates, not automatically
promoted. When a candidate exists, subsequent live games alternate between
current and candidate guidance for that endpoint; the File menu's **Review
Strategy Suggestions…** command shows each variant's observed win counts and
lets you keep testing, approve, or discard the candidate. A few games are not
enough to establish that one strategy is better, and there is no background
tournament or model-weight training. Reviews may fail or time out without
affecting the completed game. This mechanism does not change Hasbro rules or
the engine's action validation. On the same Mac, Save/Load retains the
in-progress game's strategy-variant assignment in the local profile file, so
a resumed result is counted for the same variant. Moving only the game save
to another Mac does not transfer strategy profiles.

## App bundle

A freshly built Debug bundle is available at `dist/Monopathy.app`. It is a
copyable local artifact; rebuild it with the Debug scheme before distributing a
newer version. When refreshing the bundle with `ditto`, touch the outer
`dist/Monopathy.app` directory afterward so Finder notices the new app icon
and metadata; copying only its contents can leave the bundle's old modification
date and a stale generic Finder icon.


## Bundle identifier

This project uses `net.quantumpenguin.Monopathy`. Use the `net.quantumpenguin.*` namespace for new app and extension targets.
