"use client";

// React bindings for @zyncbase/client. Every hook is a reactive view over an
// existing client primitive; see specs/api-design/react-api.md for the contract.

import type { ReactNode } from "react";
import {
	createContext,
	createElement,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useRef,
	useState,
} from "react";

import type { ZyncBaseClient } from "../client.js";
import type { ZyncBaseError } from "../errors.js";
import type {
	ActionCallOptions,
	ActionName,
	ActionParams,
	ActionReturns,
	ClientEvents,
	CollectionsOf,
	ConnectionStatus,
	ListenHandle,
	Presence,
	PresenceEntry,
	QueryOptionsFor,
	SchemaLike,
	Store,
	SubscriptionHandle,
} from "../types.js";

// ─── Public types ────────────────────────────────────────────────────────────

/** Triad returned by `useQuery`. */
export interface QueryState<R> {
	data: R;
	isLoading: boolean;
	error: ZyncBaseError | null;
}

/** Triad returned by `useListen`. */
export interface ListenState<V> {
	value: V;
	isLoading: boolean;
	error: ZyncBaseError | null;
}

/** Bound, memoized action caller returned by `useAction`. */
export type BoundAction<A, K extends string> = [A] extends [never]
	? (
			params?: Record<string, unknown>,
			options?: ActionCallOptions,
		) => Promise<unknown>
	: (
			params: ActionParams<A, K>,
			options?: ActionCallOptions,
		) => Promise<ActionReturns<A, K>>;

/** Connection surface returned by `useSyncStatus`. */
export interface SyncStatus {
	status: ConnectionStatus;
	synced: boolean;
}

type QueryRows<S extends object, C extends string> = ReturnType<
	SubscriptionHandle<S, C>["getSnapshot"]
>;
type ListenValue<S extends object, P> = ReturnType<
	ListenHandle<S, P>["getSnapshot"]
>;
type SubscribeOptions<
	S extends object,
	C extends CollectionsOf<S>,
> = QueryOptionsFor<S, C>;
type PresenceData<P> = Parameters<Presence<P>["set"]>[0];

const EMPTY_ROWS: never[] = [];

// ─── Canonical option keying ─────────────────────────────────────────────────

function stableStringify(value: unknown): string {
	if (value === null) return "null";
	if (typeof value !== "object") return String(JSON.stringify(value));
	if (Array.isArray(value)) {
		return `[${value.map(stableStringify).join(",")}]`;
	}
	const entries = Object.entries(value as Record<string, unknown>).sort(
		([a], [b]) => (a < b ? -1 : a > b ? 1 : 0),
	);
	return `{${entries
		.map(([key, entry]) => `${JSON.stringify(key)}:${stableStringify(entry)}`)
		.join(",")}}`;
}

function queryKey(collection: string, options: unknown): string {
	return `${collection}\u0000${stableStringify(options)}`;
}

// ─── Presence hub (one wire subscription per client, refcounted) ────────────

interface PresenceHub {
	listeners: Set<(entries: readonly unknown[]) => void>;
	snapshot: readonly unknown[];
	unsubscribe: (() => Promise<void>) | null;
	refs: number;
}

const presenceHubs = new WeakMap<object, PresenceHub>();

// ─── Factory ────────────────────────────────────────────────────────────────

/**
 * Creates a typed set of React bindings. Apps with a generated schema call this
 * once: `createZyncBaseReact<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>()`.
 * The module-level exports are the same hooks with loose types.
 */
export function createZyncBaseReact<
	S extends object = SchemaLike,
	A = never,
	P = never,
