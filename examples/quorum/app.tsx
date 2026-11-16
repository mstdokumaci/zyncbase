// biome-ignore-all lint/complexity/noExcessiveCognitiveComplexity: the landing composes create, join, and demo entry points.
import { useEffect, useState } from "react";
import { Room } from "./room";
import { connectRoom, type RoomSession, savedName, saveName } from "./session";
import {
	clampName,
	clampTitle,
	DEFAULT_MAX_PER_CARD,
	DEFAULT_VOTE_BUDGET,
	generateRoomCode,
	isRoomCode,
	normalizeRoomCode,
	TEMPLATES,
	type TemplateId,
} from "./shared";

function codeFromPath(path: string): string | null {
	const match = path.match(/^\/r\/([a-z0-9]+)\/?$/);
	return match ? normalizeRoomCode(match[1]) : null;
}

function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : "Something went wrong";
}

export function App() {
	const [path, setPath] = useState(location.pathname);
	const [session, setSession] = useState<RoomSession | null>(null);

	useEffect(() => {
		const onPop = () => {
			setPath(location.pathname);
			setSession((current) => {
				if (current) void current.client.disconnect();
				return null;
			});
		};
		window.addEventListener("popstate", onPop);
		return () => window.removeEventListener("popstate", onPop);
	}, []);

	function go(next: string) {
		history.pushState({}, "", next);
		setPath(next);
	}

	function leave() {
		if (session) void session.client.disconnect();
		setSession(null);
		go("/");
	}

	if (session) {
		return <Room session={session} onLeave={leave} />;
	}

	const code = codeFromPath(path);
	if (code) {
		return (
			<JoinGate
				code={code}
				onBack={() => go("/")}
				onJoin={(joined) => {
					setSession(joined);
					go(`/r/${joined.code}`);
				}}
			/>
		);
	}

	return (
		<Landing
			onCreate={(created) => {
				setSession(created);
				go(`/r/${created.code}`);
			}}
			onJoin={(joinCode) => go(`/r/${joinCode}`)}
		/>
	);
}

async function createRoomSession(input: {
	name: string;
	title: string;
	template: TemplateId;
	voteBudget: number;
	maxPerCard: number;
	demo: boolean;
}): Promise<RoomSession> {
	const code = generateRoomCode();
	const client = await connectRoom(code);
	try {
		const created = await client.actions.call("create_room", {
			name: input.name,
			title: input.title,
			template: input.template,
			vote_budget: input.voteBudget,
			max_per_card: input.maxPerCard,
			demo: input.demo,
		});
		return {
			client,
			code,
			roomId: created.room_id,
			memberId: created.member_id,
			userId: created.user_id,
			presenceId: created.presence_id,
			readOnly: false,
			name: input.name,
		};
	} catch (error) {
		await client.disconnect();
		throw error;
	}
}

