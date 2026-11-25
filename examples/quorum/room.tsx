// biome-ignore-all lint/complexity/noExcessiveCognitiveComplexity: the room shell and phase views compose queries, presence, and vote controls.
// biome-ignore-all lint/suspicious/noArrayIndexKey: fixed-size dot meters use positional keys.
import { useEffect, useMemo, useState } from "react";
import {
	useAction,
	useListen,
	usePresence,
	useQuery,
	useSyncStatus,
	ZyncBaseProvider,
} from "./bindings";
import type { RoomSession } from "./session";
import {
	type CardRow,
	COLORS,
	type DecisionRow,
	initials,
	isHost,
	lanesFor,
	type MemberRow,
	PHASES,
	type PresenceUser,
	possibleVotes,
	type ResultRow,
	type RoomRow,
} from "./shared";

export function Room({
	session,
	onLeave,
}: {
	session: RoomSession;
	onLeave: () => void;
}) {
	useEffect(
		() => () => {
			void session.client.disconnect();
		},
		[session.client],
	);
	return (
		<ZyncBaseProvider client={session.client}>
			<RoomView session={session} onLeave={onLeave} />
		</ZyncBaseProvider>
	);
}

function RoomView({
	session,
	onLeave,
}: {
	session: RoomSession;
	onLeave: () => void;
}) {
	const roomState = useListen(["rooms", session.roomId]);
	const room = roomState.value as RoomRow | undefined;
	const round = room?.round ?? 1;
	const cards = useQuery("cards", {
		where: { room_code: session.code, round },
		orderBy: [{ created_at: "asc" }],
	});
	const results = useQuery("results", {
		where: { room_code: session.code, round },
		orderBy: [{ rank: "asc" }],
	});
	const decisions = useQuery("decisions", {
		where: { room_code: session.code, round },
		orderBy: [{ created_at: "asc" }],
	});
	const members = useQuery("members", {
		where: { room_code: session.code },
		orderBy: [{ created_at: "asc" }],
	});
	const presence = usePresence();
	const sync = useSyncStatus();
	const [toast, setToast] = useState<string | null>(null);

	const me = members.data.find((member) => member.user_id === session.userId);
	const myName = me?.name ?? session.name;
	const myColor = me?.color ?? COLORS[0];
	const myRole = me?.role ?? "member";
	const publish = presence.publish;

	useEffect(() => {
		if (!session.presenceId) return;
		void publish({
			name: myName,
			color: myColor,
			role: myRole,
			typing: false,
		}).catch(() => {});
	}, [publish, session.presenceId, myName, myColor, myRole]);

	useEffect(() => {
		if (!toast) return;
		const timer = setTimeout(() => setToast(null), 3500);
		return () => clearTimeout(timer);
	}, [toast]);

	const onlineIds = useMemo(() => {
		const ids = new Set<string>();
		if (presence.mine) ids.add(presence.mine.userId);
		for (const peer of presence.peers) ids.add(peer.userId);
		return ids;
	}, [presence.mine, presence.peers]);

	const notify = (message: string) => setToast(message);

	if (roomState.error) {
		return (
			<main className="fatal">
				<h1>That room is not available</h1>
				<p>{roomState.error.message}</p>
				<button type="button" className="primary" onClick={onLeave}>
					Back to the lobby
				</button>
			</main>
		);
	}
	if (!room) {
		return (
			<main className="loading-screen">
				<div className="loading-dots">
					<i />
					<i />
					<i />
				</div>
				<p>Opening the room…</p>
			</main>
		);
	}

	const host = isHost(room, session.userId);
	const readOnly = session.readOnly || !session.memberId;

	return (
		<main className="room">
			<header className="room-header">
				<div className="room-topline">
					<button type="button" className="brand-button" onClick={onLeave}>
						<span className="brand-dot" />
						Quorum
					</button>
					<div className="room-title-block">
						<h1>{room.title}</h1>
						<div className="room-meta">
							<span className="room-code-chip">{room.room_code}</span>
							{room.demo ? <span className="demo-chip">Demo room</span> : null}
							{host ? <span className="host-chip">You facilitate</span> : null}
							{readOnly ? <span className="host-chip">Viewing</span> : null}
						</div>
					</div>
					<div className="room-actions">
						<button
							type="button"
							className="ghost small"
							onClick={() => {
								void navigator.clipboard
									?.writeText(location.href)
									.then(() => notify("Room link copied"))
									.catch(() => notify("Could not copy the link"));
							}}
						>
							Share
						</button>
						<SyncBadge status={sync.status} synced={sync.synced} />
					</div>
				</div>

				<div className="room-toolbar">
					<PhaseStepper phase={room.phase} />
					<div className="room-toolbar-right">
						{room.phase === "vote" && room.vote_ends_at ? (
							<Countdown endsAt={room.vote_ends_at} />
						) : null}
						<PresenceStack
							members={members.data}
							onlineIds={onlineIds}
							hostUserId={room.host_user_id}
						/>
					</div>
				</div>
			</header>

			<div className="room-body">
				{room.phase === "collect" ? (
					<CollectPhase
						room={room}
						cards={cards.data}
						host={host}
						publish={publish}
						notify={notify}
					/>
				) : null}
				{room.phase === "vote" ? (
					readOnly ? (
						<ReadOnlyNote />
					) : (
						<VotePhase
							room={room}
							cards={cards.data}
							session={session}
							host={host}
							notify={notify}
							publish={publish}
						/>
					)
				) : null}
				{room.phase === "results" ? (
					<ResultsPhase
						room={room}
						results={results.data}
						host={host}
						notify={notify}
					/>
				) : null}
				{room.phase === "discuss" ? (
					<DiscussPhase
						room={room}
						results={results.data}
						decisions={decisions.data}
						members={members.data}
						session={session}
						host={host}
						notify={notify}
					/>
				) : null}
				{room.phase === "closed" ? (
					<SummaryPhase
						room={room}
						results={results.data}
						decisions={decisions.data}
						members={members.data}
					/>
				) : null}
			</div>

			{toast ? <div className="toast">{toast}</div> : null}
		</main>
	);
}

