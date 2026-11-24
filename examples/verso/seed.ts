import * as Y from "yjs";

/**
 * Writes the welcome page body into the Yjs fragment Tiptap binds to. Built by
 * hand so the seed is deterministic and never races a browser: no editor has to
 * be mounted to create the first document.
 *
 * Types are attached to the fragment before they get children, because Yjs
 * refuses to write into a detached type.
 */
export function writeWelcome(fragment: Y.XmlFragment): void {
	const heading = new Y.XmlElement("heading");
	fragment.insert(fragment.length, [heading]);
	heading.insert(0, [new Y.XmlText("Everything here is a row or a change")]);

	const intro = new Y.XmlElement("paragraph");
	fragment.insert(fragment.length, [intro]);
	intro.insert(0, [
		new Y.XmlText(
			"Each page in the sidebar is one row. Its body is this Yjs document. Open this page in a second window with a different email and type in both — the text merges, and your carets travel through presence.",
		),
	]);

	const bulletList = new Y.XmlElement("bulletList");
	fragment.insert(fragment.length, [bulletList]);
	for (const text of [
		"Type / to insert a heading, a list, a to-do, or a page.",
		"Use the ⋯ menu to nest, reorder, or delete a page.",
		"Press History to replay every change this page received.",
	]) {
		const item = new Y.XmlElement("listItem");
		bulletList.insert(bulletList.length, [item]);
		const paragraph = new Y.XmlElement("paragraph");
		item.insert(0, [paragraph]);
		paragraph.insert(0, [new Y.XmlText(text)]);
	}

	const outro = new Y.XmlElement("paragraph");
	fragment.insert(fragment.length, [outro]);
	outro.insert(0, [
		new Y.XmlText(
			"The page title is last-write-wins on purpose: a name is not prose. The body is a CRDT, so two people typing at once never overwrite each other.",
		),
	]);
}
