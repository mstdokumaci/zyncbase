import {
	createClient,
	type SubscriptionHandle,
	type ZyncBaseClient,
} from "@zyncbase/client";
import { LocalMotion, type MotionDot } from "./motion";
import {
	CHUNK,
	type ChunkRow,
	COLUMNS,
	type Country,
	chunkIndex,
	countryName,
	type Direction,
	type Dot,
	HEIGHT,
	LITTLE_ENDIAN,
	MAX_COUNTRIES,
	NAMESPACE,
	playerName,
	readDots,
	readOwners,
	terrain,
	type UserRow,
	WIDTH,
	wrapX,
} from "./shared";

function element<T extends HTMLElement>(id: string): T {
	const result = document.getElementById(id);
	if (!result) throw new Error(`Missing element: ${id}`);
	return result as T;
}
const canvas = element<HTMLCanvasElement>("map");
const context = canvas.getContext("2d", { alpha: false });
if (!context) throw new Error("Your browser needs Canvas support");
const ctx = context;
const connection = element("connection");
const lobby = element("lobby");
const countryChoice = element<HTMLSelectElement>("country-choice");
const countryInput = element<HTMLInputElement>("country");
const countries = new Map<number, Country>();
// Cold roster from the users table, keyed by identity: one row per live
// player plus 10s grace tombstones. Updated only on admission, chunk
// crossing, and leave — never per tick.
const players = new Map<string, UserRow>();
let playersUnsub: SubscriptionHandle | undefined;
const chunks = new Map<
	number,
	{ image: HTMLCanvasElement; dots: Dot[]; owners: Uint16Array }
>();
const subscriptions = new Map<number, () => void>();
const held = new Map<string, Direction>();
let client: ZyncBaseClient | undefined;
let online = false;
let playing = false;
let joining = false;
let worldReady = false;
let selectedCountryCode: number | undefined;
let lobbyCountries: Country[] = [];
let availableSlots = 0;
let myId = "",
	name = "",
	nickname = "",
	seq = 0,
	lastChangeAt = 0;
let direction: Direction = "idle";
// Heading used to choose the prefetch edge. Kept after release so stopping
// does not drop the leading margin and churn subscriptions on the next move.
let prefetchDirection: Direction = "idle";
let motion: LocalMotion | undefined;
let camera = { x: WIDTH / 2, y: HEIGHT / 2 };
let scale = 8;
let width = innerWidth,
	height = innerHeight;
let lastOwnDot = 0;
let locating = false;
// Bumped when a session ends so in-flight locate() failures cannot write
// status text into the lobby that started after them.
let sessionGeneration = 0;
// Dirty-frame rendering: the scene repaints only when something it draws
// changes. Presence heartbeat runs on its own timer, not as a frame side
// effect, so it survives idle frames.
let dirty = true;
let drawnX = Number.NaN;
let drawnY = Number.NaN;
let lastSubBounds = "";
let heartbeat: ReturnType<typeof setInterval> | undefined;
let admissionTimer: ReturnType<typeof setTimeout> | undefined;
let latestCountries: Country[] = [];
const FRAME_MS = 1000 / 30;
// A chunk subscription costs a listen round trip, so keep one extra chunk on
// the leading edge of travel; idle needs no margin.
const PREFETCH_CHUNKS = 1;
let lastFrame = 0;
const OFFLINE = "The world is offline";
const TAGLINE = "A shared world. One pixel at a time.";

