import type { DocumentRowOf, ZyncBaseClient } from "@zyncbase/client";
import type { ZyncBasePresence, ZyncBaseSchema } from "./schema-types";

export type AppClient = ZyncBaseClient<ZyncBaseSchema, never, ZyncBasePresence>;

export const WORKSPACE = "main";
export const STORE_NAMESPACE = `verso:${WORKSPACE}`;
export const pageNamespace = (pageId: string) =>
	`${STORE_NAMESPACE}:doc:${pageId}`;
export const collections = {
	documents: "pages",
	snapshots: "page_snapshots",
	updates: "page_changes",
} as const;

/** Row shape as the app uses it: schema fields plus the server timestamps. */
export type PageRow = DocumentRowOf<ZyncBaseSchema, "pages"> & {
	created_at?: number;
	updated_at?: number;
};

export type ChangeRow = DocumentRowOf<ZyncBaseSchema, "page_changes"> & {
	created_at?: number;
};

export type SnapshotRow = DocumentRowOf<ZyncBaseSchema, "page_snapshots"> & {
	created_at?: number;
};

export const COLORS = [
	"#c96a4b",
	"#6f8f5f",
	"#4d74a8",
	"#a45f8d",
	"#b0842f",
	"#3f8c85",
];

export const ICONS = ["🌱", "🌿", "🍃", "🪴", "🌊", "🧭", "📚", "🗒️"];

export interface Identity {
	email: string;
	name: string;
	color: string;
}

export function initials(name: string): string {
	const parts = name.trim().split(/\s+/).filter(Boolean);
	if (parts.length === 0) return "?";
	const first = parts[0]?.[0] ?? "";
	const last = parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? "") : "";
	return `${first}${last}`.toUpperCase();
}

export function cleanText(value: string, max: number): string {
	return value.replace(/\s+/g, " ").trim().slice(0, max);
}

export function pageTitle(page: PageRow | null | undefined): string {
	return page?.title?.trim() || "Untitled";
}

export function pageIcon(page: PageRow | null | undefined): string {
	return page?.icon?.trim() || "🗒️";
}
