import type { Editor } from "@tiptap/react";
import { useEditorState } from "@tiptap/react";
import { BubbleMenu } from "@tiptap/react/menus";

const MARKS = [
	{ name: "bold", glyph: "B", title: "Bold (⌘B)", className: "mark-bold" },
	{
		name: "italic",
		glyph: "I",
		title: "Italic (⌘I)",
		className: "mark-italic",
	},
	{
		name: "underline",
		glyph: "U",
		title: "Underline (⌘U)",
		className: "mark-underline",
	},
	{
		name: "strike",
		glyph: "S",
		title: "Strikethrough",
		className: "mark-strike",
	},
	{
		name: "code",
		glyph: "</>",
		title: "Inline code",
		className: "mark-code mark-code--last",
	},
] as const;

type MarkName = (typeof MARKS)[number]["name"];

/**
 * Notion's inline formatting lives on a floating toolbar over the selection.
 * Tiptap positions it, hides it for empty selections, and keeps focus in the
 * editor while a button is pressed.
 */
export function BubbleToolbar({ editor }: { editor: Editor }) {
	return (
		<BubbleMenu editor={editor} className="bubble" updateDelay={80}>
			<MarkButtons editor={editor} />
		</BubbleMenu>
	);
}

/** The buttons on their own, so they can render outside a floating menu. */
export function MarkButtons({ editor }: { editor: Editor }) {
	const active = useEditorState({
		editor,
		selector: ({ editor: current }) => ({
			bold: current.isActive("bold"),
			italic: current.isActive("italic"),
			underline: current.isActive("underline"),
			strike: current.isActive("strike"),
			code: current.isActive("code"),
		}),
	}) as Record<MarkName, boolean>;

	return (
		<>
			{MARKS.map((mark) => (
				<button
					key={mark.name}
					type="button"
					title={mark.title}
					aria-label={mark.title}
					aria-pressed={active[mark.name]}
					className={`bubble__button ${mark.className}${
						active[mark.name] ? " is-active" : ""
					}`}
					onClick={() => editor.chain().focus().toggleMark(mark.name).run()}
				>
					{mark.glyph}
				</button>
			))}
		</>
	);
}