>() {
	type Client = ZyncBaseClient<S, A, P>;
	const ClientContext = createContext<Client | null>(null);

	function ZyncBaseProvider(props: { client: Client; children?: ReactNode }) {
		return createElement(
			ClientContext.Provider,
			{ value: props.client },
			props.children,
		);
	}

	function useClient(): Client {
		const client = useContext(ClientContext);
		if (client === null) {
			throw new Error(
				"ZyncBase React hooks must be used inside <ZyncBaseProvider client={...}> " +
					"from @zyncbase/client/react. See specs/api-design/react-api.md.",
			);
		}
		return client;
	}

	function useQuery<C extends CollectionsOf<S>>(
		collection: C,
		options: SubscribeOptions<S, C> | "skip",
	): QueryState<QueryRows<S, C>> {
		const client = useClient();
		const skipped = options === "skip";
		const key = skipped ? null : queryKey(collection, options);
		const [state, setState] = useState<{
			key: string;
			data: QueryRows<S, C>;
			isLoading: boolean;
			error: ZyncBaseError | null;
		} | null>(null);
		const empty = useMemo(() => EMPTY_ROWS as unknown as QueryRows<S, C>, []);

		// biome-ignore lint/correctness/useExhaustiveDependencies: canonical key fully describes the subscription; object identity must not re-subscribe.
		useEffect(() => {
			if (key === null) return;
			let disposed = false;
			let handle: SubscriptionHandle<S, C> | null = null;
			client.store
				.subscribe(collection, options as SubscribeOptions<S, C>, (rows) => {
					if (disposed) return;
					setState({ key, data: rows, isLoading: false, error: null });
				})
				.then((resolved) => {
					if (disposed) {
						void resolved.unsubscribe().catch(() => {});
						return;
					}
					handle = resolved;
					const seed = resolved.getSnapshot();
					if (seed.length > 0) {
						setState((prev) =>
							prev === null || prev.key !== key || prev.isLoading
								? { key, data: seed, isLoading: false, error: null }
								: prev,
						);
					}
				})
				.catch((error: unknown) => {
					if (disposed) return;
					setState({
						key,
						data: empty,
						isLoading: false,
						error: error as ZyncBaseError,
					});
				});
			return () => {
				disposed = true;
				if (handle !== null) {
					void handle.unsubscribe().catch(() => {});
				}
			};
			// The canonical key fully describes the subscription inputs.
		}, [client, key]);

		if (key === null) {
			return { data: empty, isLoading: false, error: null };
		}
		if (state !== null && state.key === key) {
			return {
				data: state.data,
				isLoading: state.isLoading,
				error: state.error,
			};
		}
		return { data: empty, isLoading: true, error: null };
	}

	function useListen<Pth extends Parameters<Store<S>["listen"]>[0]>(
		path: Pth,
	): ListenState<ListenValue<S, Pth>> {
		const client = useClient();
		const key = stableStringify(path);
		const [state, setState] = useState<{
			key: string;
			value: ListenValue<S, Pth>;
			isLoading: boolean;
			error: ZyncBaseError | null;
		} | null>(null);

		// biome-ignore lint/correctness/useExhaustiveDependencies: serialized path fully describes the registration.
		useEffect(() => {
			let disposed = false;
			let handle: ListenHandle<S, Pth> | null = null;
			client.store
				.listen(path, (value) => {
					if (disposed) return;
					setState({ key, value, isLoading: false, error: null });
				})
				.then((resolved) => {
					if (disposed) {
						void resolved.unlisten().catch(() => {});
						return;
					}
					handle = resolved;
					const seed = resolved.getSnapshot();
					if (seed !== undefined) {
						setState((prev) =>
							prev === null || prev.key !== key || prev.isLoading
								? { key, value: seed, isLoading: false, error: null }
								: prev,
						);
					}
				})
				.catch((error: unknown) => {
					if (disposed) return;
					setState({
						key,
						value: undefined as ListenValue<S, Pth>,
						isLoading: false,
						error: error as ZyncBaseError,
					});
				});
			return () => {
				disposed = true;
				if (handle !== null) {
					void handle.unlisten().catch(() => {});
				}
			};
			// The serialized path fully describes the registration inputs.
		}, [client, key]);

		if (state !== null && state.key === key) {
			return {
				value: state.value,
				isLoading: state.isLoading,
				error: state.error,
			};
		}
		return {
			value: undefined as ListenValue<S, Pth>,
			isLoading: true,
			error: null,
		};
	}

	function useAction<K extends ActionName<A>>(
		name: K,
		options?: ActionCallOptions,
	): BoundAction<A, K> {
		const client = useClient();
		const optionsRef = useRef(options);
		useEffect(() => {
			optionsRef.current = options;
		});
		const call = client.actions.call.bind(client.actions) as unknown as (
			action: string,
			params?: Record<string, unknown>,
			callOptions?: ActionCallOptions,
		) => Promise<unknown>;
		// biome-ignore lint/correctness/useExhaustiveDependencies: callback identity must stay stable; `call` is rebound each render.
		return useCallback(
			((params?: Record<string, unknown>, callOptions?: ActionCallOptions) =>
				call(
					name,
					params,
					callOptions ?? optionsRef.current,
				)) as unknown as BoundAction<A, K>,
			[client, name],
		);
	}

	function usePresence(): {
		mine: PresenceEntry<P> | undefined;
		peers: PresenceEntry<P>[];
		publish: (data: PresenceData<P>) => Promise<void>;
	} {
		const client = useClient();
		const [snapshot, setSnapshot] = useState<readonly unknown[]>([]);
		const [, bump] = useState(0);

		useEffect(() => {
			let hub = presenceHubs.get(client);
			if (hub === undefined) {
				const created: PresenceHub = {
					listeners: new Set(),
					snapshot: [],
					unsubscribe: null,
					refs: 0,
				};
				hub = created;
				presenceHubs.set(client, created);
				client.presence
					.subscribe((users) => {
						created.snapshot = users;
						for (const listener of created.listeners) {
							listener(users);
						}
					})
					.then((unsubscribe) => {
						// Ack arrived after the last consumer unmounted (StrictMode
						// double-invoke or a fast unmount): release the wire sub now.
						if (created.refs === 0) {
							void unsubscribe().catch(() => {});
							return;
						}
						created.unsubscribe = unsubscribe;
					})
					.catch(() => {
						// Drop the dead hub so a later mount retries instead of
						// reusing a hub that never subscribed.
						if (presenceHubs.get(client) === created) {
							presenceHubs.delete(client);
						}
					});
			}
			const active = hub;
			active.refs += 1;
			active.listeners.add(setSnapshot);
			setSnapshot(active.snapshot);
			return () => {
				active.listeners.delete(setSnapshot);
				active.refs -= 1;
				if (active.refs === 0) {
					if (presenceHubs.get(client) === active) {
						presenceHubs.delete(client);
					}
					void active.unsubscribe?.().catch(() => {});
					active.unsubscribe = null;
				}
			};
		}, [client]);

		const publish = useCallback(
			async (data: PresenceData<P>) => {
				await client.presence.set(data);
				// Self broadcasts do not fire the wire subscription; re-render so
				// `mine` (read from the local presence cache) reflects the publish.
				// A counter keeps `snapshot` identity stable for the peers memo.
				bump((count) => count + 1);
			},
			[client],
		);

		const localUserId = client.presence.localUserId;
		const mine =
			localUserId === null
				? undefined
				: (client.presence.get(localUserId) as PresenceEntry<P> | undefined);
		const peers = useMemo(
			() =>
				snapshot.filter(
					(entry) => (entry as PresenceEntry<P>).userId !== localUserId,
				) as PresenceEntry<P>[],
			[snapshot, localUserId],
		);

		return { mine, peers, publish };
	}

	function useSyncStatus(): SyncStatus {
		const client = useClient();
		const [state, setState] = useState<SyncStatus>(() => ({
			status: client.status,
			synced: false,
		}));

		useEffect(() => {
			const onStatus: ClientEvents["statusChange"] = (status) => {
				setState((previous) => ({ ...previous, status }));
			};
			const onSynced: ClientEvents["synced"] = () => {
				setState((previous) =>
					previous.synced ? previous : { ...previous, synced: true },
				);
			};
			const onDown: ClientEvents["disconnected"] = () => {
				setState((previous) =>
					previous.synced ? { ...previous, synced: false } : previous,
				);
			};
			const onReconnecting: ClientEvents["reconnecting"] = () => {
				setState((previous) =>
					previous.synced ? { ...previous, synced: false } : previous,
				);
			};
			client.on("statusChange", onStatus);
			client.on("synced", onSynced);
			client.on("reconnected", onSynced);
			client.on("disconnected", onDown);
			client.on("reconnecting", onReconnecting);
			return () => {
				client.off("statusChange", onStatus);
				client.off("synced", onSynced);
				client.off("reconnected", onSynced);
				client.off("disconnected", onDown);
				client.off("reconnecting", onReconnecting);
			};
		}, [client]);

		return state;
	}

	return {
		ZyncBaseProvider,
		useClient,
		useQuery,
		useListen,
		useAction,
		usePresence,
		useSyncStatus,
	};
}

// ─── Loose defaults (no generated schema) ───────────────────────────────────

const defaultBindings = createZyncBaseReact();

export const ZyncBaseProvider = defaultBindings.ZyncBaseProvider;
export const useClient = defaultBindings.useClient;
export const useQuery = defaultBindings.useQuery;
export const useListen = defaultBindings.useListen;
export const useAction = defaultBindings.useAction;
export const usePresence = defaultBindings.usePresence;
export const useSyncStatus = defaultBindings.useSyncStatus;