function PhaseStepper({ phase }: { phase: RoomRow["phase"] }) {
	const current = PHASES.findIndex((entry) => entry.id === phase);
	return (
		<ol className="phase-stepper" aria-label="Meeting phase">
			{PHASES.map((entry, index) => (
				<li
					key={entry.id}
					className={
						entry.id === phase
							? "current"
							: index < current
								? "complete"
								: "upcoming"
					}
				>
					<span>{index + 1}</span>
					{entry.label}
				</li>
			))}
		</ol>
	);
}

function SyncBadge({ status, synced }: { status: string; synced: boolean }) {
	const live = synced;
	return (
		<span className={live ? "sync-badge live" : "sync-badge reconnecting"}>
			<i />
			{live
				? "Live"
				: status === "reconnecting"
					? "Reconnecting"
					: "Connecting"}
		</span>
	);
}

function PresenceStack({
	members,
	onlineIds,
	hostUserId,
}: {
	members: MemberRow[];
	onlineIds: Set<string>;
	hostUserId: string;
}) {
	const ordered = [...members].sort((a, b) => {
		const online =
			Number(onlineIds.has(b.presence_id)) -
			Number(onlineIds.has(a.presence_id));
		if (online !== 0) return online;
		return a.name.localeCompare(b.name);
	});
	const visible = ordered.slice(0, 7);
	const online = members.filter((member) =>
		onlineIds.has(member.presence_id),
	).length;
	return (
		<div
			className="presence-stack"
			title={`${online} of ${members.length} online`}
		>
			{visible.map((member) => (
				<span
					className={
						onlineIds.has(member.presence_id)
							? "avatar online"
							: "avatar offline"
					}
					key={member.id}
					style={{ background: member.color }}
					title={`${member.name}${member.user_id === hostUserId ? " · facilitator" : ""}`}
				>
					{initials(member.name)}
					{onlineIds.has(member.presence_id) ? <i /> : null}
				</span>
			))}
			{ordered.length > visible.length ? (
				<span className="avatar more">+{ordered.length - visible.length}</span>
			) : null}
			<span className="presence-count">
				{online}/{members.length}
			</span>
		</div>
	);
}

