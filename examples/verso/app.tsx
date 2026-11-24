import { useEffect, useState } from "react";
import {
	fallbackColor,
	joinWorkspace,
	leaveWorkspace,
	storedIdentity,
	type VersoSession,
} from "./session";
import { COLORS, type Identity } from "./shared";
import { Workspace } from "./workspace";

export function App() {
	const [session, setSession] = useState<VersoSession | null>(null);
	const [restoring, setRestoring] = useState(true);

	useEffect(() => {
		const identity = storedIdentity();
		if (!identity) {
			setRestoring(false);
			return;
		}
		joinWorkspace(identity)
			.then(setSession)
			.catch(() => {})
			.finally(() => setRestoring(false));
	}, []);

	const onLeave = () => {
		if (session) leaveWorkspace(session);
		setSession(null);
		location.hash = "";
	};

	if (restoring) {
		return (
			<div className="gate">
				<p className="muted">Opening your workspace…</p>
			</div>
		);
	}

	if (!session) return <Join onJoined={setSession} />;

	return <Workspace session={session} onLeave={onLeave} />;
}

function Join({ onJoined }: { onJoined: (session: VersoSession) => void }) {
	const [email, setEmail] = useState("");
	const [name, setName] = useState("");
	const [color, setColor] = useState(fallbackColor);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);

	const submit = async (event: React.FormEvent) => {
		event.preventDefault();
		if (busy) return;
		setBusy(true);
		setError(null);
		try {
			const identity: Identity = {
				email: email.trim(),
				name: name.trim() || email.trim().split("@")[0] || "Someone",
				color,
			};
			onJoined(await joinWorkspace(identity));
		} catch (cause) {
			setError(cause instanceof Error ? cause.message : "Could not join");
			setBusy(false);
		}
	};

	return (
		<div className="gate">
			<form className="gate__card" onSubmit={submit}>
				<p className="eyebrow">a very small workspace</p>
				<h1 className="wordmark">verso</h1>
				<p className="gate__blurb">
					Pages are rows. Bodies are Yjs documents. Type in the same page from
					two windows and watch the text merge.
				</p>
				<label className="field">
					<span>Email</span>
					<input
						type="email"
						required
						autoComplete="off"
						placeholder="you@example.com"
						value={email}
						onChange={(event) => setEmail(event.target.value)}
					/>
				</label>
				<label className="field">
					<span>Display name</span>
					<input
						type="text"
						maxLength={64}
						placeholder="Ada"
						value={name}
						onChange={(event) => setName(event.target.value)}
					/>
				</label>
				<div className="field">
					<span>Caret color</span>
					<div className="swatches">
						{COLORS.map((value) => (
							<button
								key={value}
								type="button"
								aria-label={`Color ${value}`}
								className={`swatch${value === color ? " is-active" : ""}`}
								style={{ backgroundColor: value }}
								onClick={() => setColor(value)}
							/>
						))}
					</div>
				</div>
				{error ? <p className="notice notice--error">{error}</p> : null}
				<button type="submit" className="primary" disabled={busy}>
					{busy ? "Opening…" : "Enter workspace"}
				</button>
				<p className="fineprint">
					Identity here is claimed, not verified: any email opens the same
					workspace under that name. Two tabs with two emails are two people. A
					real app swaps this one endpoint for passwordless login.
				</p>
			</form>
		</div>
	);
}
