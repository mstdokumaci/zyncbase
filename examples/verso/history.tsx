import { useEffect, useMemo, useRef, useState } from "react";
import * as Y from "yjs";
import { useQuery } from "./bindings";
import { DocEditor } from "./editor/DocEditor";
import { assembleChanges } from "./history-data";
import {
	type ChangeRow,
	type Identity,
	type PageRow,
	type People,
	userOf,
} from "./shared";

const HISTORY_LIMIT = 200;
/** Five seconds in microseconds: a gap means the page is older than this log. */
const PAGE_GAP_US = 5_000_000;

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
	people: People;
	identity: Identity;
	onClose: () => void;
	onNavigate: (pageId: string) => void;
	onError: (error: unknown) => void;
}

export function HistoryPanel({
	page,
	pages,
	people,
	identity,
	onClose,
	onNavigate,
	onError,
}: HistoryPanelProps) {
	const changes = useQuery("page_changes", {
		where: { document_id: page.id },
		orderBy: [{ created_at: "desc" }],
		limit: HISTORY_LIMIT,
	});
	const entries = useMemo(
		() =>
			assembleChanges([...(changes.data as readonly ChangeRow[])].reverse()),
		[changes.data],
	);
	const [index, setIndex] = useState(0);
	// Follow new changes only while the user is at the newest one; someone
	// scrubbing through the past keeps their position.
	const following = useRef(true);
	useEffect(() => {
		setIndex((current) => {
			const last = Math.max(entries.length - 1, 0);
			return following.current ? last : Math.min(current, last);
		});
	}, [entries.length]);

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
		changes.data.length >= HISTORY_LIMIT ||
		(pageStart > 0 && earliest > 0 && earliest - pageStart > PAGE_GAP_US);
	const current = entries[index];
	const author = current ? userOf(current.ownerId, people) : undefined;

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
								}${author?.name ? ` · ${author.name}` : ""}`}
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
					onChange={(event) => {
						const next = Number(event.target.value);
						following.current = next >= entries.length - 1;
						setIndex(next);
					}}
				/>
			) : null}
			{incomplete ? (
				<p className="history__note">
					This preview starts from the oldest loaded change. Earlier history is
					either compacted away or beyond the newest {HISTORY_LIMIT} changes.
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