function Countdown({ endsAt }: { endsAt: number }) {
	const [now, setNow] = useState(Date.now());
	useEffect(() => {
		const timer = setInterval(() => setNow(Date.now()), 1000);
		return () => clearInterval(timer);
	}, []);
	const left = Math.max(0, endsAt - now);
	const seconds = Math.floor(left / 1000);
	const minutes = Math.floor(seconds / 60);
	const value = `${minutes}:${String(seconds % 60).padStart(2, "0")}`;
	if (left === 0) return <span className="countdown done">Time&apos;s up</span>;
	return (
		<span className={left < 60_000 ? "countdown urgent" : "countdown"}>
			{value} left
		</span>
	);
}

function ReadOnlyNote() {
	return (
		<section className="empty-state">
			<h2>Voting is live</h2>
			<p>The results will appear here when the facilitator closes the vote.</p>
		</section>
	);
}

function CollectPhase({
	room,
	cards,
	host,
	publish,
	notify,
}: {
	room: RoomRow;
	cards: CardRow[];
	host: boolean;
	publish: (data: PresenceUser) => Promise<void>;
	notify: (message: string) => void;
}) {
	const lanes = lanesFor(room.template);
	const [lane, setLane] = useState(lanes[0]);
	const [text, setText] = useState("");
	const [busy, setBusy] = useState(false);
	const addCard = useAction("add_card");
	const removeCard = useAction("remove_card");
	const startVote = useAction("start_vote");
	const [duration, setDuration] = useState(5);
	const [starting, setStarting] = useState(false);

	async function submit() {
		const value = text.trim();
		if (!value || busy) return;
		setBusy(true);
		try {
			await addCard({ lane, text: value });
			setText("");
			void publish({ typing: false }).catch(() => {});
		} catch (error) {
			notify(error instanceof Error ? error.message : "Could not add the idea");
		} finally {
			setBusy(false);
		}
	}

	async function remove(cardId: string) {
		try {
			await removeCard({ card_id: cardId });
		} catch (error) {
			notify(
				error instanceof Error ? error.message : "Could not remove the idea",
			);
		}
	}

	async function start() {
		if (starting) return;
		setStarting(true);
		try {
			await startVote({ duration_ms: duration * 60_000 });
		} catch (error) {
			notify(
				error instanceof Error ? error.message : "Could not start the vote",
			);
		} finally {
			setStarting(false);
		}
	}

	return (
		<section className="phase collect-phase">
			<div className="phase-intro">
				<div>
					<p className="eyebrow">Collect</p>
					<h2>What should the room look at?</h2>
					<p>
						Cards are anonymous. Add one idea per card, then the facilitator
						starts the vote.
					</p>
				</div>
				<div className="phase-stat">
					<strong>{cards.length}</strong>
					<span>ideas</span>
				</div>
			</div>

			<div className="composer">
				<select
					value={lane}
					onChange={(event) => setLane(event.target.value)}
					aria-label="Idea lane"
				>
					{lanes.map((value) => (
						<option key={value} value={value}>
							{value}
						</option>
					))}
				</select>
				<textarea
					value={text}
					onChange={(event) => {
						setText(event.target.value);
						void publish({ typing: event.target.value.length > 0 }).catch(
							() => {},
						);
					}}
					onBlur={() => void publish({ typing: false }).catch(() => {})}
					onKeyDown={(event) => {
						if (event.key === "Enter" && !event.shiftKey) {
							event.preventDefault();
							void submit();
						}
					}}
					maxLength={280}
					placeholder="One idea, in one sentence…"
					rows={2}
				/>
				<button
					type="button"
					className="primary"
					onClick={() => void submit()}
					disabled={busy}
				>
					{busy ? "Adding…" : "Add idea"}
				</button>
			</div>

			<div className="lanes">
				{lanes.map((value) => (
					<div className="lane" key={value}>
						<div className="lane-heading">
							<h3>{value}</h3>
							<span>{cards.filter((card) => card.lane === value).length}</span>
						</div>
						<div className="lane-cards">
							{cards
								.filter((card) => card.lane === value)
								.map((card) => (
									<article className="idea-card" key={card.id}>
										<p>{card.text}</p>
										{host ? (
											<button
												type="button"
												className="remove-card"
												title="Remove idea"
												aria-label="Remove idea"
												onClick={() => void remove(card.id)}
											>
												×
											</button>
										) : null}
									</article>
								))}
							{cards.every((card) => card.lane !== value) ? (
								<p className="lane-empty">Nothing here yet.</p>
							) : null}
						</div>
					</div>
				))}
			</div>

			<div className="facilitator-bar">
				<div>
					<strong>
						{host ? "Ready to vote?" : "Waiting for the facilitator"}
					</strong>
					<span>
						{host
							? "Cards freeze when the vote starts."
							: "You can keep adding ideas until the vote starts."}
					</span>
				</div>
				{host ? (
					<div className="facilitator-actions">
						<select
							value={duration}
							onChange={(event) => setDuration(Number(event.target.value))}
							aria-label="Vote duration"
						>
							<option value={3}>3 minutes</option>
							<option value={5}>5 minutes</option>
							<option value={10}>10 minutes</option>
						</select>
						<button
							type="button"
							className="primary"
							onClick={() => void start()}
							disabled={starting || cards.length === 0}
						>
							{starting ? "Starting…" : "Start voting"}
						</button>
					</div>
				) : null}
			</div>
		</section>
	);
}

