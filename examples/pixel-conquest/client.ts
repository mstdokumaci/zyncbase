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
	MAX_COUNTRIES,
	NAMESPACE,
	playerName,
	readDots,
	readOwners,
	terrain,
	type UserRow,
	WIDTH,
} from "./shared";

function element<T extends HTMLElement>(id: string): T {
	const result = document.getElementById(id);
	if (!result) throw new Error(`Missing element: ${id}`);
	return result as T;
}
const canvas = element<HTMLCanvasElement>("map");
const context = canvas.getContext("2d");
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
let myId = "",
	name = "",
	nickname = "",
	seq = 0,
	lastChangeAt = 0;
let direction: Direction = "idle";
let motion: LocalMotion | undefined;
let camera = { x: WIDTH / 2, y: HEIGHT / 2 };
let scale = 8;
let width = innerWidth,
	height = innerHeight;
let lastOwnDot = 0;
let locating = false;
let lastHeartbeat = 0;
let admissionTimer: ReturnType<typeof setTimeout> | undefined;
let latestCountries: Country[] = [];
const FRAME_MS = 1000 / 30;
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

function showLobbyCountries(all: Country[]) {
	const rows = all.filter((country) => !country.is_bot);
	rows.sort((a, b) => a.name.localeCompare(b.name));
	const slots = MAX_COUNTRIES - all.length;
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
		if (selected === "new" && !slots) countryChoice.value = "";
		if (!rows.length) countryChoice.value = "new";
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
	if (playing) updateSubscriptions();
}
addEventListener("resize", resize);
resize();

function chunkImage(owners: Uint16Array) {
	const image = document.createElement("canvas");
	image.width = image.height = CHUNK;
	const draw = image.getContext("2d");
	if (!draw) throw new Error("Canvas unavailable");
	for (let i = 0; i < owners.length; i++) {
		if (!owners[i]) continue;
		draw.fillStyle = countries.get(owners[i])?.color ?? "#b7c4bb";
		draw.fillRect(i % CHUNK, Math.floor(i / CHUNK), 1, 1);
	}
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
	chunks.set(index, { dots, owners, image: chunkImage(owners) });
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
	updateSubscriptions();
}

function ownerAt(x: number, y: number) {
	return chunks.get(chunkIndex(x, y))?.owners[
		(y % CHUNK) * CHUNK + (x % CHUNK)
	];
}

function visibleChunks() {
	const visible = new Set<number>();
	const left = Math.max(
		0,
		Math.floor((camera.x - width / scale / 2) / CHUNK) - 1,
	);
	const top = Math.max(
		0,
		Math.floor((camera.y - height / scale / 2) / CHUNK) - 1,
	);
	const right = Math.min(
		COLUMNS - 1,
		Math.floor((camera.x + width / scale / 2) / CHUNK) + 1,
	);
	const bottom = Math.min(
		Math.ceil(HEIGHT / CHUNK) - 1,
		Math.floor((camera.y + height / scale / 2) / CHUNK) + 1,
	);
	for (let y = top; y <= bottom; y++)
		for (let x = left; x <= right; x++) visible.add(y * COLUMNS + x);
	return visible;
}

function updateSubscriptions() {
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
			else chunks.delete(key);
		});
		subscriptions.set(index, unsub);
	}
}

function scoreboard(rows: Country[]) {
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
				const score = document.createElement("span");
				score.className = "score";
				score.textContent = country.count.toLocaleString();
				li.append(swatch, label, score);
				return li;
			}),
	);
	if (paletteChanged)
		for (const chunk of chunks.values()) chunk.image = chunkImage(chunk.owners);
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
	publish(true);
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
document.addEventListener("visibilitychange", release);
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
	updateSubscriptions();
}
element("zoom-in").addEventListener("click", () => zoom(2));
element("zoom-out").addEventListener("click", () => zoom(-2));

function returnToLobby(message: string) {
	clearTimeout(admissionTimer);
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
			updateSubscriptions();
		}
	} catch (error) {
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
			if (lobbyCountries.length >= MAX_COUNTRIES)
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
		});
		motion = undefined;
		camera = { x: 933, y: 276 };
		release();
		updateSubscriptions();
		zoom(0);
		connection.textContent = "Connected · Finding your dot…";
		void locate();
	} catch (error) {
		returnToLobby(error instanceof Error ? error.message : String(error));
	} finally {
		joining = false;
		updateCountryChoice();
	}
});

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: draw the map layers and local-player marker in their visual order.
function draw(now: number) {
	requestAnimationFrame(draw);
	const elapsed = now - lastFrame;
	// Allow timestamp rounding at the frame boundary without accumulating drift.
	if (elapsed + 0.1 < FRAME_MS) return;
	lastFrame += Math.floor((elapsed + 0.1) / FRAME_MS) * FRAME_MS;
	const position = motion?.position(now);
	if (position) camera = { x: position.x + 0.5, y: position.y + 0.5 };
	const zoom = playing ? scale : Math.max(width / WIDTH, height / HEIGHT);
	const left = width / 2 - camera.x * zoom;
	const top = height / 2 - camera.y * zoom;
	ctx.fillStyle = "#0d1822";
	ctx.fillRect(0, 0, width, height);
	ctx.drawImage(base, left, top, WIDTH * zoom, HEIGHT * zoom);
	const dots = new Map<string, Dot>();
	for (const [index, chunk] of chunks) {
		ctx.drawImage(
			chunk.image,
			left + (index % COLUMNS) * CHUNK * zoom,
			top + Math.floor(index / COLUMNS) * CHUNK * zoom,
			CHUNK * zoom,
			CHUNK * zoom,
		);
		for (const dot of chunk.dots) dots.set(dot.player_id, dot);
	}
	// Draw yourself last so nearby dots and names do not cover your marker.
	const self = dots.get(myId) ?? motion?.dot;
	if (self) {
		dots.delete(self.player_id);
		dots.set(self.player_id, self);
	}
	for (const dot of dots.values()) {
		const key = dot.player_id;
		// Simple client-side join: hot dot plus its cold roster row. Dots
		// without a row are mid-join/leave races; draw them neutrally once.
		const meta = players.get(key);
		const isBot = meta?.is_bot ?? false;
		const display =
			key === myId && position ? { x: position.x, y: position.y } : dot;
		const x = left + (display.x + 0.5) * zoom,
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
		if (!isBot && meta?.name) {
			ctx.fillStyle = key === myId ? "#ffe3a0" : "#bccacb";
			ctx.font = key === myId ? "bold 11px system-ui" : "10px system-ui";
			ctx.textAlign = "center";
			ctx.strokeStyle = "#0d1822";
			ctx.lineWidth = 3;
			ctx.lineJoin = "round";
			ctx.strokeText(meta.name, x, y - zoom - 7, 120);
			ctx.fillText(meta.name, x, y - zoom - 7, 120);
		}
	}
	if (playing && performance.now() - lastHeartbeat > 500) {
		lastHeartbeat = performance.now();
		publish();
		void locate();
	}
}
requestAnimationFrame(draw);