function Landing({
	onCreate,
	onJoin,
}: {
	onCreate: (session: RoomSession) => void;
	onJoin: (code: string) => void;
}) {
	const [name, setName] = useState(savedName());
	const [title, setTitle] = useState("Sprint 42 retro");
	const [template, setTemplate] = useState<TemplateId>("retro");
	const [budget, setBudget] = useState(DEFAULT_VOTE_BUDGET);
	const [perCard, setPerCard] = useState(DEFAULT_MAX_PER_CARD);
	const [joinCode, setJoinCode] = useState("");
	const [busy, setBusy] = useState<"create" | "demo" | null>(null);
	const [error, setError] = useState<string | null>(null);

	async function create(demo: boolean) {
		const person = clampName(name) || (demo ? "Host" : "");
		const roomTitle = demo ? "Demo: Sprint 42" : clampTitle(title);
		if (!person) return setError("Enter your name first.");
		if (!roomTitle) return setError("Give the room a title.");
		setBusy(demo ? "demo" : "create");
		setError(null);
		try {
			const session = await createRoomSession({
				name: person,
				title: roomTitle,
				template: demo ? "retro" : template,
				voteBudget: budget,
				maxPerCard: Math.min(perCard, budget),
				demo,
			});
			saveName(person);
			onCreate(session);
		} catch (cause) {
			setError(errorMessage(cause));
		} finally {
			setBusy(null);
		}
	}

	function join() {
		const code = normalizeRoomCode(joinCode);
		if (!isRoomCode(code)) return setError("Enter a valid room code.");
		onJoin(code);
	}

	return (
		<main className="landing">
			<header className="landing-nav">
				<span className="brand">
					<span className="brand-dot" />
					Quorum
				</span>
				<span className="tagline">
					Decide together, without the loudest voice winning.
				</span>
			</header>

			<section className="hero">
				<div className="hero-copy">
					<h1>
						One room.
						<br />
						Five votes.
						<br />A decision.
					</h1>
					<p>
						Collect ideas anonymously, spend a small budget of votes, and reveal
						the room&apos;s priorities all at once. No accounts, no integrations
						— just a link and a facilitator.
					</p>
					<ol className="steps">
						<li>
							<span>1</span> Collect ideas
						</li>
						<li>
							<span>2</span> Vote in private
						</li>
						<li>
							<span>3</span> Reveal and decide
						</li>
					</ol>
				</div>
				<div className="hero-art" aria-hidden="true">
					<div className="paper-card paper-a">
						<span className="paper-lane">Start</span>
						<strong>Ship the small thing first</strong>
						<div className="paper-dots">
							<i />
							<i />
							<i />
						</div>
					</div>
					<div className="paper-card paper-b">
						<span className="paper-lane">Stop</span>
						<strong>Status updates that could be a message</strong>
						<div className="paper-dots">
							<i />
							<i />
						</div>
					</div>
					<div className="paper-card paper-c">
						<span className="paper-lane">Continue</span>
						<strong>Pairing on the ambiguous work</strong>
						<div className="paper-dots">
							<i />
							<i />
							<i />
							<i />
						</div>
					</div>
					<div className="reveal-chip">revealed</div>
				</div>
			</section>

			<section className="landing-panels">
				<div className="panel create-panel">
					<h2>Start a room</h2>
					<label>
						Your name
						<input
							value={name}
							onChange={(event) => setName(event.target.value)}
							maxLength={24}
							placeholder="Ada"
						/>
					</label>
					<label>
						Room title
						<input
							value={title}
							onChange={(event) => setTitle(event.target.value)}
							maxLength={80}
							placeholder="Sprint 42 retro"
						/>
					</label>
					<div className="field-row">
						<label>
							Template
							<select
								value={template}
								onChange={(event) =>
									setTemplate(event.target.value as TemplateId)
								}
							>
								{Object.entries(TEMPLATES).map(([id, value]) => (
									<option key={id} value={id}>
										{value.label}
									</option>
								))}
							</select>
						</label>
						<label>
							Votes each
							<input
								type="number"
								min={1}
								max={10}
								value={budget}
								onChange={(event) => setBudget(Number(event.target.value))}
							/>
						</label>
						<label>
							Max per idea
							<input
								type="number"
								min={1}
								max={budget}
								value={perCard}
								onChange={(event) => setPerCard(Number(event.target.value))}
							/>
						</label>
					</div>
					{error ? <p className="form-error">{error}</p> : null}
					<div className="panel-actions">
						<button
							type="button"
							className="primary"
							onClick={() => void create(false)}
							disabled={busy !== null}
						>
							{busy === "create" ? "Opening…" : "Create room"}
						</button>
						<button
							type="button"
							className="ghost"
							onClick={() => void create(true)}
							disabled={busy !== null}
						>
							{busy === "demo" ? "Seeding…" : "Try the demo"}
						</button>
					</div>
					<p className="fine-print">
						The demo seeds four sample members and a few ideas so you can run
						the full reveal on your own.
					</p>
				</div>

				<div className="panel join-panel">
					<h2>Join a room</h2>
					<p>Someone sent you a code. Enter it, or open their link directly.</p>
					<label>
						Room code
						<input
							value={joinCode}
							onChange={(event) => setJoinCode(event.target.value)}
							placeholder="k3m9x2qp"
							maxLength={12}
							onKeyDown={(event) => {
								if (event.key === "Enter") join();
							}}
						/>
					</label>
					<button type="button" className="secondary" onClick={join}>
						Join room
					</button>
					<hr />
					<h3>What makes it different</h3>
					<ul className="feature-list">
						<li>Votes are private until the reveal.</li>
						<li>Every member gets exactly the same budget.</li>
						<li>The result is frozen, not recalculated.</li>
					</ul>
				</div>
			</section>
			<footer className="landing-footer">
				<span>Quorum · an example built on ZyncBase</span>
				<span>No accounts. One link. One decision.</span>
			</footer>
		</main>
	);
}

function JoinGate({
	code,
	onBack,
	onJoin,
}: {
	code: string;
	onBack: () => void;
	onJoin: (session: RoomSession) => void;
}) {
	const [name, setName] = useState(savedName());
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);

	async function join() {
		if (busy) return;
		const person = clampName(name);
		if (!person) return setError("Enter your name first.");
		setBusy(true);
		setError(null);
		const client = await connectRoom(code).catch((cause: unknown) => {
			setError(errorMessage(cause));
			return null;
		});
		if (!client) {
			setBusy(false);
			return;
		}
		try {
			const joined = await client.actions.call("join_room", { name: person });
			saveName(person);
			onJoin({
				client,
				code,
				roomId: joined.room_id,
				memberId: joined.member_id,
				userId: joined.user_id,
				presenceId: joined.presence_id,
				readOnly: joined.read_only,
				name: person,
			});
		} catch (cause) {
			await client.disconnect();
			setError(errorMessage(cause));
		} finally {
			setBusy(false);
		}
	}

	return (
		<main className="join-gate">
			<div className="join-card">
				<span className="brand">
					<span className="brand-dot" />
					Quorum
				</span>
				<h1>Join the room</h1>
				<p className="room-code-chip">{code}</p>
				<label>
					Your name
					<input
						value={name}
						onChange={(event) => setName(event.target.value)}
						onKeyDown={(event) => {
							if (event.key === "Enter") void join();
						}}
						maxLength={24}
						placeholder="Ada"
					/>
				</label>
				{error ? <p className="form-error">{error}</p> : null}
				<div className="panel-actions">
					<button
						type="button"
						className="primary"
						onClick={() => void join()}
						disabled={busy}
					>
						{busy ? "Joining…" : "Join room"}
					</button>
					<button
						type="button"
						className="ghost"
						onClick={onBack}
						disabled={busy}
					>
						Back
					</button>
				</div>
				<p className="fine-print">
					Your votes are private. The room sees the total, never your picks.
				</p>
			</div>
		</main>
	);
}