function VotePhase({
	room,
	cards,
	session,
	host,
	notify,
	publish,
}: {
	room: RoomRow;
	cards: CardRow[];
	session: RoomSession;
	host: boolean;
	notify: (message: string) => void;
	publish: (data: PresenceUser) => Promise<void>;
}) {
	const budgetState = useListen(["budgets", session.memberId, "votes_left"]);
	const votesLeft =
		typeof budgetState.value === "number"
			? budgetState.value
			: room.vote_budget;
	const ballots = useQuery("ballots", {
		where: { room_code: room.room_code, round: room.round },
	});
	const cast = useAction("cast_vote");
	const retract = useAction("retract_vote");
	const extend = useAction("extend_vote");
	const close = useAction("close_vote");
	const [busyCard, setBusyCard] = useState<string | null>(null);
	const [closing, setClosing] = useState(false);

	const counts = new Map(
		ballots.data.map((ballot) => [ballot.card_id, ballot.count]),
	);
	const possible = possibleVotes(room);
	const progress =
		possible > 0 ? Math.min(100, (room.votes_cast / possible) * 100) : 0;
	const lanes = lanesFor(room.template);

	useEffect(() => {
		void publish({ done: votesLeft === 0 }).catch(() => {});
	}, [publish, votesLeft]);

	async function vote(cardId: string, direction: 1 | -1) {
		if (busyCard) return;
		const count = counts.get(cardId) ?? 0;
		if (direction === 1 && (votesLeft < 1 || count >= room.max_per_card))
			return;
		if (direction === -1 && count < 1) return;
		setBusyCard(cardId);
		try {
			await (direction === 1 ? cast : retract)({ card_id: cardId });
		} catch (error) {
			notify(
				error instanceof Error ? error.message : "Could not record the vote",
			);
		} finally {
			setBusyCard(null);
		}
	}

	async function extendVote() {
		try {
			await extend({ duration_ms: 60_000 });
			notify("One minute added");
		} catch (error) {
			notify(
				error instanceof Error ? error.message : "Could not extend the vote",
			);
		}
	}

	async function closeVote() {
		if (closing) return;
		if (!window.confirm("Close voting and reveal the results to everyone?"))
			return;
		setClosing(true);
		try {
			await close({});
		} catch (error) {
			notify(
				error instanceof Error ? error.message : "Could not close the vote",
			);
		} finally {
			setClosing(false);
		}
	}

	return (
		<section className="phase vote-phase">
			<div className="vote-banner">
				<div className="vote-budget">
					<p className="eyebrow">Your budget</p>
					<strong>
						{votesLeft} <span>of {room.vote_budget} votes left</span>
					</strong>
					<div className="budget-dots" aria-hidden="true">
						{Array.from({ length: room.vote_budget }, (_, index) => (
							<i
								key={`budget-dot-${index}`}
								className={index < votesLeft ? "filled" : ""}
							/>
						))}
					</div>
				</div>
				<div className="vote-progress">
					<div className="progress-label">
						<span>
							{room.votes_cast} of {possible} votes cast
						</span>
						<span>{Math.round(progress)}%</span>
					</div>
					<div className="progress-track">
						<div style={{ width: `${progress}%` }} />
					</div>
					<p className="blind-note">
						Blind vote. Nothing is tallied on screen until the facilitator
						closes the round.
					</p>
				</div>
			</div>

			<div className="lanes vote-lanes">
				{lanes.map((lane) => (
					<div className="lane" key={lane}>
						<div className="lane-heading">
							<h3>{lane}</h3>
							<span>{cards.filter((card) => card.lane === lane).length}</span>
						</div>
						<div className="lane-cards">
							{cards
								.filter((card) => card.lane === lane)
								.map((card) => {
									const count = counts.get(card.id) ?? 0;
									return (
										<article className="idea-card vote-card" key={card.id}>
											<p>{card.text}</p>
											<div className="vote-controls">
												<div className="my-dots" aria-hidden="true">
													{Array.from(
														{ length: room.max_per_card },
														(_, index) => (
															<i
																key={`my-dot-${index}`}
																className={index < count ? "filled" : ""}
															/>
														),
													)}
												</div>
												<div className="vote-buttons">
													<button
														type="button"
														className="round"
														aria-label="Remove one vote"
														disabled={count < 1 || busyCard !== null}
														onClick={() => void vote(card.id, -1)}
													>
														−
													</button>
													<span>{count}</span>
													<button
														type="button"
														className="round"
														aria-label="Add one vote"
														disabled={
															votesLeft < 1 ||
															count >= room.max_per_card ||
															busyCard !== null
														}
														onClick={() => void vote(card.id, 1)}
													>
														+
													</button>
												</div>
											</div>
										</article>
									);
								})}
							{cards.every((card) => card.lane !== lane) ? (
								<p className="lane-empty">Nothing to vote on here.</p>
							) : null}
						</div>
					</div>
				))}
			</div>

			<div className="facilitator-bar">
				<div>
					<strong>
						{host ? "Facilitator controls" : "The facilitator closes the vote"}
					</strong>
					<span>
						Max {room.max_per_card} votes per idea. Changes are allowed until
						close.
					</span>
				</div>
				{host ? (
					<div className="facilitator-actions">
						<button
							type="button"
							className="ghost"
							onClick={() => void extendVote()}
						>
							+1 minute
						</button>
						<button
							type="button"
							className="primary"
							onClick={() => void closeVote()}
							disabled={closing}
						>
							{closing ? "Revealing…" : "Close and reveal"}
						</button>
					</div>
				) : null}
			</div>
		</section>
	);
}

