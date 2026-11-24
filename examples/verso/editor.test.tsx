import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";

GlobalRegistrator.register();

const { Editor } = await import("@tiptap/core");
const { default: StarterKit } = await import("@tiptap/starter-kit");
const { default: Collaboration } = await import(
	"@tiptap/extension-collaboration"
);
const { default: TaskList } = await import("@tiptap/extension-task-list");
const { default: TaskItem } = await import("@tiptap/extension-task-item");
const { SubPage } = await import("./editor/subpage");
const { MarkButtons } = await import("./editor/BubbleToolbar");
const { render, fireEvent, cleanup } = await import("@testing-library/react");
const { createElement } = await import("react");
const { cursorFromPresence, cursorToPresence } = await import(
	"./editor/cursor-presence"
);
const { default: CollaborationCaret } = await import(
	"@tiptap/extension-collaboration-caret"
);
const awarenessLib = await import("y-protocols/awareness");
const Y = await import("yjs");

const navigated: string[] = [];

function editorFor(doc: InstanceType<typeof Y.Doc>) {
	const element = document.createElement("div");
	document.body.append(element);
	return new Editor({
		element,
		extensions: [
			StarterKit.configure({ undoRedo: false, heading: { levels: [1, 2, 3] } }),
			TaskList,
			TaskItem.configure({ nested: true }),
			Collaboration.configure({ document: doc }),
			SubPage.configure({ onNavigate: (id) => navigated.push(id) }),
		],
	});
}

describe("editor wiring", () => {
	test("content lands in the Y.Doc and reaches a peer", () => {
		const docA = new Y.Doc();
		const docB = new Y.Doc();
		const a = editorFor(docA);
		a.commands.setContent(
			"<h2>Merging</h2><p>Two windows, one paragraph.</p><ul><li><p>a task</p></li></ul>",
		);
		const text = JSON.stringify(docA.getXmlFragment("default").toJSON());
		expect(text).toContain("Two windows, one paragraph.");

		Y.applyUpdate(docB, Y.encodeStateAsUpdate(docA));
		const b = editorFor(docB);
		expect(b.getText()).toContain("Two windows, one paragraph.");

		b.destroy();
		a.destroy();
		docA.destroy();
		docB.destroy();
	});

	test("the sub-page node renders and navigates", () => {
		const doc = new Y.Doc();
		const editor = editorFor(doc);
		editor.commands.setSubPage({ pageId: "page-9" });
		const node = document.querySelector<HTMLElement>(".sub-page");
		expect(node?.dataset.subPage).toBe("page-9");
		node?.click();
		expect(navigated).toEqual(["page-9"]);
		editor.destroy();
		doc.destroy();
	});

	// The reported crash: a caret published on an empty non-text node is a root
	// type ID with no item. Dropping the type made every peer throw
	// "Unexpected case" on the next transaction.
	test("a cursor restored from presence does not break a transaction", () => {
		const doc = new Y.Doc();
		const awareness = new awarenessLib.Awareness(doc);
		const remote = new awarenessLib.Awareness(doc);
		remote.on(
			"update",
			({
				added,
				updated,
				removed,
			}: {
				added: number[];
				updated: number[];
				removed: number[];
			}) => {
				awarenessLib.applyAwarenessUpdate(
					awareness,
					awarenessLib.encodeAwarenessUpdate(remote, [
						...added,
						...updated,
						...removed,
					]),
					"remote",
				);
			},
		);
		const element = document.createElement("div");
		document.body.append(element);
		const editor = new Editor({
			element,
			extensions: [
				StarterKit.configure({ undoRedo: false }),
				Collaboration.configure({ document: doc }),
				CollaborationCaret.configure({
					provider: { awareness },
					user: { name: "Ada", color: "#c96a4b" },
				}),
			],
		});

		const emptyNode = {
			anchor: { type: { client: 99, clock: 0 }, assoc: 0 },
			head: { type: { client: 99, clock: 0 }, assoc: 0 },
		};
		const payload = cursorToPresence(emptyNode);
		expect(payload).not.toBeNull();
		const restored = cursorFromPresence(payload);
		expect(restored).toEqual(emptyNode);
		remote.setLocalState({
			user: { name: "Grace", color: "#4d74a8" },
			cursor: restored,
		});

		expect(() => editor.commands.insertContent("hello")).not.toThrow();
		expect(editor.getText()).toContain("hello");

		editor.destroy();
		awareness.destroy();
		remote.destroy();
		doc.destroy();
	});

	test("the selection toolbar toggles marks that reach the doc", () => {
		const doc = new Y.Doc();
		const editor = editorFor(doc);
		editor.commands.setContent("<p>Hello world</p>");
		editor.commands.selectAll();

		const view = render(createElement(MarkButtons, { editor }));
		const buttons = [
			...view.container.querySelectorAll<HTMLButtonElement>(".bubble__button"),
		];
		expect(buttons.map((button) => button.title)).toEqual([
			"Bold (⌘B)",
			"Italic (⌘I)",
			"Underline (⌘U)",
			"Strikethrough",
			"Inline code",
		]);

		fireEvent.click(buttons[0] as HTMLButtonElement);
		expect(editor.isActive("bold")).toBe(true);
		expect(editor.getHTML()).toContain("<strong>");

		fireEvent.click(buttons[1] as HTMLButtonElement);
		expect(editor.getHTML()).toMatch(/<em><strong>|<strong><em>/);

		const marks = JSON.stringify(doc.getXmlFragment("default").toJSON());
		expect(marks).toContain("bold");
		expect(marks).toContain("italic");

		cleanup();
		editor.destroy();
		doc.destroy();
	});
});

afterAll(() => {
	GlobalRegistrator.unregister();
});

beforeAll(() => {});
