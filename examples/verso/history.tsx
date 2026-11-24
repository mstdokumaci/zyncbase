import { useEffect, useMemo, useState } from "react";
import * as Y from "yjs";
import { useQuery } from "./bindings";
import { DocEditor } from "./editor/DocEditor";
import { assembleChanges } from "./history-data";
import type { ChangeRow, Identity, PageRow } from "./shared";

function when(at: number): string {
	return new Date(at / 1000).toLocaleTimeString([], {
		hour: "2-digit",
		minute: "2-digit",
		second: "2-digit",
	});
}

export interface HistoryPanelProps {
	page: PageRow;
	pages: Map<string, PageRow>;
	identity: Identity;
	onClose: () => void;
	onNavigate: (pageId: string) => void;
	onError: (error: unknown) => void;
}

export function HistoryPanel({
	page,
	pages,
	identity,
	onClose,
	onNavigate,
	onError,
}: HistoryPanelProps) {
	const changes = useQuery("page_changes", {
		where: { document_id: page.id },
		orderBy: [{ created_at: "desc" }],
		limit: 200,
	});
	const entries = useMemo(
		() =>
			assembleChanges([...(changes.data as readonly ChangeRow[])].reverse()),
		[changes.data],
	);
	const [index, setIndex] = useState(0);
	useEffect(() => setIndex(Math.max(entries.length - 1, 0)), [entries.length]);

	const preview = useMemo(() => {
		const doc = new Y.Doc();
		for (const entry of entries.slice(0, index + 1)) {
			Y.applyUpdate(doc, entry.bytes, "history");
		}
		return doc;
	}, [entries, index]);
	useEffect(() => () => preview.destroy(), [preview]);

	const pageStart = page.created_at ?? 0;
	const earliest = entries[0]?.at ?? 0;
	const incomplete =
		pageStart > 0 && earliest > 0 && earliest - pageStart > 5_000_000;
	const current = entries[index];

	return (
		<aside className="history">
			<header className="history__head">
				<div>
					<h2>History</h2>
					<p>
						{entries.length === 0
							? "No retained changes yet."
							: `${index + 1} of ${entries.length} changes${
									current ? ` · ${when(current.at)}` : ""
								}`}
					</p>
				</div>
				<button type="button" className="ghost" onClick={onClose}>
					Close
				</button>
			</header>
			{entries.length > 1 ? (
				<input
					className="history__slider"
					type="range"
					min={0}
					max={entries.length - 1}
					value={index}
					onChange={(event) => setIndex(Number(event.target.value))}
				/>
			) : null}
			{incomplete ? (
				<p className="history__note">
					Older changes were compacted away; this preview starts from the oldest
					retained change.
				</p>
			) : null}
			<div className="history__preview">
				{entries.length === 0 ? (
					<p className="muted">Type in the page, then come back.</p>
				) : (
					<DocEditor
						doc={preview}
						provider={null}
						pages={pages}
						identity={identity}
						readOnly
						onNavigate={onNavigate}
						createSubPage={async () => null}
						onError={onError}
					/>
				)}
			</div>
		</aside>
	);
}