function ResultsPhase({
	room,
	results,
	host,
	notify,
}: {
	room: RoomRow;
	results: ResultRow[];
	host: boolean;
	notify: (message: string) => void;
}) {
	const startDiscussion = useAction("start_discussion");
	const [busy, setBusy] = useState(false);
	const max = Math.max(1, ...results.map((result) => result.votes));
	const total = results.reduce((sum, result) => sum + result.votes, 0);
	const balanced = total === room.votes_cast;

	async function discuss() {
		setBusy(true);
		try {
			await startDiscussion({});
		} catch (error) {
			notify(
				error instanceof Error
					? error.message
					: "Could not start the discussion",
			);
		} finally {
			setBusy(false);
		}
	}

	return (
		<section className="phase results-phase">
			<div className="results-hero">
				<p className="eyebrow">The reveal</p>
				<h2>The room has decided.</h2>
				<p>
					{room.votes_cast} votes from {room.members_count} participants. The
					tally is frozen in the same commit that ends the round.
				</p>
				<span className={balanced ? "ledger-badge ok" : "ledger-badge bad"}>
					{balanced ? "Ledger balanced" : "Ledger mismatch"} · {total} votes
				</span>
			</div>

			<div className="result-list">
				{results.map((result, index) => (
					<article
						className={index < 3 ? "result-row top" : "result-row"}
						key={result.id}
						style={{ animationDelay: `${index * 60}ms` }}
					>
						<span className="result-rank">{result.rank}</span>
						<div className="result-content">
							<div className="result-text">
								<strong>{result.text}</strong>
								<span>{result.lane}</span>
							</div>
							<div className="result-bar-track">
								<div
									className="result-bar"
									style={{ width: `${(result.votes / max) * 100}%` }}
								/>
							</div>
						</div>
						<span className="result-votes">
							{result.votes}
							<small> votes</small>
						</span>
					</article>
				))}
				{results.length === 0 ? (
					<p className="lane-empty">No topics were collected.</p>
				) : null}
			</div>

			<div className="facilitator-bar">
				<div>
					<strong>
						{host
							? "Ready to discuss?"
							: "The facilitator opens the discussion"}
					</strong>
					<span>Start with the top topic, then work down the list.</span>
				</div>
				{host ? (
					<button
						type="button"
						className="primary"
						onClick={() => void discuss()}
						disabled={busy || results.length === 0}
					>
						{busy ? "Opening…" : "Discuss top topics"}
					</button>
				) : null}
			</div>
		</section>
	);
}

