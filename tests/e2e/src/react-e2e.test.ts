import { GlobalRegistrator } from "@happy-dom/global-registrator";

// Keep Bun's native WebSocket and fetch: the SDK talks to a real server, and
// only React rendering needs DOM. happy-dom would route both through its own
// client (CORS preflights, no real socket).
const NativeWebSocket = globalThis.WebSocket;
const NativeFetch = globalThis.fetch;
GlobalRegistrator.register();
globalThis.WebSocket = NativeWebSocket;
globalThis.fetch = NativeFetch;

import {
	afterAll,
	beforeAll,
	describe,
	expect,
	setDefaultTimeout,
	test,
} from "bun:test";
import { createClient } from "@zyncbase/client";
import {
	useListen,
	useQuery,
	useSyncStatus,
	ZyncBaseProvider,
} from "@zyncbase/client/react";
import { createElement } from "react";
import {
	buildServerIfNeeded,
	cleanupE2EArtifacts,
	resetE2ERoots,
	runE2ETest,
	withServer,
} from "./harness";

const { act, render, waitFor } = await import("@testing-library/react");

setDefaultTimeout(90_000);

beforeAll(
	() => {
		buildServerIfNeeded();
		resetE2ERoots();
	},
	{ timeout: 300_000 },
);

afterAll(() => {
	cleanupE2EArtifacts();
});

interface ProbeRender {
	titles: string[];
	listenTitle: string | undefined;
	status: string;
	synced: boolean;
}

describe("React hooks E2E", () => {
	test("live query, listen, and sync status over a real server", async () => {
		await runE2ETest("React hooks", async (ctx) => {
			await withServer(
				ctx,
				{
					schemaPath: ctx.schemaPath("schema-sync.json"),
					dataDir: ctx.dataPath("react"),
					configName: "zyncbase-config-react.json",
					authPath: ctx.schemaPath("auth-allow-all.json"),
				},
				async ({ port }) => {
					const client = createClient({
						url: `ws://127.0.0.1:${port}`,
						auth: { anonymous: true },
					});

					const renders: ProbeRender[] = [];
					function Probe() {
						const query = useQuery("tasks", {});
						const listen = useListen("tasks.react-1.title");
						const status = useSyncStatus();
						renders.push({
							titles: query.data.map((row) =>
								String((row as { title?: unknown }).title ?? ""),
							),
							listenTitle: listen.value as string | undefined,
							status: status.status,
							synced: status.synced,
						});
						return null;
					}

					// Hooks mount before connect: registrations queue until the
					// session is ready, and `synced` fires while subscribed.
					const tree = render(
						createElement(ZyncBaseProvider, { client }, createElement(Probe)),
					);

					let reference: Awaited<
						ReturnType<typeof client.store.subscribe>
					> | null = null;
					try {
						await act(async () => {
							await client.connect();
						});

						await waitFor(
							() => {
								const last = renders[renders.length - 1];
								expect(last?.status).toBe("connected");
								expect(last?.synced).toBe(true);
							},
							{ timeout: 10_000 },
						);

						await act(async () => {
							await client.store.set("tasks.react-1", {
								title: "hello",
							});
						});

						await waitFor(
							() => {
								const last = renders[renders.length - 1];
								expect(last?.listenTitle).toBe("hello");
								expect(last?.titles).toContain("hello");
							},
							{ timeout: 10_000 },
						);

						reference = await client.store.subscribe("tasks", {}, () => {});
						await waitFor(
							() => {
								const titles = reference
									?.getSnapshot()
									.map((row) =>
										String((row as { title?: unknown }).title ?? ""),
									);
								expect(titles).toContain("hello");
							},
							{ timeout: 10_000 },
						);

						const last = renders[renders.length - 1];
						expect(last.titles).toEqual(
							reference
								.getSnapshot()
								.map((row) => String((row as { title?: unknown }).title ?? "")),
						);
					} finally {
						tree.unmount();
						if (reference !== null) {
							await reference.unsubscribe();
						}
						client.disconnect();
					}
				},
			);
		});
	});
});
