import { ZyncBaseYjsProvider } from "@zyncbase/client/yjs";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import * as Y from "yjs";
import { useClient, useQuery } from "./bindings";
import {
	CLEARED_CURSOR,
	cursorFromPresence,
	cursorToPresence,
} from "./editor/cursor-presence";
import { DocEditor, type PageProvider } from "./editor/DocEditor";
import { HistoryPanel } from "./history";
import { createPage, positionAtEnd, renamePage, siblingsOf } from "./pages";
import type { VersoSession } from "./session";
import {
	type ChangeRow,
	collections,
	ICONS,
	initials,
	type PageRow,
	type People,
	pageIcon,
	pageNamespace,
	pageTitle,
	relativeTime,
	type UserRow,
	userOf,
} from "./shared";

interface OpenedPage {
	doc: Y.Doc;
	provider: PageProvider;
}

interface AwarenessUser {
	clientId: number;
	name: string;
	color: string;
}

function useAwarenessUsers(provider: PageProvider | null): AwarenessUser[] {
	const [users, setUsers] = useState<AwarenessUser[]>([]);
	useEffect(() => {
		const awareness = provider?.awareness;
		if (!awareness) {
			setUsers([]);
			return;
		}
		const update = () => {
			const next: AwarenessUser[] = [];
			for (const [clientId, state] of awareness.getStates()) {
				const user = (state as { user?: { name?: string; color?: string } })
					.user;
				if (typeof user?.name === "string") {
					next.push({
						clientId,
						name: user.name,
						color: user.color ?? "#999999",
					});
				}
			}
			setUsers(next);
		};
		update();
		awareness.on("change", update);
		return () => awareness.off("change", update);
	}, [provider]);
	return users;
}

export interface PageScreenProps {
	session: VersoSession;
	page: PageRow | undefined;
	pages: readonly PageRow[];
	byId: Map<string, PageRow>;
	people: People;
	onNavigate: (pageId: string | null) => void;
}

