import { useCallback, useEffect, useMemo, useState } from "react";
import {
	useClient,
	useQuery,
	useSyncStatus,
	ZyncBaseProvider,
} from "./bindings";
import { PageScreen } from "./page";
import {
	buildTree,
	createPage,
	deletePage,
	movePage,
	type PageNode,
	positionAtEnd,
	positionBetween,
	siblingsOf,
} from "./pages";
import type { VersoSession } from "./session";
import {
	type AppClient,
	ICONS,
	initials,
	type PageRow,
	pageIcon,
	pageTitle,
} from "./shared";

function hashPage(): string | null {
	const match = /^#\/(.+)$/.exec(location.hash);
	return match?.[1] ? decodeURIComponent(match[1]) : null;
}

export function Workspace({
	session,
	onLeave,
}: {
	session: VersoSession;
	onLeave: () => void;
}) {
	return (
		<ZyncBaseProvider client={session.client}>
			<WorkspaceView session={session} onLeave={onLeave} />
		</ZyncBaseProvider>
	);
}

function WorkspaceView({
	session,
	onLeave,
}: {
	session: VersoSession;
	onLeave: () => void;
}) {
	const client = useClient();
	const pagesQuery = useQuery("pages", {
		orderBy: [{ position: "asc" }],
		limit: 500,
	});
	const rows = pagesQuery.data as PageRow[];
	const tree = useMemo(() => buildTree(rows), [rows]);
	const byId = useMemo(() => new Map(rows.map((row) => [row.id, row])), [rows]);
	const [pageId, setPageId] = useState<string | null>(() => hashPage());
	const [menuId, setMenuId] = useState<string | null>(null);
	const sync = useSyncStatus();
	// `synced` is event-driven, and the client connected before this mounted, so
	// the event was already missed. `status` is seeded from the client.
	const online = sync.status === "connected";

	useEffect(() => {
		const onHash = () => setPageId(hashPage());
		window.addEventListener("hashchange", onHash);
		return () => window.removeEventListener("hashchange", onHash);
	}, []);

	const navigate = useCallback((next: string | null) => {
		setPageId(next);
		if (next) {
			history.replaceState(null, "", `#/${encodeURIComponent(next)}`);
		} else {
			history.replaceState(null, "", location.pathname);
		}
	}, []);

	useEffect(() => {
		if (pageId) return;
		const first = tree[0]?.page.id;
		if (first) navigate(first);
	}, [pageId, tree, navigate]);

	const addPage = useCallback(
		async (parentId?: string) => {
			const position = positionAtEnd(siblingsOf(rows, parentId));
			const icon = ICONS[Math.floor(Math.random() * ICONS.length)] ?? "🗒️";
			const id = await createPage(client, { parentId, position, icon });
			navigate(id);
		},
		[client, navigate, rows],
	);

	const onMove = useCallback(
		async (page: PageRow, direction: -1 | 1) => {
			const siblings = siblingsOf(rows, page.parent_id);
			const index = siblings.findIndex((row) => row.id === page.id);
			if (index < 0) return;
			if (direction < 0 ? index === 0 : index === siblings.length - 1) return;
			const position =
				direction < 0
					? positionBetween(siblings[index - 2], siblings[index - 1])
					: positionBetween(siblings[index + 2], siblings[index + 1]);
			await movePage(client, page.id, position, page.parent_id);
		},
		[client, rows],
	);

	const onIndent = useCallback(
		async (page: PageRow) => {
			const siblings = siblingsOf(rows, page.parent_id);
			const index = siblings.findIndex((row) => row.id === page.id);
			const newParent = index > 0 ? siblings[index - 1] : undefined;
			if (!newParent) return;
			await movePage(
				client,
				page.id,
				positionAtEnd(siblingsOf(rows, newParent.id)),
				newParent.id,
			);
		},
		[client, rows],
	);

	const onOutdent = useCallback(
		async (page: PageRow) => {
			if (!page.parent_id) return;
			const parent = byId.get(page.parent_id);
			if (!parent) return;
			const grandparentId = parent.parent_id;
			const uncles = siblingsOf(rows, grandparentId);
			const index = uncles.findIndex((row) => row.id === parent.id);
			await movePage(
				client,
				page.id,
				positionBetween(parent, uncles[index + 1]),
				grandparentId,
			);
		},
		[byId, client, rows],
	);

	const onDelete = useCallback(
		async (page: PageRow) => {
			const confirmed = window.confirm(
				`Delete “${pageTitle(page)}” and every page inside it? This cannot be undone.`,
			);
			if (!confirmed) return;
			await deletePage(client, page.id);
			if (pageId === page.id) navigate(page.parent_id ?? null);
		},
		[client, navigate, pageId],
	);

	const page = pageId ? byId.get(pageId) : undefined;

	return (
		<div className="shell">
			<nav className="sidebar">
				<div className="sidebar__brand">
					<span className="wordmark">verso</span>
					<button
						type="button"
						className="ghost ghost--small"
						title="New page"
						onClick={() => void addPage()}
					>
						+ New
					</button>
				</div>
				<div className="sidebar__tree">
					{tree.length === 0 ? (
						<p className="muted muted--small">
							{pagesQuery.isLoading ? "Loading pages…" : "No pages yet."}
						</p>
					) : (
						tree.map((node) => (
							<TreeNode
								key={node.page.id}
								node={node}
								depth={0}
								activeId={pageId}
								menuId={menuId}
								onMenu={setMenuId}
								onOpen={navigate}
								onAdd={addPage}
								onMove={onMove}
								onIndent={onIndent}
								onOutdent={onOutdent}
								onDelete={onDelete}
							/>
						))
					)}
				</div>
				<footer className="sidebar__foot">
					<span className="whoami">
						<span
							className="avatar avatar--you"
							style={{ backgroundColor: session.identity.color }}
						>
							{initials(session.identity.name)}
						</span>
						<span className="whoami__name">{session.identity.name}</span>
					</span>
					<span className={`link-pill${online ? "" : " is-off"}`}>
						{online ? "live" : sync.status}
					</span>
					<button
						type="button"
						className="ghost ghost--small"
						onClick={onLeave}
					>
						Leave
					</button>
				</footer>
			</nav>

			<main className="main">
				{online ? null : (
					<div className="notice">
						Offline — page bodies keep merging locally and sync on reconnect.
						Page titles need the connection.
					</div>
				)}
				{page ? (
					<PageScreen
						session={session}
						page={page}
						pages={rows}
						byId={byId}
						onNavigate={navigate}
					/>
				) : (
					<div className="empty">
						<h1>Pick a page</h1>
						<p className="muted">
							Or start a new one with <kbd>/</kbd> inside the page.
						</p>
						<button
							type="button"
							className="primary"
							onClick={() => void addPage()}
						>
							New page
						</button>
					</div>
				)}
			</main>
		</div>
	);
}

