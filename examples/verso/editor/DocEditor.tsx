import Collaboration from "@tiptap/extension-collaboration";
import CollaborationCaret from "@tiptap/extension-collaboration-caret";
import Placeholder from "@tiptap/extension-placeholder";
import TaskItem from "@tiptap/extension-task-item";
import TaskList from "@tiptap/extension-task-list";
import { EditorContent, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import type { ZyncBaseYjsProvider } from "@zyncbase/client/yjs";
import { useEffect, useMemo } from "react";
import type * as Y from "yjs";
import type { ZyncBasePresence, ZyncBaseSchema } from "../schema-types";
import type { Identity, PageRow } from "../shared";
import { BubbleToolbar } from "./BubbleToolbar";
import { SlashCommand, SlashMenu, SlashMenuController } from "./slash";
import { publishPageTitles, SubPage } from "./subpage";

export type PageProvider = ZyncBaseYjsProvider<
	ZyncBaseSchema,
	never,
	ZyncBasePresence
>;

export interface DocEditorProps {
	doc: Y.Doc;
	provider: PageProvider | null;
	pages: Map<string, PageRow>;
	identity: Identity;
	readOnly?: boolean;
	onNavigate: (pageId: string) => void;
	createSubPage: () => Promise<string | null>;
	onError: (error: unknown) => void;
}

function caretElement(user: Record<string, unknown>): HTMLElement {
	const caret = document.createElement("span");
	caret.className = "caret";
	caret.style.borderColor = String(user.color ?? "#999");
	const label = document.createElement("span");
	label.className = "caret__label";
	label.style.backgroundColor = String(user.color ?? "#999");
	label.textContent = String(user.name ?? "Someone");
	caret.append(label);
	return caret;
}

export function DocEditor({
	doc,
	provider,
	pages,
	identity,
	readOnly = false,
	onNavigate,
	createSubPage,
	onError,
}: DocEditorProps) {
	const controller = useMemo(() => new SlashMenuController(), []);

	const extensions = useMemo(() => {
		const base = [
			StarterKit.configure({
				// Yjs owns undo history; a second history stack would diverge.
				undoRedo: false,
				heading: { levels: [1, 2, 3] },
				// Clicking a link while editing should place the caret, not navigate.
				link: { openOnClick: false },
			}),
			TaskList,
			TaskItem.configure({ nested: true }),
			Collaboration.configure({ document: doc }),
			SubPage.configure({ onNavigate }),
		];
		if (readOnly) return base;
		return [
			...base,
			Placeholder.configure({
				placeholder: "Write something, or type / for a block",
			}),
			SlashCommand.configure({
				controller,
				createSubPage,
				onError,
			}),
			...(provider?.awareness
				? [
						CollaborationCaret.configure({
							provider,
							user: { name: identity.name, color: identity.color },
							render: caretElement,
							selectionRender: (user: Record<string, unknown>) => ({
								class: "caret-selection",
								style: `background-color: ${String(user.color ?? "#999")}26`,
							}),
						}),
					]
				: []),
		];
	}, [
		doc,
		provider,
		readOnly,
		controller,
		identity.name,
		identity.color,
		onNavigate,
		createSubPage,
		onError,
	]);

	const editor = useEditor(
		{
			extensions,
			editable: !readOnly,
			immediatelyRender: false,
			editorProps: { attributes: { class: "prose" } },
		},
		[extensions],
	);

	useEffect(() => {
		publishPageTitles(pages);
	}, [pages]);

	useEffect(() => {
		if (readOnly) return;
		editor?.commands.updateUser({
			name: identity.name,
			color: identity.color,
		});
	}, [editor, identity.name, identity.color, readOnly]);

	return (
		<>
			<EditorContent editor={editor} />
			{readOnly ? null : <SlashMenu controller={controller} />}
			{editor && !readOnly ? <BubbleToolbar editor={editor} /> : null}
		</>
	);
}