export function PageScreen({
	session,
	page,
	pages,
	byId,
	people,
	onNavigate,
}: PageScreenProps) {
	const client = useClient();
	const pageId = page?.id ?? "";
	const [opened, setOpened] = useState<OpenedPage | null>(null);
	const [openError, setOpenError] = useState<string | null>(null);
	const [title, setTitle] = useState(page?.title ?? "");
	const [iconOpen, setIconOpen] = useState(false);
	const [historyOpen, setHistoryOpen] = useState(false);
	const pendingTitle = useRef<ReturnType<typeof setTimeout> | null>(null);
	const titleFocused = useRef(false);
	const pagesRef = useRef(pages);
	pagesRef.current = pages;

	// The change log records the writer's id, so the newest row names the last
	// person who touched the body. Title and icon writes do not create rows.
	const changes = useQuery("page_changes", {
		where: { document_id: pageId },
		orderBy: [{ created_at: "desc" }],
		limit: 1,
	});
	const lastChange = (changes.data as ChangeRow[])[0];
	const creator = userOf(page?.owner_id, people);
	const editor = userOf(lastChange?.owner_id, people);

	const onError = useCallback((error: unknown) => {
		setOpenError(error instanceof Error ? error.message : String(error));
	}, []);

	// One provider per open page. Presence follows the page, so the awareness
	// namespace is switched before the provider is built.
	useEffect(() => {
		if (!pageId) return;
		let cancelled = false;
		let provider: PageProvider | null = null;
		titleFocused.current = false;
		setOpened(null);
		setOpenError(null);
		(async () => {
			await client.setPresenceNamespace(pageNamespace(pageId));
			if (cancelled) return;
			const doc = new Y.Doc();
			const created: PageProvider = new ZyncBaseYjsProvider(
				client,
				pageId,
				doc,
				{
					collections,
					awareness: {
						namespace: pageNamespace(pageId),
						toPresence: (state) => {
							const user = state.user;
							const cursor = cursorToPresence(state.cursor) ?? CLEARED_CURSOR;
							return {
								...(user ? { user } : {}),
								cursor,
							};
						},
						fromPresence: (data) => {
							const user = data.user;
							const cursor = cursorFromPresence(data.cursor);
							return {
								...(user ? { user } : {}),
								...(cursor ? { cursor } : {}),
							};
						},
					},
				},
			);
			provider = created;
			created.on("error", (error) => {
				if (!cancelled) onError(error);
			});
			await created.connect();
			if (cancelled) return;
			setOpened({ doc, provider: created });
		})().catch((error: unknown) => {
			if (!cancelled) onError(error);
		});
		return () => {
			cancelled = true;
			provider?.destroy();
			setOpened(null);
		};
	}, [client, pageId, onError]);

	useEffect(() => {
		// A late echo of an older title must not overwrite what is being typed.
		if (titleFocused.current) return;
		setTitle(page?.title ?? "");
	}, [page?.title]);

	useEffect(() => {
		return () => {
			if (pendingTitle.current) clearTimeout(pendingTitle.current);
		};
	}, []);

	const commitTitle = useCallback(
		(value: string) => {
			setTitle(value);
			if (pendingTitle.current) clearTimeout(pendingTitle.current);
			pendingTitle.current = setTimeout(() => {
				pendingTitle.current = null;
				void renamePage(client, pageId, value).catch(onError);
			}, 300);
		},
		[client, pageId, onError],
	);

	const createSubPage = useCallback(async () => {
		return createPage(client, {
			parentId: pageId,
			position: positionAtEnd(siblingsOf(pagesRef.current, pageId)),
		});
	}, [client, pageId]);

	const users = useAwarenessUsers(opened?.provider ?? null);
	// Awareness includes this client; the explicit "you" chip below is enough.
	const peers = users.filter(
		(user) => user.clientId !== opened?.provider.awareness?.clientID,
	);

	// The nearest existing ancestor, so deleting the open page lands somewhere.
	const fallback = useMemo(() => {
		const parentId = page?.parent_id;
		return parentId && byId.has(parentId) ? parentId : null;
	}, [byId, page?.parent_id]);

	if (!page) {
		return (
			<div className="empty">
				<p>That page is gone.</p>
				<button
					type="button"
					className="primary"
					onClick={() => onNavigate(fallback)}
				>
					Go back
				</button>
			</div>
		);
	}

	return (
		<div className="page">
			<div className="page__main">
				<header className="page__bar">
					<span className="page__path">{pathOf(page, byId)}</span>
					<div className="page__tools">
						<div className="avatars">
							{peers.slice(0, 4).map((user) => (
								<span
									key={user.clientId}
									className="avatar"
									style={{ backgroundColor: user.color }}
									title={user.name}
								>
									{initials(user.name)}
								</span>
							))}
							<span
								className="avatar avatar--you"
								style={{ backgroundColor: session.identity.color }}
								title={`${session.identity.name} (you)`}
							>
								{initials(session.identity.name)}
							</span>
						</div>
						<button
							type="button"
							className="ghost"
							onClick={() => setHistoryOpen((open) => !open)}
						>
							History
						</button>
					</div>
				</header>

				<div className="page__heading">
					<button
						type="button"
						className="page__icon"
						aria-label="Change icon"
						onClick={() => setIconOpen((open) => !open)}
					>
						{pageIcon(page)}
					</button>
					<input
						className="page__title"
						value={title}
						placeholder="Untitled"
						maxLength={120}
						onChange={(event) => commitTitle(event.target.value)}
						onFocus={() => {
							titleFocused.current = true;
						}}
						onBlur={() => {
							titleFocused.current = false;
							if (pendingTitle.current) {
								clearTimeout(pendingTitle.current);
								pendingTitle.current = null;
								void renamePage(client, pageId, title).catch(onError);
							}
						}}
					/>
				</div>
				<div className="page__meta">
					<MetaItem at={page.created_at} verb="Created" user={creator} />
					{lastChange?.created_at ? (
						<>
							<span className="page__meta__sep">·</span>
							<MetaItem
								at={lastChange.created_at}
								verb="Edited"
								user={editor}
							/>
						</>
					) : null}
				</div>
				{iconOpen ? (
					<div className="icon-picker">
						{ICONS.map((icon) => (
							<button
								key={icon}
								type="button"
								onClick={() => {
									setIconOpen(false);
									void client.store
										.set(["pages", pageId, "icon"], icon)
										.catch(onError);
								}}
							>
								{icon}
							</button>
						))}
					</div>
				) : null}

				{openError ? <p className="notice notice--error">{openError}</p> : null}

				{opened ? (
					<DocEditor
						doc={opened.doc}
						provider={opened.provider}
						pages={byId}
						identity={session.identity}
						onNavigate={onNavigate}
						createSubPage={createSubPage}
						onError={onError}
					/>
				) : (
					<p className="muted">Opening “{pageTitle(page)}”…</p>
				)}
			</div>

			{historyOpen ? (
				<HistoryPanel
					page={page}
					pages={byId}
					people={people}
					identity={session.identity}
					onClose={() => setHistoryOpen(false)}
					onNavigate={onNavigate}
					onError={onError}
				/>
			) : null}
		</div>
	);
}

/** One "who and when" item; the name is omitted when the owner has no profile. */
function MetaItem({
	at,
	verb,
	user,
}: {
	at: number | undefined;
	verb: "Created" | "Edited";
	user: UserRow | undefined;
}) {
	if (!at) return null;
	const who = user?.name
		? `${verb === "Created" ? `${user.name} created` : `Edited by ${user.name}`} `
		: `${verb} `;
	return (
		<span className="page__meta__item">
			{user?.name ? (
				<span
					className="avatar"
					style={{ backgroundColor: user.color ?? "#999999" }}
					title={user.name}
				>
					{initials(user.name)}
				</span>
			) : null}
			{who}
			<span title={new Date(at / 1000).toLocaleString()}>
				{relativeTime(at)}
			</span>
		</span>
	);
}

function pathOf(page: PageRow, byId: Map<string, PageRow>): string {
	const parts: string[] = [];
	let cursor: string | undefined = page.parent_id;
	const seen = new Set<string>();
	while (cursor && !seen.has(cursor)) {
		seen.add(cursor);
		const parent = byId.get(cursor);
		if (!parent) break;
		parts.unshift(pageTitle(parent));
		cursor = parent.parent_id;
	}
	return parts.join(" / ");
}
