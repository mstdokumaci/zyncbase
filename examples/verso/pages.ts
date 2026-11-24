import type { AppClient, PageRow } from "./shared";

export interface PageNode {
	page: PageRow;
	children: PageNode[];
}

/** Sidebar order: position first, id as the stable tie-break. */
function compareSiblings(a: PageRow, b: PageRow): number {
	return a.position - b.position || a.id.localeCompare(b.id);
}

/** Builds the sidebar tree. Rows without a present parent are roots. */
export function buildTree(rows: readonly PageRow[]): PageNode[] {
	const nodes = new Map<string, PageNode>();
	for (const page of rows) {
		nodes.set(page.id, { page, children: [] });
	}
	const roots: PageNode[] = [];
	for (const node of nodes.values()) {
		const parentId = node.page.parent_id;
		const parent = parentId ? nodes.get(parentId) : undefined;
		if (parent) parent.children.push(node);
		else roots.push(node);
	}
	const sort = (list: PageNode[]) => {
		list.sort((a, b) => compareSiblings(a.page, b.page));
		for (const node of list) sort(node.children);
	};
	sort(roots);
	return roots;
}

/** Children of one page, in sidebar order. Orphans count as roots. */
export function siblingsOf(
	rows: readonly PageRow[],
	parentId: string | undefined,
): PageRow[] {
	const known = new Set(rows.map((row) => row.id));
	const target = parentId ?? undefined;
	return rows
		.filter((row) => {
			const parent =
				row.parent_id && known.has(row.parent_id) ? row.parent_id : undefined;
			return parent === target;
		})
		.sort(compareSiblings);
}

export interface PositionChange {
	id: string;
	position: number;
}

const POSITION_STEP = 1000;

/**
 * The writes that move one page a slot. A midpoint is enough when the
 * neighbours are separated; when their positions tie, the midpoint cannot
 * order the row, so every sibling is renumbered in the requested order.
 */
export function moveChanges(
	siblings: readonly PageRow[],
	index: number,
	direction: -1 | 1,
): PositionChange[] | null {
	const moved = siblings[index];
	if (!moved) return null;
	const insertAt = index + direction;
	if (insertAt < 0 || insertAt >= siblings.length) return null;

	const rest = siblings.filter((_, current) => current !== index);
	const position = positionBetween(rest[insertAt - 1], rest[insertAt]);
	const reordered = [
		...rest.slice(0, insertAt),
		{ ...moved, position },
		...rest.slice(insertAt),
	];
	const sorted = [...reordered].sort(compareSiblings);
	if (sorted[insertAt]?.id === moved.id) {
		return [{ id: moved.id, position }];
	}
	return reordered.map((row, slot) => ({
		id: row.id,
		position: (slot + 1) * POSITION_STEP,
	}));
}

/** Applies a reorder atomically; a renumber must never land half-done. */
export function reorderPages(
	client: AppClient,
	changes: readonly PositionChange[],
): Promise<void> {
	return client.store.batch(
		changes.map((change) => ({
			op: "set" as const,
			path: ["pages", change.id, "position"],
			value: change.position,
		})),
	);
}

/** A position that sorts after every sibling. */
export function positionAtEnd(siblings: readonly PageRow[]): number {
	const last = siblings[siblings.length - 1];
	return last ? last.position + 1000 : 1000;
}

/** A position halfway between two siblings; reorder rewrites one row. */
export function positionBetween(
	previous: PageRow | undefined,
	next: PageRow | undefined,
): number {
	if (previous && next) return (previous.position + next.position) / 2;
	if (previous) return previous.position + 1000;
	if (next) return next.position - 1000;
	return 1000;
}

export async function createPage(
	client: AppClient,
	options: {
		title?: string;
		icon?: string;
		parentId?: string;
		position?: number;
	},
): Promise<string> {
	const id = client.utils.id();
	await client.store.batch([
		{
			op: "set",
			path: ["pages", id],
			value: {
				title: options.title ?? "",
				icon: options.icon ?? "🗒️",
				position: options.position ?? 1000,
				compaction_version: 0,
				...(options.parentId ? { parent_id: options.parentId } : {}),
			},
		},
	]);
	return id;
}

export function renamePage(
	client: AppClient,
	pageId: string,
	title: string,
): Promise<void> {
	return client.store.set(["pages", pageId, "title"], title);
}

/** One write: the row's own chunks cascade with the subtree. */
export function deletePage(client: AppClient, pageId: string): Promise<void> {
	return client.store.remove(["pages", pageId]);
}

export async function movePage(
	client: AppClient,
	pageId: string,
	position: number,
	parentId?: string,
): Promise<void> {
	await client.store.batch([
		{ op: "set", path: ["pages", pageId, "position"], value: position },
		{
			op: "set",
			path: ["pages", pageId, "parent_id"],
			value: parentId ?? null,
		},
	]);
}
