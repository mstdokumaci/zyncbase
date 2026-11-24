import { type Editor, Extension, type Range } from "@tiptap/core";
import Suggestion, {
	type SuggestionKeyDownProps,
	type SuggestionProps,
} from "@tiptap/suggestion";
import { useSyncExternalStore } from "react";

export interface SlashItem {
	title: string;
	hint: string;
	glyph: string;
	run: (editor: Editor, range: Range) => unknown;
}

export interface SlashState {
	open: boolean;
	index: number;
	items: SlashItem[];
	rect: { left: number; top: number; bottom: number } | null;
}

const INITIAL: SlashState = { open: false, index: 0, items: [], rect: null };

/** Drives the slash menu from the Tiptap suggestion plugin. */
export class SlashMenuController {
	private state: SlashState = INITIAL;
	private readonly listeners = new Set<() => void>();
	private props: SuggestionProps<SlashItem, SlashItem> | null = null;

	readonly subscribe = (listener: () => void) => {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	};

	readonly getSnapshot = () => this.state;

	private emit(next: Partial<SlashState>) {
		this.state = { ...this.state, ...next };
		for (const listener of this.listeners) listener();
	}

	private rectOf(props: SuggestionProps<SlashItem, SlashItem>) {
		const rect = props.clientRect?.();
		return rect
			? { left: rect.left, top: rect.top, bottom: rect.bottom }
			: null;
	}

	open(props: SuggestionProps<SlashItem, SlashItem>) {
		this.props = props;
		this.emit({
			open: true,
			index: 0,
			items: props.items,
			rect: this.rectOf(props),
		});
	}

	update(props: SuggestionProps<SlashItem, SlashItem>) {
		this.props = props;
		this.emit({
			items: props.items,
			rect: this.rectOf(props),
			index: Math.min(this.state.index, Math.max(props.items.length - 1, 0)),
		});
	}

	close() {
		this.props = null;
		this.emit({ ...INITIAL });
	}

	move(delta: number) {
		const count = this.state.items.length;
		if (count === 0) return;
		this.emit({ index: (this.state.index + delta + count) % count });
	}

	setIndex(index: number) {
		if (index === this.state.index) return;
		this.emit({ index });
	}

	select(index = this.state.index) {
		const item = this.state.items[index];
		const props = this.props;
		if (!item || !props) return;
		this.close();
		void props.command(item);
	}
}

export interface SlashOptions {
	controller: SlashMenuController;
	createSubPage: () => Promise<string | null>;
	onError: (error: unknown) => void;
}

export const SlashCommand = Extension.create<SlashOptions>({
	name: "slashCommand",

	addOptions() {
		return {
			controller: new SlashMenuController(),
			createSubPage: async () => null,
			onError: () => {},
		};
	},

	addProseMirrorPlugins() {
		const { controller, createSubPage, onError } = this.options;
		const items = (): SlashItem[] => [
			{
				title: "Heading 1",
				hint: "Big section heading",
				glyph: "H1",
				run: (target, range) =>
					target
						.chain()
						.focus()
						.deleteRange(range)
						.setHeading({ level: 1 })
						.run(),
			},
			{
				title: "Heading 2",
				hint: "Medium section heading",
				glyph: "H2",
				run: (target, range) =>
					target
						.chain()
						.focus()
						.deleteRange(range)
						.setHeading({ level: 2 })
						.run(),
			},
			{
				title: "Heading 3",
				hint: "Small section heading",
				glyph: "H3",
				run: (target, range) =>
					target
						.chain()
						.focus()
						.deleteRange(range)
						.setHeading({ level: 3 })
						.run(),
			},
			{
				title: "Bulleted list",
				hint: "A simple list",
				glyph: "•",
				run: (target, range) =>
					target.chain().focus().deleteRange(range).toggleBulletList().run(),
			},
			{
				title: "Numbered list",
				hint: "A list with numbers",
				glyph: "1.",
				run: (target, range) =>
					target.chain().focus().deleteRange(range).toggleOrderedList().run(),
			},
			{
				title: "To-do",
				hint: "Track a task",
				glyph: "☑",
				run: (target, range) =>
					target.chain().focus().deleteRange(range).toggleTaskList().run(),
			},
			{
				title: "Quote",
				hint: "Set text apart",
				glyph: "❝",
				run: (target, range) =>
					target.chain().focus().deleteRange(range).toggleBlockquote().run(),
			},
			{
				title: "Code block",
				hint: "A monospaced block",
				glyph: "</>",
				run: (target, range) =>
					target.chain().focus().deleteRange(range).toggleCodeBlock().run(),
			},
			{
				title: "Divider",
				hint: "A horizontal rule",
				glyph: "—",
				run: (target, range) =>
					target.chain().focus().deleteRange(range).setHorizontalRule().run(),
			},
			{
				title: "Page",
				hint: "Link another page",
				glyph: "📄",
				run: async (target, range) => {
					// Delete before the await: a remote edit can shift the captured
					// range while the page is being created.
					target.chain().focus().deleteRange(range).run();
					try {
						const pageId = await createSubPage();
						if (!pageId) return;
						target.chain().focus().setSubPage({ pageId }).run();
					} catch (error) {
						onError(error);
					}
				},
			},
		];

		return [
			Suggestion<SlashItem, SlashItem>({
				editor: this.editor,
				char: "/",
				items: ({ query }) => {
					const all = items();
					const needle = query.toLowerCase();
					return needle
						? all.filter((item) => item.title.toLowerCase().includes(needle))
						: all;
				},
				command: ({ editor, range, props }) => {
					void props.run(editor, range);
				},
				render: () => ({
					onStart: (props) => controller.open(props),
					onUpdate: (props) => controller.update(props),
					onExit: () => controller.close(),
					onKeyDown: ({ event }: SuggestionKeyDownProps) => {
						const state = controller.getSnapshot();
						if (!state.open) return false;
						if (event.key === "Escape") {
							controller.close();
							return true;
						}
						if (
							(event.key === "Enter" || event.key === "Tab") &&
							state.items.length === 0
						) {
							return false;
						}
						const actions: Record<string, () => void> = {
							ArrowDown: () => controller.move(1),
							ArrowUp: () => controller.move(-1),
							Enter: () => controller.select(),
							Tab: () => controller.select(),
						};
						const action = actions[event.key];
						if (!action) return false;
						action();
						return true;
					},
				}),
			}),
		];
	},
});

/** The floating menu. Rendered next to the editor, positioned at the caret. */
export function SlashMenu({ controller }: { controller: SlashMenuController }) {
	const state = useSyncExternalStore(
		controller.subscribe,
		controller.getSnapshot,
	);
	if (!state.open || state.items.length === 0) return null;
	const style = state.rect
		? { left: state.rect.left, top: state.rect.bottom + 6 }
		: { left: 24, top: 24 };
	return (
		<div className="slash-menu" style={style} role="listbox">
			{state.items.map((item, index) => (
				<button
					key={item.title}
					type="button"
					role="option"
					aria-selected={index === state.index}
					className={`slash-item${index === state.index ? " is-active" : ""}`}
					onMouseEnter={() => controller.setIndex(index)}
					onMouseDown={(event) => {
						event.preventDefault();
						controller.select(index);
					}}
				>
					<span className="slash-glyph">{item.glyph}</span>
					<span className="slash-copy">
						<span className="slash-title">{item.title}</span>
						<span className="slash-hint">{item.hint}</span>
					</span>
				</button>
			))}
		</div>
	);
}
