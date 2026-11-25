import type { ListenHandle } from "@zyncbase/client";
import { ZyncBaseClient } from "./client";

const WAIT_MS = 10_000;

async function waitFor(label: string, check: () => boolean): Promise<void> {
	const deadline = Date.now() + WAIT_MS;
	while (Date.now() < deadline) {
		if (check()) return;
		await Bun.sleep(50);
	}
	throw new Error(`Timed out waiting for ${label}`);
}

/**
 * A collection declared `namespaced: false` is stored, read and notified under
 * the global namespace, so a subscription in one namespace must see rows
 * written from another namespace — including later updates, not just the
 * initial snapshot.
 */
export async function run(port: number): Promise<void> {
	const writer = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	const reader = new ZyncBaseClient(`ws://127.0.0.1:${port}`);

	try {
		await Promise.all([writer.connect(), reader.connect()]);
		await writer.setNamespace("public");
		await reader.setNamespace("other");

		await writer.set("public", ["globals", "one"], { title: "from writer" });

		const titles: string[] = [];
		let handle: ListenHandle | undefined;
		try {
			handle = await reader.store.listen(
				["globals", "one"],
				(value: unknown) => {
					const title = (value as { title?: string } | null)?.title;
					if (typeof title === "string") titles.push(title);
				},
			);

			await waitFor("the initial global row", () =>
				titles.includes("from writer"),
			);

			await writer.set("public", ["globals", "one"], { title: "after update" });
			await waitFor("the live delta for the global row", () =>
				titles.includes("after update"),
			);
		} finally {
			if (handle) await handle.unlisten();
		}

		console.log("E2E global-collection subscription passed.");
	} finally {
		reader.close();
		writer.close();
	}
}