function updateCountryChoice() {
	const creating = countryChoice.value === "new";
	const country = lobbyCountries.find(
		(country) => String(country.code) === countryChoice.value,
	);
	element("new-country").hidden = !creating;
	countryInput.disabled = !creating;
	countryInput.required = creating;
	element("country-preview").hidden = !country;
	if (country) {
		element("country-swatch").style.background = country.color;
		element("country-detail").textContent =
			`${country.name} · ${country.count.toLocaleString()} land pixels`;
	}
	element<HTMLButtonElement>("join-button").disabled =
		joining || !worldReady || (!creating && !country);
}
countryChoice.addEventListener("change", updateCountryChoice);

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: one reconciliation pass must sync slots, rows, and the native picker.
function showLobbyCountries(all: Country[]) {
	const rows = all.filter((country) => !country.is_bot);
	rows.sort((a, b) => a.name.localeCompare(b.name));
	const slots = MAX_COUNTRIES - all.length;
	availableSlots = slots;
	// Keep the native picker intact during polling unless its options change.
	if (
		countryChoice.options.length === 1 ||
		rows.length !== lobbyCountries.length ||
		rows.some((country, i) => country.code !== lobbyCountries[i]?.code)
	) {
		const selected = countryChoice.value;
		const create = new Option("＋ Create a country", "new");
		create.disabled = slots === 0;
		countryChoice.replaceChildren(
			new Option("Choose a country…", ""),
			...rows.map((country) => new Option(country.name, String(country.code))),
			create,
		);
		countryChoice.value = selected;
		if (!rows.length && slots > 0) countryChoice.value = "new";
	}
	// Slots can change without the option list changing (bots come and go),
	// so keep the create option and its selection in sync on every poll.
	const createOption = countryChoice.options.item(
		countryChoice.options.length - 1,
	);
	if (createOption?.value === "new") {
		createOption.disabled = slots === 0;
		if (createOption.disabled && countryChoice.value === "new")
			countryChoice.value = "";
	}
	lobbyCountries = rows;
	countryChoice.disabled = false;
	element("country-slots").textContent = slots
		? `${all.length} / ${MAX_COUNTRIES} countries · ${slots} ${slots === 1 ? "slot" : "slots"} available`
		: `All ${MAX_COUNTRIES} slots are taken. Join an existing country.`;
	updateCountryChoice();
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: in-flight health polls must not alter the UI after joining starts.
async function checkHealth() {
	if (playing || joining) return;
	try {
		const response = await fetch("/health", {
			signal: AbortSignal.timeout(3000),
		});
		const health = await response.json();
		if (playing || joining) return;
		if (!response.ok || health.ready !== true) throw new Error();
		worldReady = true;
		showLobbyCountries(health.countries);
		if (element("error").textContent === OFFLINE)
			element("error").textContent = "";
		if (connection.textContent.startsWith(OFFLINE))
			connection.textContent = TAGLINE;
	} catch {
		if (playing || joining) return;
		worldReady = false;
		countryChoice.disabled = true;
		updateCountryChoice();
		element("error").textContent = OFFLINE;
		connection.textContent = `${OFFLINE} · Retrying…`;
	}
}
void checkHealth();
setInterval(() => void checkHealth(), 5000);

const land = terrain();
const base = document.createElement("canvas");
base.width = WIDTH;
base.height = HEIGHT;
const baseContext = base.getContext("2d");
if (!baseContext) throw new Error("Canvas unavailable");
const pixels = baseContext.createImageData(WIDTH, HEIGHT);
for (let i = 0; i < land.length; i++) {
	pixels.data.set(land[i] ? [80, 87, 94, 255] : [19, 37, 52, 255], i * 4);
}
baseContext.putImageData(pixels, 0, 0);

function resize() {
	width = innerWidth;
	height = innerHeight;
	const ratio = Math.min(devicePixelRatio, 2);
	canvas.width = Math.round(width * ratio);
	canvas.height = Math.round(height * ratio);
	ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
	ctx.imageSmoothingEnabled = false;
	dirty = true;
	if (playing) updateSubscriptions();
}
addEventListener("resize", resize);
resize();

// One scratch ImageData reused by every chunk update: putImageData copies
// synchronously, so a single buffer avoids per-tick allocations. Colors are
// packed once per country code; the cache is dropped when the palette changes.
const chunkImageData = new ImageData(CHUNK, CHUNK);
const chunkPixels = new Uint32Array(chunkImageData.data.buffer);
const chunkColors = new Map<number, number>();

function packedColor(code: number) {
	let color = chunkColors.get(code);
	if (color === undefined) {
		const hex = countries.get(code)?.color ?? "#b7c4bb";
		const r = Number.parseInt(hex.slice(1, 3), 16);
		const g = Number.parseInt(hex.slice(3, 5), 16);
		const b = Number.parseInt(hex.slice(5, 7), 16);
		color = LITTLE_ENDIAN
			? ((0xff << 24) | (b << 16) | (g << 8) | r) >>> 0
			: ((r << 24) | (g << 16) | (b << 8) | 0xff) >>> 0;
		chunkColors.set(code, color);
	}
	return color;
}

function chunkImage(owners: Uint16Array, canvas?: HTMLCanvasElement) {
	const image = canvas ?? document.createElement("canvas");
	if (!canvas) image.width = image.height = CHUNK;
	const draw = image.getContext("2d");
	if (!draw) throw new Error("Canvas unavailable");
	chunkPixels.fill(0);
	for (let i = 0; i < owners.length; i++)
		if (owners[i]) chunkPixels[i] = packedColor(owners[i]);
	draw.putImageData(chunkImageData, 0, 0);
	return image;
}

function myCountry(): number {
	return players.get(myId)?.country_id ?? selectedCountryCode ?? 0;
}

function toMotion(dot: Dot): MotionDot {
	return { ...dot, country_id: myCountry() };
}

function receive(row: ChunkRow) {
	const index = Number(row.id);
	if (!Number.isSafeInteger(index)) return;
	const dots = readDots(row.dots);
	const owners = readOwners(row.owners);
	const previous = chunks.get(index);
	chunks.set(index, {
		dots,
		owners,
		image: chunkImage(owners, previous?.image),
	});
	dirty = true;
	const self = dots.find((dot) => dot.player_id === myId);
	const now = performance.now();
	const moving = online ? direction : "idle";
	const selfMotion = self ? toMotion(self) : undefined;
	if (motion && selfMotion) motion.update(selfMotion, moving, now);
	if (!self || !selfMotion) return;
	if (lastOwnDot === 0) {
		clearTimeout(admissionTimer);
		// First sighting acks our input; latency uses our own change clock.
		connection.textContent = `Live · ${Math.max(0, now - lastChangeAt)} ms input → view`;
	}
	lastOwnDot = now;
	if (!motion) motion = new LocalMotion(selfMotion, moving, now, land, ownerAt);
	const position = motion.position(lastOwnDot);
	camera = { x: position.x + 0.5, y: position.y + 0.5 };
	const country = countries.get(myCountry());
	element("coordinates").textContent =
		`${country?.name ?? name} · ${self.x}, ${self.y}`;
	maybeUpdateSubscriptions();
}

function ownerAt(x: number, y: number) {
	const wrapped = wrapX(x);
	return chunks.get(chunkIndex(wrapped, y))?.owners[
		(y % CHUNK) * CHUNK + (wrapped % CHUNK)
	];
}

// A world copy is WIDTH wide but chunk columns are CHUNK wide; the last column
// is partial, so the wrapped columns come from world copies rather than a
// modulo of the chunk column. Straddling the seam can need columns from both
// ends at once.
function visibleChunks() {
	const visible = new Set<number>();
	const { xMin, xMax, yMin, yMax } = subscriptionBounds();
	const top = Math.max(0, Math.floor(yMin / CHUNK));
	const bottom = Math.min(
		Math.ceil(HEIGHT / CHUNK) - 1,
		Math.floor(yMax / CHUNK),
	);
	for (let k = Math.floor(xMin / WIDTH); k <= Math.floor(xMax / WIDTH); k++) {
		const start = Math.max(0, xMin - k * WIDTH),
			end = Math.min(WIDTH, xMax - k * WIDTH);
		if (start >= end) continue;
		const first = Math.floor(start / CHUNK);
		const last = Math.min(COLUMNS - 1, Math.ceil(end / CHUNK) - 1);
		for (let col = first; col <= last; col++)
			for (let y = top; y <= bottom; y++) visible.add(y * COLUMNS + col);
	}
	return visible;
}

// Extend the view one chunk in the direction of travel so a tile is subscribed
// (and its first row delivered) before its pixels reach the viewport edge. The
// heading persists while idle so a stop keeps the margin it already paid for.
function subscriptionBounds() {
	const halfWidth = width / scale / 2;
	const halfHeight = height / scale / 2;
	const margin = PREFETCH_CHUNKS * CHUNK;
	const heading = direction === "idle" ? prefetchDirection : direction;
	return {
		xMin: camera.x - halfWidth - (heading === "left" ? margin : 0),
		xMax: camera.x + halfWidth + (heading === "right" ? margin : 0),
		yMin: camera.y - halfHeight - (heading === "up" ? margin : 0),
		yMax: camera.y + halfHeight + (heading === "down" ? margin : 0),
	};
}

function subscriptionKey() {
	const { xMin, xMax, yMin, yMax } = subscriptionBounds();
	return `${Math.floor(xMin / CHUNK)},${Math.floor(xMax / CHUNK)},${Math.floor(yMin / CHUNK)},${Math.floor(yMax / CHUNK)}`;
}

function updateSubscriptions() {
	// Record the served bounds even when not playing so the next frame does not
	// retry a refresh that has nothing to do.
	lastSubBounds = subscriptionKey();
	if (!client || !playing) return;
	const visible = visibleChunks();
	for (const [index, unsub] of subscriptions) {
		if (visible.has(index)) continue;
		unsub();
		subscriptions.delete(index);
		chunks.delete(index);
	}
	for (const index of visible) {
		if (subscriptions.has(index)) continue;
		// Direct document listens: chunk ids are the store primary keys, so
		// no secondary index or query-subscription group is needed per tile.
		const key = index;
		const unsub = client.store.listen(["chunks", String(index)], (row) => {
			if (!subscriptions.has(key)) return;
			if (row) receive(row as ChunkRow);
			else {
				chunks.delete(key);
				dirty = true;
			}
		});
		subscriptions.set(index, unsub);
	}
}

// Recompute tiles only when the prefetched bounds cross a chunk edge: chunk
// updates arrive at tick rate and must not rescan subscriptions each time.
function maybeUpdateSubscriptions() {
	if (subscriptionKey() === lastSubBounds) return;
	updateSubscriptions();
}

function scoreboard(rows: Country[]) {
	// ponytail: roster rows include 10s grace tombstones, so a departed player
	// keeps counting until expiry; filtering needs a live flag from the server.
	const headcount = new Map<number, number>();
	for (const player of players.values())
		headcount.set(
			player.country_id,
			(headcount.get(player.country_id) ?? 0) + 1,
		);
	const paletteChanged = rows.some(
		(row) => countries.get(row.code)?.color !== row.color,
	);
	countries.clear();
	for (const row of rows) countries.set(row.code, row);
	element("country-count").textContent = String(rows.length);
	element("countries").replaceChildren(
		...rows
			.sort((a, b) => b.count - a.count)
			.map((country) => {
				const li = document.createElement("li");
				li.classList.toggle(
					"local",
					country.name.toLowerCase() === name.toLowerCase(),
				);
				const swatch = document.createElement("span");
				swatch.className = "swatch";
				swatch.style.background = country.color;
				const label = document.createElement("span");
				label.className = "name";
				label.textContent = country.name;
				const roster = document.createElement("span");
				roster.className = "players";
				roster.title = "Players";
				roster.textContent = String(headcount.get(country.code) ?? 0);
				const score = document.createElement("span");
				score.className = "score";
				score.textContent = country.count.toLocaleString();
				li.append(swatch, label, roster, score);
				return li;
			}),
	);
	if (paletteChanged) {
		chunkColors.clear();
		dirty = true;
		for (const chunk of chunks.values())
			chunk.image = chunkImage(chunk.owners, chunk.image);
	}
}

function publish(changed = false) {
	if (changed)
		motion?.update(motion.dot, online ? direction : "idle", performance.now());
	if (!online || !client) return;
	if (changed) {
		seq++;
		lastChangeAt = performance.now();
	}
	client.presence.set({
		name: nickname,
		countryCode: selectedCountryCode,
		direction,
		seq,
	});
}

function movement() {
	const next = [...held.values()].at(-1) ?? "idle";
	if (next === direction) return;
	direction = next;
	if (next !== "idle") prefetchDirection = next;
	publish(true);
	updateSubscriptions();
}

function release() {
	held.clear();
	direction = "idle";
	publish(true);
}

const keys: Record<string, Direction> = {
	KeyW: "up",
	ArrowUp: "up",
	KeyS: "down",
	ArrowDown: "down",
	KeyA: "left",
	ArrowLeft: "left",
	KeyD: "right",
	ArrowRight: "right",
};
window.addEventListener("keydown", (event) => {
	if (!playing || !online || !keys[event.code]) return;
	event.preventDefault();
	if (event.repeat) return;
	held.set(event.code, keys[event.code]);
	movement();
});
window.addEventListener("keyup", (event) => {
	if (held.delete(event.code)) {
		event.preventDefault();
		movement();
	}
});
addEventListener("blur", release);
document.addEventListener("visibilitychange", () => {
	release();
	dirty = true;
});
addEventListener("pagehide", () => {
	release();
	client?.disconnect();
});
for (const button of document.querySelectorAll<HTMLButtonElement>(
	"[data-direction]",
)) {
	button.addEventListener("pointerdown", (event) => {
		button.setPointerCapture(event.pointerId);
		held.set(
			`pointer:${event.pointerId}`,
			button.dataset.direction as Direction,
		);
		movement();
	});
	for (const type of ["pointerup", "pointercancel", "lostpointercapture"])
		button.addEventListener(type, (event) => {
			held.delete(`pointer:${(event as PointerEvent).pointerId}`);
			movement();
		});
}

function zoom(change: number) {
	if (!playing) return;
	scale = Math.min(16, Math.max(2, scale + change));
	element("zoom-label").textContent = `${scale}×`;
	dirty = true;
	updateSubscriptions();
}
element("zoom-in").addEventListener("click", () => zoom(2));
element("zoom-out").addEventListener("click", () => zoom(-2));

function returnToLobby(message: string) {
	sessionGeneration++;
	clearTimeout(admissionTimer);
	clearInterval(heartbeat);
	heartbeat = undefined;
	client?.disconnect();
	for (const unsub of subscriptions.values()) unsub();
	subscriptions.clear();
	chunks.clear();
	playersUnsub?.unsubscribe();
	playersUnsub = undefined;
	players.clear();
	playing = online = false;
	lobby.hidden = false;
	element("scoreboard").hidden = true;
	element("direction-pad").hidden = true;
	element("error").textContent = message;
	connection.textContent = "Ready when you are.";
	dirty = true;
	updateCountryChoice();
	void checkHealth();
}

// The roster can change between the lobby poll and presence admission.
function checkAdmission() {
	if (!playing || lastOwnDot !== 0) return;
	if (
		selectedCountryCode !== undefined &&
		!latestCountries.some((country) => country.code === selectedCountryCode)
	) {
		returnToLobby("That country is no longer available. Choose another one.");
		return;
	}
}

async function locate() {
	if (!client || !online || locating || performance.now() - lastOwnDot < 1500)
		return;
	const generation = sessionGeneration;
	locating = true;
	try {
		// O(1) self-locate: our own roster row names our chunk (spawn cell on
		// admission, chunk-entry cell after crossings, final cell as a grace
		// tombstone). No table scan; the visible-ring subscriptions deliver us.
		const me = (await client.store.get(["users", myId])) as unknown as
			| UserRow
			| undefined;
		if (
			me &&
			Number.isSafeInteger(me.lastX) &&
			Number.isSafeInteger(me.lastY) &&
			me.lastX >= 0 &&
			me.lastX < WIDTH &&
			me.lastY >= 0 &&
			me.lastY < HEIGHT
		) {
			camera = { x: me.lastX + 0.5, y: me.lastY + 0.5 };
			dirty = true;
			updateSubscriptions();
		}
	} catch (error) {
		if (generation === sessionGeneration)
			connection.textContent = `Connection interrupted: ${String(error)}`;
	} finally {
		locating = false;
	}
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: keep selection validation and connection cleanup together during admission.
element("join").addEventListener("submit", async (event) => {
	event.preventDefault();
	if (joining || playing || !worldReady) return;
	joining = true;
	updateCountryChoice();
	element("error").textContent = "";
	lastOwnDot = 0;
	latestCountries = [];
	clearTimeout(admissionTimer);
	try {
		nickname = playerName(element<HTMLInputElement>("player-name").value);
		const selected = lobbyCountries.find(
			(country) => String(country.code) === countryChoice.value,
		);
		selectedCountryCode = selected?.code;
		if (countryChoice.value === "new") {
			if (availableSlots === 0)
				throw new Error(
					"All country slots are taken. Join an existing country.",
				);
			name = countryName(countryInput.value);
			if (
				lobbyCountries.some(
					(country) => country.name.toLowerCase() === name.toLowerCase(),
				)
			)
				throw new Error(
					"That country already exists. Choose it from the list to join.",
				);
		} else {
			if (!selected) throw new Error("Choose a country to join.");
			name = selected.name;
		}
		const response = await fetch("/session", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(selected ? {} : { countryName: name }),
		});
		const session = await response.json();
		if (!response.ok) throw new Error(session.error);
		selectedCountryCode = selected?.code ?? session.countryCode;
		client = createClient({
			url: `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/ws`,
			auth: { token: session.token },
			storeNamespace: NAMESPACE,
			presenceNamespace: NAMESPACE,
		});
		client.on("error", (error) => {
			connection.textContent = `Connection issue: ${String(error)}`;
		});
		client.on("disconnected", () => {
			online = false;
			release();
			connection.textContent = "Disconnected · Reconnecting…";
		});
		client.on("connected", () => {
			if (playing) {
				online = true;
				release();
				connection.textContent = "Connected · Finding your dot…";
				void locate();
			}
		});
		await client.connect();
		// Identity comes from scope setup, not a table scan: the users table
		// now holds every roster row, so limit:1 would return anyone.
		myId = client.presence.localUserId ?? "";
		for (let i = 0; i < 30 && !myId; i++) {
			await new Promise((resolve) => setTimeout(resolve, 100));
			myId = client.presence.localUserId ?? "";
		}
		if (!myId) throw new Error("Could not resolve your player identity");
		playing = online = true;
		clearTimeout(admissionTimer);
		admissionTimer = setTimeout(checkAdmission, 3000);
		lobby.hidden = true;
		element("scoreboard").hidden = false;
		element("direction-pad").hidden = false;
		client.store.subscribe("countries", { limit: 1000 }, (rows) => {
			const list = rows as Country[];
			latestCountries = list;
			scoreboard(list);
		});
		// Cold roster, subscribed once: identity and country per dot, joined
		// at render. Fires only on admission, chunk crossing, and leave.
		playersUnsub?.unsubscribe();
		playersUnsub = client.store.subscribe("users", { limit: 2048 }, (rows) => {
			players.clear();
			for (const row of rows as UserRow[]) players.set(row.id, row);
			scoreboard(latestCountries);
			dirty = true;
		});
		motion = undefined;
		camera = { x: 933, y: 276 };
		release();
		updateSubscriptions();
		zoom(0);
		dirty = true;
		clearInterval(heartbeat);
		heartbeat = setInterval(() => {
			if (!playing || !online) return;
			publish();
			void locate();
		}, 500);
		connection.textContent = "Connected · Finding your dot…";
		void locate();
	} catch (error) {
		returnToLobby(error instanceof Error ? error.message : String(error));
	} finally {
		joining = false;
		updateCountryChoice();
	}
});

const visibleDots = new Map<string, Dot>();

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: draw the map layers and local-player marker in their visual order.
function draw(now: number) {
	requestAnimationFrame(draw);
	const elapsed = now - lastFrame;
	// Allow timestamp rounding at the frame boundary without accumulating drift.
	if (elapsed + 0.1 < FRAME_MS) return;
	const position = motion?.position(now);
	// Idle frames are identical: repaint only when the camera moved or a
	// mutation (chunk, roster, palette, resize) marked the scene dirty.
	const moved =
		position !== undefined && (position.x !== drawnX || position.y !== drawnY);
	if (!dirty && !moved) return;
	lastFrame += Math.floor((elapsed + 0.1) / FRAME_MS) * FRAME_MS;
	dirty = false;
	if (position) {
		drawnX = position.x;
		drawnY = position.y;
		camera = { x: position.x + 0.5, y: position.y + 0.5 };
	}
	maybeUpdateSubscriptions();
	const zoom = playing ? scale : Math.max(width / WIDTH, height / HEIGHT);
	const left = width / 2 - camera.x * zoom;
	const top = height / 2 - camera.y * zoom;
	const xMin = camera.x - width / zoom / 2,
		xMax = camera.x + width / zoom / 2;
	ctx.fillStyle = "#0d1822";
	ctx.fillRect(0, 0, width, height);
	// The world repeats every WIDTH: draw each visible copy so the map pans
	// forever and the seam stays seamless.
	const firstCopy = Math.floor(xMin / WIDTH),
		lastCopy = Math.floor(xMax / WIDTH);
	for (let k = firstCopy; k <= lastCopy; k++)
		ctx.drawImage(
			base,
			left + k * WIDTH * zoom,
			top,
			WIDTH * zoom,
			HEIGHT * zoom,
		);
	visibleDots.clear();
	for (const [index, chunk] of chunks) {
		const chunkX = (index % COLUMNS) * CHUNK,
			chunkY = Math.floor(index / COLUMNS) * CHUNK;
		for (
			let k = Math.floor((xMin - chunkX) / WIDTH);
			k <= Math.floor((xMax - chunkX) / WIDTH);
			k++
		)
			ctx.drawImage(
				chunk.image,
				left + (chunkX + k * WIDTH) * zoom,
				top + chunkY * zoom,
				CHUNK * zoom,
				CHUNK * zoom,
			);
		for (const dot of chunk.dots) visibleDots.set(dot.player_id, dot);
	}
	// Draw yourself last so nearby dots and names do not cover your marker.
	const self = visibleDots.get(myId) ?? motion?.dot;
	if (self) {
		visibleDots.delete(self.player_id);
		visibleDots.set(self.player_id, self);
	}
	for (const dot of visibleDots.values()) {
		const key = dot.player_id;
		// Simple client-side join: hot dot plus its cold roster row. Dots
		// without a row are mid-join/leave races; draw them neutrally once.
		const meta = players.get(key);
		const isBot = meta?.is_bot ?? false;
		const display =
			key === myId && position ? { x: position.x, y: position.y } : dot;
		// Draw the dot in whichever world copy is nearest the camera.
		const dotX = display.x + WIDTH * Math.round((camera.x - display.x) / WIDTH);
		const x = left + (dotX + 0.5) * zoom,
			y = top + (display.y + 0.5) * zoom;
		ctx.beginPath();
		const radius = Math.max(3, zoom * 0.48);
		if (isBot) ctx.rect(x - radius, y - radius, radius * 2, radius * 2);
		else ctx.arc(x, y, radius, 0, Math.PI * 2);
		ctx.fillStyle = (meta && countries.get(meta.country_id)?.color) ?? "white";
		ctx.fill();
		ctx.lineWidth = 2;
		ctx.strokeStyle = key === myId ? "#ffe3a0" : "#0d1822";
		ctx.stroke();
	}
	// Names in their own pass: font and text state change twice per frame
	// instead of once per visible player.
	ctx.textAlign = "center";
	ctx.lineJoin = "round";
	ctx.strokeStyle = "#0d1822";
	ctx.lineWidth = 3;
	ctx.font = "10px system-ui";
	ctx.fillStyle = "#bccacb";
	for (const dot of visibleDots.values()) {
		if (dot.player_id === myId) continue;
		const meta = players.get(dot.player_id);
		if (!meta?.name || meta.is_bot) continue;
		const dotX = dot.x + WIDTH * Math.round((camera.x - dot.x) / WIDTH);
		const x = left + (dotX + 0.5) * zoom,
			y = top + (dot.y + 0.5) * zoom;
		ctx.strokeText(meta.name, x, y - zoom - 7, 120);
		ctx.fillText(meta.name, x, y - zoom - 7, 120);
	}
	const selfMeta = players.get(myId);
	if (self && selfMeta?.name && !selfMeta.is_bot) {
		const display = position ?? self;
		const dotX = display.x + WIDTH * Math.round((camera.x - display.x) / WIDTH);
		const x = left + (dotX + 0.5) * zoom,
			y = top + (display.y + 0.5) * zoom;
		ctx.font = "bold 11px system-ui";
		ctx.fillStyle = "#ffe3a0";
		ctx.strokeText(selfMeta.name, x, y - zoom - 7, 120);
		ctx.fillText(selfMeta.name, x, y - zoom - 7, 120);
	}
}
requestAnimationFrame(draw);
