import type { AppClient, PageRow } from "./shared";

export interface PageNode {
	page: PageRow;
	children: PageNode[];
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
		list.sort(
			(a, b) =>
				a.page.position - b.page.position || a.page.id.localeCompare(b.page.id),
		);
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
		.sort((a, b) => a.position - b.position || a.id.localeCompare(b.id));
}

/** The position a page needs to move one slot, or null at the edge. */
export function movePosition(
	siblings: readonly PageRow[],
	index: number,
	direction: -1 | 1,
): number | null {
	if (index < 0) return null;
	if (direction < 0) {
		if (index === 0) return null;
		return positionBetween(siblings[index - 2], siblings[index - 1]);
	}
	if (index >= siblings.length - 1) return null;
	return positionBetween(siblings[index + 1], siblings[index + 2]);
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