function DiscussPhase({
	room,
	results,
	decisions,
	members,
	session,
	host,
	notify,
}: {
	room: RoomRow;
	results: ResultRow[];
	decisions: DecisionRow[];
	members: MemberRow[];
	session: RoomSession;
	host: boolean;
	notify: (message: string) => void;
}) {
	const focusTopic = useAction("focus_topic");
	const addDecision = useAction("add_decision");
	const closeRoom = useAction("close_room");
	const [text, setText] = useState("");
	const [busy, setBusy] = useState(false);
	const [closing, setClosing] = useState(false);

	const focus =
		results.find((result) => result.card_id === room.focus_card_id) ??
		results[0];
	const focusIndex = focus
		? results.findIndex((result) => result.card_id === focus.card_id)
		: -1;
	const focusDecisions = decisions.filter(
		(decision) => decision.card_id === focus?.card_id,
	);

	async function move(direction: 1 | -1) {
		const next = results[focusIndex + direction];
		if (!next) return;
		try {
			await focusTopic({ card_id: next.card_id });
		} catch (error) {
			notify(
				error instanceof Error ? error.message : "Could not change the topic",
			);
		}
	}

	async function submitDecision() {
		const value = text.trim();
		if (!value || busy) return;
		setBusy(true);
		try {
			await addDecision({ text: value });
			setText("");
		} catch (error) {
			notify(
				error instanceof Error ? error.message : "Could not add the decision",
			);
		} finally {
			setBusy(false);
		}
	}

	async function closeMeeting() {
		if (!window.confirm("Close the meeting and publish the summary?")) return;
		setClosing(true);
		try {
			await closeRoom({});
		} catch (error) {
			notify(
				error instanceof Error ? error.message : "Could not close the meeting",
			);
		} finally {
			setClosing(false);
		}
	}

	return (
		<section className="phase discuss-phase">
			<div className="discuss-layout">
				<aside className="topic-list">
					<p className="eyebrow">Topics by votes</p>
					{results.map((result) => (
						<button
							type="button"
							key={result.id}
							className={
								result.card_id === focus?.card_id ? "topic active" : "topic"
							}
							onClick={() => {
								if (!host) return;
								void focusTopic({ card_id: result.card_id }).catch(
									(error: unknown) =>
										notify(
											error instanceof Error
												? error.message
												: "Could not focus",
										),
								);
							}}
							disabled={!host}
						>
							<span>{result.rank}</span>
							<strong>{result.text}</strong>
							<em>{result.votes}</em>
						</button>
					))}
				</aside>

				<div className="discuss-main">
					{focus ? (
						<>
							<article className="focus-card">
								<p className="eyebrow">{focus.lane}</p>
								<h2>{focus.text}</h2>
								<span className="focus-votes">{focus.votes} votes</span>
							</article>

							<div className="decision-box">
								<h3>Decisions & next steps</h3>
								{focusDecisions.length === 0 ? (
									<p className="lane-empty">
										No decision recorded for this topic yet.
									</p>
								) : (
									<ul className="decision-list">
										{focusDecisions.map((decision) => (
											<li key={decision.id}>
												<p>{decision.text}</p>
												<span>— {decision.author_name}</span>
											</li>
										))}
									</ul>
								)}
								{!session.readOnly && session.memberId ? (
									<div className="decision-form">
										<textarea
											value={text}
											onChange={(event) => setText(event.target.value)}
											placeholder="What will we do about this?"
											maxLength={280}
											rows={2}
										/>
										<button
											type="button"
											className="secondary"
											onClick={() => void submitDecision()}
											disabled={busy || !text.trim()}
										>
											{busy ? "Saving…" : "Add decision"}
										</button>
									</div>
								) : null}
							</div>
						</>
					) : (
						<ReadOnlyNote />
					)}

					<div className="facilitator-bar">
						<div>
							<strong>
								{host ? "Facilitator controls" : "The facilitator leads"}
							</strong>
							<span>
								{focus
									? `Topic ${focusIndex + 1} of ${results.length}`
									: "No topic selected"}
							</span>
						</div>
						{host ? (
							<div className="facilitator-actions">
								<button
									type="button"
									className="ghost"
									onClick={() => void move(-1)}
									disabled={focusIndex <= 0}
								>
									Previous
								</button>
								<button
									type="button"
									className="ghost"
									onClick={() => void move(1)}
									disabled={focusIndex < 0 || focusIndex >= results.length - 1}
								>
									Next
								</button>
								<button
									type="button"
									className="primary"
									onClick={() => void closeMeeting()}
									disabled={closing}
								>
									{closing ? "Closing…" : "Close meeting"}
								</button>
							</div>
						) : null}
					</div>
				</div>
			</div>
			<p className="attendee-line">
				{members.length} participants · {decisions.length} decisions recorded
			</p>
		</section>
	);
}