interface TreeNodeProps {
	node: PageNode;
	depth: number;
	activeId: string | null;
	menuId: string | null;
	onMenu: (id: string | null) => void;
	onOpen: (id: string) => void;
	onAdd: (parentId?: string) => Promise<void>;
	onMove: (page: PageRow, direction: -1 | 1) => Promise<void>;
	onIndent: (page: PageRow) => Promise<void>;
	onOutdent: (page: PageRow) => Promise<void>;
	onDelete: (page: PageRow) => Promise<void>;
}

function TreeNode({
	node,
	depth,
	activeId,
	menuId,
	onMenu,
	onOpen,
	onAdd,
	onMove,
	onIndent,
	onOutdent,
	onDelete,
}: TreeNodeProps) {
	const { page, children } = node;
	const [collapsed, setCollapsed] = useState(false);
	const open = menuId === page.id;
	return (
		<div className="node">
			<div
				className={`node__row${activeId === page.id ? " is-active" : ""}`}
				style={{ paddingLeft: 10 + depth * 14 }}
			>
				<button
					type="button"
					className={`node__chevron${children.length === 0 ? " is-hidden" : ""}`}
					onClick={() => setCollapsed((value) => !value)}
					aria-label={collapsed ? "Expand" : "Collapse"}
				>
					{collapsed ? "▸" : "▾"}
				</button>
				<button
					type="button"
					className="node__open"
					onClick={() => onOpen(page.id)}
				>
					<span className="node__icon">{pageIcon(page)}</span>
					<span className="node__title">{pageTitle(page)}</span>
				</button>
				<span className="node__actions">
					<button
						type="button"
						className="ghost ghost--tiny"
						title="Add a page inside"
						onClick={() => void onAdd(page.id)}
					>
						+
					</button>
					<button
						type="button"
						className="ghost ghost--tiny"
						title="Page actions"
						onClick={() => onMenu(open ? null : page.id)}
					>
						⋯
					</button>
				</span>
			</div>
			{open ? (
				<div className="node__menu">
					<button type="button" onClick={() => void onMove(page, -1)}>
						Move up
					</button>
					<button type="button" onClick={() => void onMove(page, 1)}>
						Move down
					</button>
					<button type="button" onClick={() => void onIndent(page)}>
						Indent
					</button>
					<button type="button" onClick={() => void onOutdent(page)}>
						Outdent
					</button>
					<button
						type="button"
						className="danger"
						onClick={() => void onDelete(page)}
					>
						Delete
					</button>
				</div>
			) : null}
			{collapsed
				? null
				: children.map((child) => (
						<TreeNode
							key={child.page.id}
							node={child}
							depth={depth + 1}
							activeId={activeId}
							menuId={menuId}
							onMenu={onMenu}
							onOpen={onOpen}
							onAdd={onAdd}
							onMove={onMove}
							onIndent={onIndent}
							onOutdent={onOutdent}
							onDelete={onDelete}
						/>
					))}
		</div>
	);
}

export type { AppClient };
