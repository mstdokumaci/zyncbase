import { mergeAttributes, Node } from "@tiptap/core";
import type { PageRow } from "../shared";
import { pageIcon, pageTitle } from "../shared";

export interface SubPageOptions {
	onNavigate: (pageId: string) => void;
}

const watchers = new Map<string, Set<HTMLElement>>();
let latestPages: Map<string, PageRow> = new Map();

function applyTitle(element: HTMLElement, pageId: string): void {
	const page = latestPages.get(pageId);
	const icon = element.querySelector(".sub-page__icon");
	const title = element.querySelector(".sub-page__title");
	if (icon) icon.textContent = pageIcon(page);
	if (title) {
		title.textContent = pageId
			? page
				? pageTitle(page)
				: "Missing page"
			: "Untitled";
	}
}

/** Called by the editor whenever the page tree changes. */
export function publishPageTitles(pages: Map<string, PageRow>): void {
	latestPages = pages;
	for (const [pageId, elements] of watchers) {
		for (const element of elements) applyTitle(element, pageId);
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
			const title = document.createElement("span");
			title.className = "sub-page__title";
			dom.append(icon, title);
			dom.addEventListener("click", () => {
				if (pageId) this.options.onNavigate(pageId);
			});

			const elements = watchers.get(pageId) ?? new Set<HTMLElement>();
			watchers.set(pageId, elements);
			elements.add(dom);
			applyTitle(dom, pageId);

			return {
				dom,
				// Attributes never change in this app. Recreating the view is
				// simpler and safer than retargeting its registrations.
				update: () => false,
				destroy: () => {
					elements.delete(dom);
					if (elements.size === 0) watchers.delete(pageId);
				},
			};
		};
	},
});
