import {
	createClient,
	type SubscriptionHandle,
	type ZyncBaseClient,
} from "@zyncbase/client";
import { LocalMotion } from "./motion";
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
	readDots,
	readOwners,
	terrain,
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
const countries = new Map<number, Country>();
const chunks = new Map<
	number,
	{ image: HTMLCanvasElement; dots: Dot[]; owners: Uint16Array }
>();
const subscriptions = new Map<number, SubscriptionHandle>();
const held = new Map<string, Direction>();
let client: ZyncBaseClient | undefined;
let online = false;
let playing = false;
let myId = "",
	name = "",
	seq = 0,
	pulse = 0,
	lastAck = -1,
	sentAt = 0;
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

async function checkHealth() {
	if (playing) return;
	const button = element<HTMLButtonElement>("join-button");
	try {
		const response = await fetch("/health", {
			signal: AbortSignal.timeout(3000),
		});
		const health = await response.json();
		if (!response.ok || health.ready !== true) throw new Error();
		button.disabled = false;
		if (element("error").textContent === OFFLINE)
			element("error").textContent = "";
		if (connection.textContent.startsWith(OFFLINE))
			connection.textContent = TAGLINE;
	} catch {
		button.disabled = true;
		element("error").textContent = OFFLINE;
		connection.textContent = `${OFFLINE} · Retrying…`;
	}
}
void checkHealth();
const healthTimer = setInterval(() => {
	if (playing) clearInterval(healthTimer);
	else void checkHealth();
}, 5000);

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

function receive(row: ChunkRow) {
	const dots = readDots(row.dots);
	const owners = readOwners(row.owners);
	chunks.set(row.index, { dots, owners, image: chunkImage(owners) });
	const self = dots.find((dot) => dot.id === myId);
	const now = performance.now();
	const moving = online ? direction : "idle";
	if (motion) motion.update(self ?? motion.dot, moving, now);
	if (!self) return;
	if (lastOwnDot === 0) clearTimeout(admissionTimer);
	lastOwnDot = now;
	if (!motion) motion = new LocalMotion(self, moving, now, land, ownerAt);
	const position = motion.position(lastOwnDot);
	camera = { x: position.x + 0.5, y: position.y + 0.5 };
	if (self.seq > lastAck) {
		lastAck = self.seq;
		connection.textContent = `Live · ${Math.max(0, Date.now() - self.sentAt)} ms input → view`;
	}
	const country = countries.get(self.code);
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
	for (const [index, handle] of subscriptions) {
		if (visible.has(index)) continue;
		handle.unsubscribe();
		subscriptions.delete(index);
		chunks.delete(index);
	}
	for (const index of visible) {
		if (subscriptions.has(index)) continue;
		const handle = client.store.subscribe(
			"chunks",
			{ where: { index }, limit: 1 },
			(rows) => {
				if (!subscriptions.has(index)) return;
				if (rows.length) receive(rows[0] as ChunkRow);
				else chunks.delete(index);
			},
		);
		subscriptions.set(index, handle);
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
		sentAt = Date.now();
	}
	client.presence.set({
		country: name,
		direction,
		seq,
		sentAt,
		pulse: ++pulse,
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

// Admission rejects new names once 64 live countries exist, which leaves
// the newcomer without a dot. A join-scoped timeout reads the latest
// country state so the check runs even when no country updates arrive.
function checkAdmission() {
	if (!playing || lastOwnDot !== 0) return;
	if (
		latestCountries.length >= MAX_COUNTRIES &&
		!latestCountries.some(
			(country) => country.name.toLowerCase() === name.toLowerCase(),
		)
	) {
		client?.disconnect();
		for (const handle of subscriptions.values()) handle.unsubscribe();
		subscriptions.clear();
		chunks.clear();
		playing = online = false;
		lobby.hidden = false;
		element("scoreboard").hidden = true;
		element("direction-pad").hidden = true;
		element("error").textContent =
			`The world already has ${MAX_COUNTRIES} countries — join an existing one.`;
		connection.textContent = "Ready when you are.";
		element<HTMLButtonElement>("join-button").disabled = false;
	}
}

async function locate() {
	if (!client || !online || locating || performance.now() - lastOwnDot < 1500)
		return;
	locating = true;
	try {
		const rows = await client.store.query("chunks", {
			where: { occupied: true },
			limit: 100,
		});
		const row = (rows as unknown as ChunkRow[]).find((row) =>
			readDots(row.dots).some((dot) => dot.id === myId),
		);
		if (row) receive(row);
	} catch (error) {
		connection.textContent = `Connection interrupted: ${String(error)}`;
	} finally {
		locating = false;
	}
}

element("join").addEventListener("submit", async (event) => {
	event.preventDefault();
	const button = element<HTMLButtonElement>("join-button");
	button.disabled = true;
	element("error").textContent = "";
	lastOwnDot = 0;
	latestCountries = [];
	clearTimeout(admissionTimer);
	try {
		name = countryName(element<HTMLInputElement>("country").value);
		const response = await fetch("/session", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ code: element<HTMLInputElement>("code").value }),
		});
		const session = await response.json();
		if (!response.ok) throw new Error(session.error);
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
		const users = await client.store.query("users", { limit: 1 });
		myId = String((users[0] as { id: string })?.id ?? "");
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
		motion = undefined;
		camera = { x: 933, y: 276 };
		release();
		updateSubscriptions();
		zoom(0);
		connection.textContent = "Connected · Finding your dot…";
		void locate();
	} catch (error) {
		clearTimeout(admissionTimer);
		client?.disconnect();
		playing = online = false;
		element("error").textContent =
			error instanceof Error ? error.message : String(error);
		connection.textContent = "Ready when you are.";
	} finally {
		button.disabled = false;
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
		for (const dot of chunk.dots) dots.set(dot.id, dot);
	}
	if (motion && !dots.has(myId)) dots.set(myId, motion.dot);
	for (const dot of dots.values()) {
		const display = dot.id === myId && position ? position : dot;
		const x = left + (display.x + 0.5) * zoom,
			y = top + (display.y + 0.5) * zoom;
		ctx.beginPath();
		const radius = Math.max(3, zoom * 0.48);
		if (dot.bot) ctx.rect(x - radius, y - radius, radius * 2, radius * 2);
		else ctx.arc(x, y, radius, 0, Math.PI * 2);
		ctx.fillStyle = countries.get(dot.code)?.color ?? "white";
		ctx.fill();
		ctx.lineWidth = 2;
		ctx.strokeStyle = dot.id === myId ? "#ffffff" : "#0d1822";
		ctx.stroke();
		if (dot.id === myId) {
			ctx.fillStyle = "#fff";
			ctx.font = "bold 10px system-ui";
			ctx.textAlign = "center";
			ctx.fillText("YOU", x, y - zoom - 7);
		}
	}
	if (playing && performance.now() - lastHeartbeat > 500) {
		lastHeartbeat = performance.now();
		publish();
		void locate();
	}
}
requestAnimationFrame(draw);