function SummaryPhase({
	room,
	results,
	decisions,
	members,
}: {
	room: RoomRow;
	results: ResultRow[];
	decisions: DecisionRow[];
	members: MemberRow[];
}) {
	function download(name: string, type: string, content: string) {
		const blob = new Blob([content], { type });
		const url = URL.createObjectURL(blob);
		const anchor = document.createElement("a");
		anchor.href = url;
		anchor.download = name;
		anchor.click();
		URL.revokeObjectURL(url);
	}

	function markdown() {
		const lines = [
			`# ${room.title}`,
			"",
			`Room ${room.room_code} · ${members.length} participants · ${room.votes_cast} votes`,
			"",
			"## Priorities",
			...results.map(
				(result) =>
					`${result.rank}. ${result.text} — ${result.votes} votes (${result.lane})`,
			),
			"",
			"## Decisions",
			...(decisions.length
				? decisions.map(
						(decision) => `- ${decision.text} (${decision.author_name})`,
					)
				: ["- No decisions recorded."]),
			"",
		];
		return lines.join("\n");
	}

	function csv() {
		const csvEscape = (value: string) => {
			const safe = /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
			return `"${safe.replaceAll('"', '""')}"`;
		};
		return [
			"rank,votes,lane,text",
			...results.map((result) =>
				[result.rank, result.votes, result.lane, result.text]
					.map((value) => csvEscape(String(value)))
					.join(","),
			),
		].join("\n");
	}

	return (
		<section className="phase summary-phase">
			<div className="summary-hero">
				<p className="eyebrow">Meeting summary</p>
				<h2>{room.title}</h2>
				<p>
					{members.length} participants · {room.votes_cast} votes ·{" "}
					{decisions.length} decisions
				</p>
				<div className="summary-actions">
					<button
						type="button"
						className="secondary"
						onClick={() => download("quorum.md", "text/markdown", markdown())}
					>
						Download Markdown
					</button>
					<button
						type="button"
						className="ghost"
						onClick={() => download("quorum.csv", "text/csv", csv())}
					>
						Download CSV
					</button>
				</div>
			</div>

			<div className="summary-grid">
				<div className="summary-card">
					<h3>Priorities</h3>
					<ol className="summary-topics">
						{results.slice(0, 5).map((result) => (
							<li key={result.id}>
								<strong>{result.text}</strong>
								<span>{result.votes} votes</span>
							</li>
						))}
					</ol>
				</div>
				<div className="summary-card">
					<h3>Decisions</h3>
					{decisions.length === 0 ? (
						<p className="lane-empty">No decisions recorded.</p>
					) : (
						<ul className="summary-decisions">
							{decisions.map((decision) => (
								<li key={decision.id}>
									<p>{decision.text}</p>
									<span>{decision.author_name}</span>
								</li>
							))}
						</ul>
					)}
				</div>
				<div className="summary-card">
					<h3>Participants</h3>
					<ul className="attendee-list">
						{members.map((member) => (
							<li key={member.id}>
								<span
									className="avatar small"
									style={{ background: member.color }}
								>
									{initials(member.name)}
								</span>
								{member.name}
								{member.role === "host" ? <em>facilitator</em> : null}
							</li>
						))}
					</ul>
				</div>
			</div>

			<div className="summary-footer">
				<a className="primary" href="/">
					Start another room
				</a>
				<span>
					{room.demo
						? "This was a seeded demo room. The votes came from sample members."
						: "The result is frozen. Nothing on this page will change."}
				</span>
			</div>
		</section>
	);
}
