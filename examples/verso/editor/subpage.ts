import { mergeAttributes, Node } from "@tiptap/core";
import type { PageRow } from "../shared";
import { pageIcon, pageTitle } from "../shared";

export interface SubPageOptions {
	onNavigate: (pageId: string) => void;
}

const watchers = new Map<string, Set<HTMLElement>>();

/** Called by the editor whenever the page tree changes. */
export function publishPageTitles(pages: Map<string, PageRow>): void {
	for (const [pageId, elements] of watchers) {
		const page = pages.get(pageId);
		for (const element of elements) {
			const icon = element.querySelector(".sub-page__icon");
			const title = element.querySelector(".sub-page__title");
			if (icon) icon.textContent = pageIcon(page);
			if (title) title.textContent = page ? pageTitle(page) : "Missing page";
		}
	}
}

declare module "@tiptap/core" {
	interface Commands<ReturnType> {
		subPage: {
			setSubPage: (attributes: { pageId: string }) => ReturnType;
		};
	}
}

/**
 * An inline reference to another page. The node lives in the page's Y.Doc; the
 * page it points at is a store row, so the link is a plain id.
 */
export const SubPage = Node.create<SubPageOptions>({
	name: "subPage",
	group: "block",
	atom: true,
	selectable: true,

	addOptions() {
		return { onNavigate: () => {} };
	},

	addAttributes() {
		return { pageId: { default: null } };
	},

	parseHTML() {
		return [{ tag: "div[data-sub-page]" }];
	},

	renderHTML({ HTMLAttributes }) {
		return ["div", mergeAttributes({ "data-sub-page": HTMLAttributes.pageId })];
	},

	addCommands() {
		return {
			setSubPage:
				(attributes) =>
				({ commands }) =>
					commands.insertContent({
						type: this.name,
						attrs: attributes,
					}),
		};
	},

	addNodeView() {
		return ({ node }) => {
			const pageId = String(node.attrs.pageId ?? "");
			const dom = document.createElement("div");
			dom.className = "sub-page";
			dom.dataset.subPage = pageId;
			const icon = document.createElement("span");
			icon.className = "sub-page__icon";
			icon.textContent = "🗒️";
			const title = document.createElement("span");
			title.className = "sub-page__title";
			title.textContent = "Untitled";
			dom.append(icon, title);
			dom.addEventListener("click", () => {
				if (pageId) this.options.onNavigate(pageId);
			});

			let registered = watchers.get(pageId);
			if (!registered) {
				registered = new Set();
				watchers.set(pageId, registered);
			}
			registered.add(dom);

			return {
				dom,
				update: (updated) => {
					if (updated.type.name !== "subPage") return false;
					const next = String(updated.attrs.pageId ?? "");
					if (next === dom.dataset.subPage) return true;
					registered?.delete(dom);
					dom.dataset.subPage = next;
					let nextWatchers = watchers.get(next);
					if (!nextWatchers) {
						nextWatchers = new Set();
						watchers.set(next, nextWatchers);
					}
					nextWatchers.add(dom);
					return true;
				},
				destroy: () => {
					registered?.delete(dom);
				},
			};
		};
	},
});
