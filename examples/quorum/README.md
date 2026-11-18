# Quorum

A live decision room built on ZyncBase's React bindings, presence, and atomic store operations.

Everyone joins with a link, adds ideas anonymously, and spends a small budget of votes. Nothing is tallied on screen until the facilitator closes the round. The reveal is one committed transaction: the frozen result and the phase change land together, and no late vote can slip in.

## Run it

From the repository root, with Zig 0.16, Bun, and the native build prerequisites installed:

```sh
bun install
bun run demo:quorum
```

Open **http://localhost:8080**. The launcher builds the SDK and a ReleaseFast ZyncBase binary. For later starts without rebuilding:

```sh
bun run demo:quorum:dev
```

Add `--reset` to discard the local data directory before starting:

```sh
bun run demo:quorum:dev --reset
```

A data directory written by a ZyncBase build from before schema migrations is refused at startup with `UnrecognizedDatabase`. Start once with `--reset`.

Stop with Ctrl+C.

### The 60-second demo

1. Enter a name and press **Try the demo**. A room is seeded with four sample members, eight ideas, and twenty pre-cast votes.
2. Press **Start voting** and spend a vote or two. Keep voting open.
3. Open the room link in an incognito window, join as a second member, and vote from both windows.
4. Back in the host window, press **Close and reveal**.
5. After the reveal, **Discuss top topics**, add a decision, and close the meeting to get the summary and exports.

## The product loop

- **Collect** — anonymous cards in the template's lanes (Start / Stop / Continue, or a single Ideas lane). Cards freeze when voting starts.
- **Vote** — every member gets the same budget (five by default, max three per idea). Votes are private and can be changed until close.
- **Results** — the facilitator closes the round; the room sees one frozen ranking.
- **Discuss** — the facilitator walks the topics in vote order; anyone can record a decision.
- **Summary** — priorities, decisions, participants, Markdown/CSV export.

The facilitator controls phase transitions, vote duration, topic focus, and card removal. The room is open by link; there are no accounts.

## How it uses ZyncBase

### One namespace per room

A room lives in the store namespace `room:<code>`. The browser's JWT carries the room code, and the namespace rule requires `$session.room` to match `$namespace.room_code`. The same namespace holds presence, so rooms never see each other's members or typing state.

The app server lazily starts **one worker connection per active room** when `POST /session` first asks for that code. The worker registers the room's actions in that namespace. Creating a room does not require a connection per user, and a token for room A cannot enter room B's namespace.

### The browser does not write the ledger

The browser writes **presence only**. Every durable write (`rooms`, `members`, `budgets`, `cards`, `ballots`, `results`, `decisions`) is performed by the service worker through an action.

That is deliberate: the room's rules are cross-row and phase-bound. The authorization language is collection/row scoped, so it cannot express "the room is in `vote`" or "my budget is still positive." The action is the trusted boundary, and it returns meaningful errors (`NO_VOTES_LEFT`, `CARD_LIMIT`, `ROOM_FULL`) instead of a generic precondition failure.

### Private ballots, public reveal

Each member has a public row in `members` and a private row in `budgets`. Ballots are private rows with a `count` per member/card. The read rules on those two collections are:

```json
{ "or": [
  { "$session.role": { "eq": "service" } },
  { "$doc.user_id": { "eq": "$session.externalId" } }
] }
```

`user_id` is the JWT subject (`sub`), so the rule matches the stable external identity. `presence_id` is the internal `$session.userId` used to join presence entries to the roster. The service role can read all ballots for the close; members only ever see their own.

The subject is issued by the app server and bound to a signed credential stored in the browser. Public `user_id`/`host_user_id` values are identifiers, not bearer tokens; a member who reads the host's id cannot mint a host session.

### Casting a vote

The ballot row is created at zero when the vote starts (and for late joiners when they join during the vote). Casting is one committed batch:

```ts
[
  ballot.count += 1        if count < max_per_card
  budget.votes_left -= 1   if votes_left >= 1
  room.votes_cast += 1     if phase == "vote"
  room.votes_version += 1  if phase == "vote"
]
```

The per-card and budget guards prevent over-spending. The phase guard prevents a vote from landing after close. Retracting is the inverse.

### Closing the round

Closing cannot just read the ballots and write the results; a concurrent vote would be missed. `votes_cast` is a net counter, so a vote plus a retract can leave it unchanged. `votes_version` increments on every change, and the close batch uses it as an optimistic snapshot guard:

1. Read the room version, cards, and ballots.
2. Tally and rank.
3. In one committed batch, set the room phase to `results` **only if** the phase is still `vote` and `votes_version` still matches, then write the result rows.
4. On `PRECONDITION_FAILED`, retry; the failed batch committed nothing.

The guarded phase write comes before the result rows. If two facilitators click close at once, the second sees the phase change and returns idempotently instead of inserting duplicate result rows.

This is the part a whiteboard sticker vote cannot guarantee: the reveal is a transaction, and the result is frozen in the same commit that ends the round.

## Code map

| File | Role |
|---|---|
| `schema.json` | Rooms, members, private budgets/ballots, frozen results, decisions, actions, presence |
| `authorization.json` | Room-scoped namespace; service-only writes; private budget/ballot reads |
| `worker.ts` | Action handlers, ballot ledger, close/reveal, demo seed |
| `server.ts` | JWT minting, ZyncBase spawn, room worker pool, `/session`, `/health` |
| `dev.ts` | Local edge: SPA assets, `/session`/`/health`, `/auth/ticket`, `/ws` |
| `app.tsx` | Landing, create/join, session gate |
| `room.tsx` | Phase UI: collect, vote, results, discuss, summary |
| `session.ts` | Server-issued identity credential, token exchange, client creation |
| `shared.ts` | Templates, room codes, limits, row types |
| `smoke.ts` | Two-client end-to-end flow |
| `room.test.ts` | Concurrency, privacy, close-race, isolation, demo seed |
| `ui.test.tsx` | Real server + happy-dom walk through the demo UI |
| `build.ts` | Bun browser bundle |

## Test

```sh
bun run test:quorum
```

This checks generated types, runs the unit/integration/UI tests, and runs the two-client smoke. The integration tests start a real ZyncBase in a temporary data directory. The UI test starts the dev edge and clicks through the demo in happy-dom with native WebSocket and fetch.

```sh
bun run typecheck:examples
bunx biome check examples/quorum
```

## Limits

- Open by link: anyone with the code can join, and a single person can open multiple browser profiles. The budget is enforced per identity, not per human.
- The facilitator must stay connected to advance phases; there is no host transfer in this version.
- The voting timer is advisory; only the facilitator's close makes the result final.
- No accounts, teams, billing, integrations, attachments, grouping, or multi-round runoff.
- Local-first: no deployment scripts or CDN story. The app server and ZyncBase run as one local stack.

## Next

The obvious next features are private collect (cards hidden until a reveal), affinity grouping before the vote, a runoff round for the top three, and an optional room passcode. They are intentionally left out of this example so the vote ledger and the reveal stay the center of the demo.
