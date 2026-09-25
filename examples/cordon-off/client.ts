import {
	ActionExecutionError,
	createClient,
	type SubscriptionHandle,
	type ZyncBaseClient,
} from "@zyncbase/client";
import nipplejs from "nipplejs";
import {
	approach,
	JoystickSteering,
	LocalMotion,
	type MotionDot,
} from "./motion";
import {
	COUNTRY_CHUNK_HEIGHT,
	COUNTRY_CHUNK_WIDTH,
	COUNTRY_COLOR_INDEX,
	COUNTRY_COLORS,
	COUNTRY_COLUMNS,
	COUNTRY_ROWS,
	type Country,
	type CountryChunkRow,
	countryChunkIndex,
	countryName,
	type Direction,
	type Dot,
	HEIGHT,
	LAND_RGB,
	LITTLE_ENDIAN,
	MAX_COUNTRIES,
	NAMESPACE,
	type PlayerRow,
	playerName,
	readColorIndexes,
	readCoordinates,
	terrain,
	USER_CHUNK_HEIGHT,
	USER_CHUNK_WIDTH,
	USER_COLUMNS,
	USER_ROWS,
	type UserChunkRow,
	WATER_COUNTRY_CHUNKS,
	WATER_RGB,
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
const roundChip = element("round");
const lobby = element("lobby");
const countryChoice = element<HTMLSelectElement>("country-choice");
const countryInput = element<HTMLInputElement>("country");
const scoreboardPanel = element("scoreboard");
const scoreboardToggle = element<HTMLButtonElement>("scoreboard-toggle");
const countries = new Map<number, Country>();
// Cold roster from the users table, keyed by identity: one row per live
// player plus 10s grace tombstones. Updated only on admission, chunk
// crossing, and leave — never per tick.
const roster = new Map<string, PlayerRow>();
let rosterUnsub: SubscriptionHandle | undefined;
const chunks = new Map<
	number,
	{ image: HTMLCanvasElement; colorIndexes: Uint8Array }
>();
const userChunks = new Map<number, Dot[]>();
const subscriptions = new Map<number, () => void>();
const userSubscriptions = new Map<number, () => void>();
const held = new Map<string, Direction>();
let client: ZyncBaseClient | undefined;
let online = false;
let playing = false;
let joining = false;
// Admission lives in an action: joined means the worker admitted this player,
// and identity came back in the join reply.
let joined = false;
let joinedAt = 0;
const ADMISSION_GRACE_MS = 1000;
let joinInFlight = false;
let worldReady = false;
let roundNumber = 0;
let roundEndsAt = 0;
let serverSkew = 0;
let roundTimer: ReturnType<typeof setTimeout> | undefined;
let leaving = false;
let selectedCountryId: number | undefined;
let sessionId = "";
let lobbyCountries: Country[] = [];
let availableSlots = 0;
let myPlayerId = "",
	name = "",
	nickname = "",
	seq = 0;
let direction: Direction = "idle";
// Heading used to choose the prefetch edge. Kept after release so stopping
// does not drop the leading margin and churn subscriptions on the next move.
let prefetchDirection: Direction = "idle";
// Alternation: when two orthogonal directions are held (keyboard) or the
// joystick provides a diagonal vector, we alternate between the two axes
// on each confirmed server move instead of using a timer — this avoids
// leaking credit across direction changes on the server.
let altDirections: Direction[] = [];
let altIndex = 0;
const joystickSteering = new JoystickSteering();
let lastSentDirection: Direction = "idle";
let motion: LocalMotion | undefined;
let camera = { x: WIDTH / 2, y: HEIGHT / 2 };
let scale = 8;
let width = innerWidth,
	height = innerHeight;
let lastOwnDot = 0;
// Consecutive locate() reads that could not find our own roster row. A live
// player always has one; a few misses mean the world dropped us (long sleep,
// expired session, restart) and the lobby is the only way back.
let ownRowMisses = 0;
let locating = false;
// Bumped when a session ends so in-flight locate() failures cannot write
// status text into the lobby that started after them.
let sessionGeneration = 0;
// Dirty-frame rendering: the scene repaints only when something it draws
// changes. The input heartbeat runs on its own timer, not as a frame side
// effect, so it survives idle frames.
let dirty = true;
let drawnX = Number.NaN;
let drawnY = Number.NaN;
let lastCountrySubKey = "";
let lastUserSubKey = "";
let heartbeat: ReturnType<typeof setInterval> | undefined;
let admissionTimer: ReturnType<typeof setTimeout> | undefined;
let latestCountries: Country[] = [];
const FRAME_MS = 1000 / 30;
// Camera catch-up time constant. Bigger = lazier trailing behind the dot.
const CAMERA_TAU = 120;
// A chunk subscription costs a listen round trip, so keep one extra country
// chunk on the leading edge of travel; user chunks are 200 cells wide and need
// no margin, and idle needs none either.
const COUNTRY_PREFETCH_CHUNKS = 1;
const USER_PREFETCH_CHUNKS = 0;
let lastFrame = 0;
const OFFLINE = "The world is offline";

// Only warn states render (CSS hides .connection otherwise): only trouble
// should pull attention away from the map.
function setConnection(text: string, warn = false) {
	connection.textContent = text;
	connection.classList.toggle("warn", warn);
}

function formatDuration(ms: number) {
	const total = Math.max(0, Math.ceil(ms / 1000));
	const hours = Math.floor(total / 3600);
	const minutes = Math.floor((total % 3600) / 60);
	const seconds = total % 60;
	const mm = String(minutes).padStart(2, "0");
	const ss = String(seconds).padStart(2, "0");
	return hours ? `${hours}:${mm}:${ss}` : `${minutes}:${ss}`;
}

function updateRoundLabel() {
	if (!roundNumber || !roundEndsAt) {
		roundChip.hidden = true;
		return;
	}
	const remaining = roundEndsAt - (Date.now() + serverSkew);
	roundChip.hidden = false;
	roundChip.classList.toggle("urgent", remaining <= 30_000);
	roundChip.textContent =
		remaining > 0
			? `Round ${roundNumber} · ${formatDuration(remaining)} left`
			: `Round ${roundNumber} · final seconds`;
}

// Results live on the Cloudflare Worker, so navigating at the deadline is
// safe while the simulation restarts; the viewer waits for the deploy.
function scheduleRoundEnd() {
	clearTimeout(roundTimer);
	if (!roundNumber || !roundEndsAt) return;
	const remaining = roundEndsAt - (Date.now() + serverSkew) + 1200;
	roundTimer = setTimeout(
		() => {
			if (!playing || leaving) return;
			leaving = true;
			location.href = `/history.html?round=${roundNumber}`;
		},
		Math.max(0, remaining),
	);
}

setInterval(updateRoundLabel, 1000);

function updateCountryChoice() {
	const creating = countryChoice.value === "new";
	const country = lobbyCountries.find(
		(country) => String(country.country_id) === countryChoice.value,
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
		rows.some(
			(country, i) => country.country_id !== lobbyCountries[i]?.country_id,
		)
	) {
		const selected = countryChoice.value;
		const create = new Option("＋ Create a country", "new");
		create.disabled = slots === 0;
		countryChoice.replaceChildren(
			new Option("Choose a country…", ""),
			...rows.map(
				(country) => new Option(country.name, String(country.country_id)),
			),
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
		if (typeof health.now === "number") serverSkew = health.now - Date.now();
		if (health.round) {
			roundNumber = health.round.number;
			roundEndsAt = health.round.endsAt;
			updateRoundLabel();
		}
		if (!response.ok || health.ready !== true) throw new Error();
		worldReady = true;
		showLobbyCountries(health.countries);
		if (element("error").textContent === OFFLINE)
			element("error").textContent = "";
		if (connection.textContent.startsWith(OFFLINE)) setConnection("");
	} catch {
		if (playing || joining) return;
		worldReady = false;
		countryChoice.disabled = true;
		updateCountryChoice();
		element("error").textContent = OFFLINE;
		setConnection(`${OFFLINE} · Retrying…`, true);
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
const landColor = [...LAND_RGB, 255];
const waterColor = [...WATER_RGB, 255];
for (let i = 0; i < land.length; i++)
	pixels.data.set(land[i] ? landColor : waterColor, i * 4);
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
// synchronously, so a single buffer avoids per-tick allocations. Color indexes
// index a 256-entry palette LUT packed once, so painting needs no countries.
const chunkImageData = new ImageData(COUNTRY_CHUNK_WIDTH, COUNTRY_CHUNK_HEIGHT);
const chunkPixels = new Uint32Array(chunkImageData.data.buffer);
const ownerPixels = new Uint32Array(256);
for (let code = 1; code <= MAX_COUNTRIES; code++) {
	const hex = COUNTRY_COLORS[code - 1];
	const r = Number.parseInt(hex.slice(1, 3), 16);
	const g = Number.parseInt(hex.slice(3, 5), 16);
	const b = Number.parseInt(hex.slice(5, 7), 16);
	ownerPixels[code] = LITTLE_ENDIAN
		? ((0xff << 24) | (b << 16) | (g << 8) | r) >>> 0
		: ((r << 24) | (g << 16) | (b << 8) | 0xff) >>> 0;
}

function chunkImage(colorIndexes: Uint8Array, canvas?: HTMLCanvasElement) {
	const image = canvas ?? document.createElement("canvas");
	if (!canvas) {
		image.width = COUNTRY_CHUNK_WIDTH;
		image.height = COUNTRY_CHUNK_HEIGHT;
	}
	const draw = image.getContext("2d");
	if (!draw) throw new Error("Canvas unavailable");
	for (let i = 0; i < colorIndexes.length; i++)
		chunkPixels[i] = ownerPixels[colorIndexes[i]];
	draw.putImageData(chunkImageData, 0, 0);
	return image;
}

function myCountryId(): number {
	return roster.get(myPlayerId)?.country_id ?? selectedCountryId ?? 0;
}

function myColorIndex(): number {
	return (
		COUNTRY_COLOR_INDEX.get(countries.get(myCountryId())?.color ?? "") ?? 0
	);
}

function toMotion(dot: Dot): MotionDot {
	return { ...dot, colorIndex: myColorIndex() };
}

function positionChanged(a: Dot, b: Dot) {
	return a.x !== b.x || a.y !== b.y || a.player_id !== b.player_id;
}

function isConsistentMove(from: Dot, to: Dot, dir: Direction): boolean {
	let dx = to.x - from.x;
	dx -= WIDTH * Math.round(dx / WIDTH);
	const dy = to.y - from.y;
	switch (dir) {
		case "left":
			return dx < 0 && dy === 0;
		case "right":
			return dx > 0 && dy === 0;
		case "up":
			return dx === 0 && dy < 0;
		case "down":
			return dx === 0 && dy > 0;
		default:
			return false;
	}
}

function updateSelfMotion(self: MotionDot, now: number) {
	const moving = online ? direction : "idle";
	if (motion) {
		const confirmed =
			positionChanged(self, motion.dot) &&
			online &&
			isConsistentMove(motion.dot, self, lastSentDirection);
		motion.update(self, moving, now);
		if (confirmed) onMoveConfirmed();
		return;
	}
	motion = new LocalMotion(self, moving, now, land, ownerAt);
}

function receiveCountryChunk(row: CountryChunkRow) {
	const index = Number(row.id);
	if (!Number.isSafeInteger(index)) return;
	const colorIndexes = readColorIndexes(row.color_indexes);
	const previous = chunks.get(index);
	chunks.set(index, {
		colorIndexes,
		image: chunkImage(colorIndexes, previous?.image),
	});
	dirty = true;
}

function receiveUserChunk(row: UserChunkRow) {
	const index = Number(row.id);
	if (!Number.isSafeInteger(index)) return;
	const dots = readCoordinates(row.coordinates);
	userChunks.set(index, dots);
	dirty = true;
	const self = dots.find((dot) => dot.player_id === myPlayerId);
	const now = performance.now();
	const selfMotion = self ? toMotion(self) : undefined;
	if (selfMotion) updateSelfMotion(selfMotion, now);
	if (!self || !selfMotion) return;
	ownRowMisses = 0;
	if (lastOwnDot === 0) {
		clearTimeout(admissionTimer);
		// First sighting acks our input.
		setConnection("");
	}
	lastOwnDot = now;
	maybeUpdateSubscriptions();
}

function ownerAt(x: number, y: number) {
	const wrapped = wrapX(x);
	// Water is always unowned and water-only chunks have no rows; answer
	// without a subscribed chunk so prediction keeps working over the ocean.
	if (!land[y * WIDTH + wrapped]) return 0;
	return chunks.get(countryChunkIndex(wrapped, y))?.colorIndexes[
		(y % COUNTRY_CHUNK_HEIGHT) * COUNTRY_CHUNK_WIDTH +
			(wrapped % COUNTRY_CHUNK_WIDTH)
	];
}

// A world copy is WIDTH wide but chunk columns are chunk-width; both grids
// divide WIDTH exactly, so wrapped columns come from world copies rather than
// a modulo of the chunk column. Straddling the seam can need both ends.
type ChunkGrid = {
	width: number;
	height: number;
	columns: number;
	rows: number;
	prefetch: number;
	water?: Uint8Array;
};

const COUNTRY_GRID: ChunkGrid = {
	width: COUNTRY_CHUNK_WIDTH,
	height: COUNTRY_CHUNK_HEIGHT,
	columns: COUNTRY_COLUMNS,
	rows: COUNTRY_ROWS,
	prefetch: COUNTRY_PREFETCH_CHUNKS,
	water: WATER_COUNTRY_CHUNKS,
};
const USER_GRID: ChunkGrid = {
	width: USER_CHUNK_WIDTH,
	height: USER_CHUNK_HEIGHT,
	columns: USER_COLUMNS,
	rows: USER_ROWS,
	prefetch: USER_PREFETCH_CHUNKS,
};

// Extend the view by the grid's prefetch margin in the direction of travel so
// a tile is subscribed before its pixels reach the viewport edge. The heading
// persists while idle so a stop keeps the margin it already paid for.
function subscriptionBounds(grid: ChunkGrid) {
	const halfWidth = width / scale / 2;
	const halfHeight = height / scale / 2;
	const heading = direction === "idle" ? prefetchDirection : direction;
	return {
		xMin:
			camera.x -
			halfWidth -
			(heading === "left" ? grid.prefetch * grid.width : 0),
		xMax:
			camera.x +
			halfWidth +
			(heading === "right" ? grid.prefetch * grid.width : 0),
		yMin:
			camera.y -
			halfHeight -
			(heading === "up" ? grid.prefetch * grid.height : 0),
		yMax:
			camera.y +
			halfHeight +
			(heading === "down" ? grid.prefetch * grid.height : 0),
	};
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: one walk covers seam copies, rows, and the water filter for either grid.
function visibleChunks(grid: ChunkGrid) {
	const visible = new Set<number>();
	const { xMin, xMax, yMin, yMax } = subscriptionBounds(grid);
	const top = Math.max(0, Math.floor(yMin / grid.height));
	const bottom = Math.min(grid.rows - 1, Math.floor(yMax / grid.height));
	for (let k = Math.floor(xMin / WIDTH); k <= Math.floor(xMax / WIDTH); k++) {
		const start = Math.max(0, xMin - k * WIDTH),
			end = Math.min(WIDTH, xMax - k * WIDTH);
		if (start >= end) continue;
		const first = Math.floor(start / grid.width);
		const last = Math.min(grid.columns - 1, Math.ceil(end / grid.width) - 1);
		for (let col = first; col <= last; col++)
			for (let y = top; y <= bottom; y++) {
				const index = y * grid.columns + col;
				// Water-only country chunks can never change: never subscribe.
				if (!grid.water?.[index]) visible.add(index);
			}
	}
	return visible;
}

function subscriptionKey(grid: ChunkGrid) {
	const { xMin, xMax, yMin, yMax } = subscriptionBounds(grid);
	return `${Math.floor(xMin / grid.width)},${Math.floor(xMax / grid.width)},${Math.floor(yMin / grid.height)},${Math.floor(yMax / grid.height)}`;
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: both grids need the same serve/unserve bookkeeping in one pass.
function updateSubscriptions() {
	// The SDK does not retry a listen issued while the transport is down, and a
	// failed handle would pin its chunk index forever. Record the served bounds
	// only when a set is served, or an offline key would suppress the first
	// refresh after reconnect.
	if (!client || !playing || !online) return;
	lastCountrySubKey = subscriptionKey(COUNTRY_GRID);
	lastUserSubKey = subscriptionKey(USER_GRID);
	const visibleCountry = visibleChunks(COUNTRY_GRID);
	for (const [index, unsub] of subscriptions) {
		if (visibleCountry.has(index)) continue;
		unsub();
		subscriptions.delete(index);
		chunks.delete(index);
	}
	for (const index of visibleCountry) {
		if (subscriptions.has(index)) continue;
		// Direct document listens: chunk ids are the store primary keys, so
		// no secondary index or query-subscription group is needed per tile.
		const key = index;
		const unsub = client.store.listen(
			["country_chunks", String(index)],
			(row) => {
				if (!subscriptions.has(key)) return;
				if (row) receiveCountryChunk(row as CountryChunkRow);
				else {
					chunks.delete(key);
					dirty = true;
				}
			},
		);
		subscriptions.set(index, unsub);
	}
	const visibleUser = visibleChunks(USER_GRID);
	for (const [index, unsub] of userSubscriptions) {
		if (visibleUser.has(index)) continue;
		unsub();
		userSubscriptions.delete(index);
		userChunks.delete(index);
	}
	for (const index of visibleUser) {
		if (userSubscriptions.has(index)) continue;
		const key = index;
		const unsub = client.store.listen(["user_chunks", String(index)], (row) => {
			if (!userSubscriptions.has(key)) return;
			if (row) receiveUserChunk(row as UserChunkRow);
			else {
				userChunks.delete(key);
				dirty = true;
			}
		});
		userSubscriptions.set(index, unsub);
	}
}

// Recompute tiles only when the prefetched bounds cross a chunk edge: chunk
// updates arrive at tick rate and must not rescan subscriptions each time.
function maybeUpdateSubscriptions() {
	if (
		subscriptionKey(COUNTRY_GRID) === lastCountrySubKey &&
		subscriptionKey(USER_GRID) === lastUserSubKey
	)
		return;
	updateSubscriptions();
}

function scoreboard(rows: Country[]) {
	// ponytail: roster rows include 10s grace tombstones, so a departed player
	// keeps counting until expiry; filtering needs a live flag from the server.
	const headcount = new Map<number, number>();
	for (const player of roster.values())
		headcount.set(
			player.country_id,
			(headcount.get(player.country_id) ?? 0) + 1,
		);
	const paletteChanged =
		rows.length !== countries.size ||
		rows.some((row) => countries.get(row.country_id)?.color !== row.color);
	countries.clear();
	for (const row of rows) countries.set(row.country_id, row);
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
				const members = document.createElement("span");
				members.className = "players";
				members.title = "Players";
				members.textContent = String(headcount.get(country.country_id) ?? 0);
				const score = document.createElement("span");
				score.className = "score";
				score.textContent = country.count.toLocaleString();
				li.append(swatch, label, members, score);
				return li;
			}),
	);
	// The motion's color joins the roster later than its first dot, so refresh
	// it here without treating the change as a relocation.
	refreshMotionColor();
	// Chunk images come from the palette LUT, but dots join their color from
	// this map: repaint once when the roster's colors arrive or change.
	if (paletteChanged) dirty = true;
}

function refreshMotionColor() {
	if (!motion) return;
	const colorIndex = myColorIndex();
	if (motion.dot.colorIndex === colorIndex) return;
	motion.update(
		{ ...motion.dot, colorIndex },
		online ? direction : "idle",
		performance.now(),
	);
}

// Admission and identity come from the sync join action: its reply carries the
// internal user id the roster and dots are keyed by.
async function joinWorld() {
	if (!client) throw new Error("Not connected");
	const result = (await client.actions.call("player_join", {
		name: nickname,
		country_id: selectedCountryId,
		session_id: sessionId,
	})) as { user_id?: unknown };
	if (typeof result.user_id !== "string" || !result.user_id)
		throw new Error("Join returned no player identity");
	myPlayerId = result.user_id;
	joined = true;
	joinedAt = performance.now();
	ownRowMisses = 0;
	setConnection("");
}

// A rejected join (full world, missing country, bad name) is final; a worker
// that is still booting is transient and the heartbeat retries it.
async function ensureJoined() {
	if (!client || !online || joined || joinInFlight) return;
	joinInFlight = true;
	try {
		await joinWorld();
	} catch (error) {
		if (error instanceof ActionExecutionError) returnToLobby(error.message);
	} finally {
		joinInFlight = false;
	}
}

// Best-effort: remove the dot now instead of waiting for the input lease.
// Crashes and dropped sockets still expire on the lease.
function leave() {
	if (!client || !online || !joined) return;
	void client.actions.call("player_leave", {}).catch(() => {});
}

function publish(changed = false) {
	if (changed)
		motion?.update(motion.dot, online ? direction : "idle", performance.now());
	if (!online || !client || !joined) return;
	if (changed) seq++;
	void client.actions.call("player_move", { direction, seq }).catch(() => {});
}

function setDirection(next: Direction) {
	if (next === direction) return;
	direction = next;
	lastSentDirection = next;
	if (next !== "idle") prefetchDirection = next;
	publish(true);
	updateSubscriptions();
}

// Called when the server confirms we actually moved (position changed in a
// chunk update). Alternate to the next direction in the sequence so each
// axis gets its full terrain cost before switching.
function onMoveConfirmed() {
	// Joystick: advance the deterministic mixed sequence so the cadence
	// matches the stick angle. Keyboard: simple 50/50 toggle.
	const stick = joystickSteering.confirmed();
	if (stick) {
		setDirection(stick);
		return;
	}
	if (altDirections.length < 2) return;
	altIndex = (altIndex + 1) % altDirections.length;
	setDirection(altDirections[altIndex]);
}

// Recompute alternation state from keyboard held keys.
function heldAxes(): { x: number; y: number } {
	let x = 0,
		y = 0;
	for (const dir of held.values()) {
		if (dir === "left") x = -1;
		else if (dir === "right") x = 1;
		else if (dir === "up") y = -1;
		else if (dir === "down") y = 1;
	}
	return { x, y };
}

function axisDir(axis: "x" | "y", sign: number): Direction {
	if (axis === "x") return sign > 0 ? "right" : "left";
	return sign > 0 ? "down" : "up";
}

function updateKeyboardInput() {
	const { x, y } = heldAxes();
	if (x !== 0 && y !== 0) {
		const h = axisDir("x", x);
		const v = axisDir("y", y);
		if (altDirections[0] === h && altDirections[1] === v) return;
		altDirections = [h, v];
		altIndex = 0;
		setDirection(h);
		return;
	}
	altDirections = [];
	altIndex = 0;
	if (x !== 0) setDirection(axisDir("x", x));
	else if (y !== 0) setDirection(axisDir("y", y));
	else setDirection("idle");
}

// Joystick sends a screen-space vector; the steering state machine owns the
// diagonal sequence so held-stick move events do not restart it.
function updateJoystickInput(x: number, y: number) {
	const next = joystickSteering.move(x, y);
	if (next === undefined) return;
	altDirections = [];
	altIndex = 0;
	setDirection(next);
}

function release() {
	held.clear();
	altDirections = [];
	altIndex = 0;
	joystickSteering.release();
	lastSentDirection = "idle";
	setDirection("idle");
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
// Keyboard fallback for zoom now that the on-screen buttons are gone.
const zoomKeys: Record<string, number> = {
	Equal: 1,
	Minus: -1,
	NumpadAdd: 1,
	NumpadSubtract: -1,
};
window.addEventListener("keydown", (event) => {
	if (!playing || !online) return;
	// Browser shortcuts (zoom, select all, save) must keep working.
	if (event.ctrlKey || event.metaKey) return;
	const zoomStep = zoomKeys[event.code];
	if (zoomStep !== undefined) {
		event.preventDefault();
		zoom(zoomStep);
		return;
	}
	if (!keys[event.code]) return;
	event.preventDefault();
	if (event.repeat) return;
	held.set(event.code, keys[event.code]);
	updateKeyboardInput();
});
window.addEventListener("keyup", (event) => {
	if (held.delete(event.code)) {
		event.preventDefault();
		updateKeyboardInput();
	}
});
// Gameplay input self-heals: extensions, devtools, browser modals, and other
// tabs can steal focus, so reclaim it whenever the page gets it back and
// clear stale keys whenever it is lost.
function focusMap() {
	if (playing) canvas.focus({ preventScroll: true });
}
addEventListener("blur", release);
addEventListener("focus", focusMap);
canvas.addEventListener("pointerdown", focusMap);
document.addEventListener("visibilitychange", () => {
	release();
	dirty = true;
	if (!document.hidden) focusMap();
});
addEventListener("pagehide", () => {
	release();
	leave();
	client?.disconnect();
});
// Touch players get a fixed nipplejs stick. Its `move` event carries the
// 45°-bucketed direction and drops it below the threshold, so recentering
// the stick stops movement without waiting for release.
let joystick: ReturnType<typeof nipplejs.create> | undefined;

function flash(target: HTMLElement) {
	target.classList.remove("flash");
	target.getBoundingClientRect();
	target.classList.add("flash");
	target.addEventListener(
		"animationend",
		() => target.classList.remove("flash"),
		{ once: true },
	);
}

function startJoystick() {
	const zone = element("joystick");
	zone.hidden = false;
	flash(zone);
	const stick = nipplejs.create({
		zone,
		mode: "static",
		// Static mode anchors the base at this position; centering it in the zone.
		position: { top: "50%", left: "50%" },
		size: 130,
		threshold: 0.15,
		color: { front: "#eef0e8", back: "#101b28b8" },
		fadeTime: 150,
		restOpacity: 1,
	});
	joystick = stick;
	stick.on("move", (evt) => {
		const vector = evt.data.vector;
		if (vector) updateJoystickInput(vector.x, -vector.y);
	});
	stick.on("end", () => {
		joystickSteering.release();
		altDirections = [];
		altIndex = 0;
		setDirection("idle");
	});
}

function stopJoystick() {
	joystick?.destroy();
	joystick = undefined;
	element("joystick").hidden = true;
}

function setScale(next: number) {
	if (!playing) return;
	const clamped = Math.min(16, Math.max(2, Math.round(next)));
	if (clamped === scale) return;
	scale = clamped;
	dirty = true;
	updateSubscriptions();
}
function zoom(change: number) {
	setScale(scale + change);
}
// Wheel is the desktop zoom. Trackpads fire a burst of tiny deltas, so
// accumulate until one notch-worth before stepping; ctrl+wheel is the
// browser's own pinch zoom and stays untouched.
let wheelAccum = 0;
canvas.addEventListener(
	"wheel",
	(event) => {
		if (!playing || event.ctrlKey) return;
		event.preventDefault();
		const unit =
			event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? innerHeight : 1;
		wheelAccum += event.deltaY * unit;
		if (Math.abs(wheelAccum) >= 80) {
			zoom(wheelAccum > 0 ? -1 : 1);
			wheelAccum = 0;
		}
	},
	{ passive: false },
);

// Pinch maps two-finger spread to integer scale steps so pixels stay crisp.
// The camera stays player-centred, so there is no focal point to track.
let pinchStart = 0;
let pinchScale = 8;
const touchGap = (touches: TouchList) =>
	Math.hypot(
		touches[0].clientX - touches[1].clientX,
		touches[0].clientY - touches[1].clientY,
	);
canvas.addEventListener("touchstart", (event) => {
	if (event.touches.length !== 2) return;
	pinchStart = touchGap(event.touches);
	pinchScale = scale;
});
canvas.addEventListener(
	"touchmove",
	(event) => {
		if (!pinchStart || event.touches.length !== 2) return;
		event.preventDefault();
		const gap = touchGap(event.touches);
		if (gap > 0) setScale(pinchScale * (gap / pinchStart));
	},
	{ passive: false },
);
const endPinch = (event: TouchEvent) => {
	if (event.touches.length < 2) pinchStart = 0;
};
canvas.addEventListener("touchend", endPinch);
canvas.addEventListener("touchcancel", endPinch);

function setScoreboardOpen(open: boolean) {
	scoreboardPanel.classList.toggle("collapsed", !open);
	scoreboardToggle.setAttribute("aria-expanded", String(open));
}
scoreboardToggle.addEventListener("click", () =>
	setScoreboardOpen(scoreboardPanel.classList.contains("collapsed")),
);
// Mouse clicks on HUD controls must not pull focus off the game surface.
scoreboardToggle.addEventListener("pointerdown", (event) => {
	if (event.pointerType === "mouse") event.preventDefault();
});
setScoreboardOpen(!matchMedia("(pointer: coarse)").matches);

function returnToLobby(message: string) {
	sessionGeneration++;
	leaving = false;
	clearTimeout(roundTimer);
	clearTimeout(admissionTimer);
	clearInterval(heartbeat);
	heartbeat = undefined;
	leave();
	joined = false;
	ownRowMisses = 0;
	sessionId = "";
	client?.disconnect();
	for (const unsub of subscriptions.values()) unsub();
	subscriptions.clear();
	chunks.clear();
	for (const unsub of userSubscriptions.values()) unsub();
	userSubscriptions.clear();
	userChunks.clear();
	rosterUnsub?.unsubscribe();
	rosterUnsub = undefined;
	roster.clear();
	playing = online = false;
	lobby.hidden = false;
	scoreboardPanel.hidden = true;
	stopJoystick();
	element("error").textContent = message;
	setConnection("");
	dirty = true;
	updateCountryChoice();
	void checkHealth();
}

// The roster can change between the lobby poll and the join action.
function checkAdmission() {
	if (!playing || lastOwnDot !== 0) return;
	if (
		selectedCountryId !== undefined &&
		!latestCountries.some((country) => country.country_id === selectedCountryId)
	) {
		returnToLobby("That country is no longer available. Choose another one.");
		return;
	}
}

// A live player always has a roster row; consecutive locate() misses mean the
// world dropped us. Returns true when the lobby has been requested.
function noteOwnRowMissing() {
	if (!playing || !joined || joinInFlight) return false;
	if (performance.now() - joinedAt < ADMISSION_GRACE_MS) return false;
	ownRowMisses++;
	if (ownRowMisses < 3) return false;
	returnToLobby("You were away too long — rejoin");
	return true;
}

function hasOwnRow(me: PlayerRow | undefined): me is PlayerRow {
	return (
		me !== undefined &&
		Number.isSafeInteger(me.last_x) &&
		Number.isSafeInteger(me.last_y) &&
		me.last_x >= 0 &&
		me.last_x < WIDTH &&
		me.last_y >= 0 &&
		me.last_y < HEIGHT
	);
}

function applyOwnRow(me: PlayerRow) {
	// The camera is the subscription focus, so this move re-targets the
	// listening ring. Only do it before a local dot exists: the located
	// cell is the chunk entry, up to COUNTRY_CHUNK_WIDTH-1 cells off, so
	// it must not fight draw()'s eased follow once motion owns the view.
	if (!motion) {
		camera = { x: me.last_x + 0.5, y: me.last_y + 0.5 };
		dirty = true;
	}
	ownRowMisses = 0;
	updateSubscriptions();
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
		const me = (await client.store.get(["users", myPlayerId])) as unknown as
			| PlayerRow
			| undefined;
		if (hasOwnRow(me)) applyOwnRow(me);
		else if (noteOwnRowMissing()) return;
	} catch (error) {
		if (generation === sessionGeneration)
			setConnection(`Connection interrupted: ${String(error)}`, true);
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
			(country) => String(country.country_id) === countryChoice.value,
		);
		selectedCountryId = selected?.country_id;
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
		if (typeof session.session_id !== "string")
			throw new Error("Session response is missing its player lease");
		sessionId = session.session_id;
		if (typeof session.now === "number") serverSkew = session.now - Date.now();
		if (session.round) {
			roundNumber = session.round.number;
			roundEndsAt = session.round.endsAt;
			updateRoundLabel();
		}
		selectedCountryId = selected?.country_id ?? session.country_id;
		client = createClient({
			url: `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/ws`,
			auth: { token: session.token },
			storeNamespace: NAMESPACE,
		});
		client.on("error", (error) => {
			setConnection(`Connection issue: ${String(error)}`, true);
		});
		// A transient drop only emits "reconnecting" (the SDK resumes on its
		// own), but input and subscription setup must stop until "connected":
		// a listen issued while down is dropped, not queued. A reconnect must
		// also re-join, because the worker may have restarted meanwhile.
		const offline = () => {
			online = false;
			joined = false;
			release();
			setConnection("Disconnected · Reconnecting…", true);
		};
		client.on("disconnected", offline);
		client.on("reconnecting", offline);
		client.on("connected", () => {
			if (playing) {
				online = true;
				joined = false;
				void ensureJoined();
				release();
				setConnection("");
				void locate();
			}
		});
		await client.connect();
		// The join action admits the player and returns the internal user id
		// the roster and dots are keyed by. The worker may still be booting,
		// so retry briefly before treating the world as unavailable.
		for (let i = 0; i < 30 && !joined; i++) {
			try {
				await joinWorld();
			} catch (error) {
				if (error instanceof ActionExecutionError) throw error;
				await new Promise((resolve) => setTimeout(resolve, 100));
			}
		}
		if (!joined) throw new Error("Could not join the world");
		playing = online = true;
		clearTimeout(admissionTimer);
		admissionTimer = setTimeout(checkAdmission, 3000);
		scheduleRoundEnd();
		lobby.hidden = true;
		scoreboardPanel.hidden = false;
		canvas.focus({ preventScroll: true });
		if (matchMedia("(pointer: coarse)").matches) startJoystick();
		else flash(element("controls-hint"));
		client.store.subscribe("countries", { limit: 1000 }, (rows) => {
			const list = rows as Country[];
			latestCountries = list;
			scoreboard(list);
		});
		// Cold roster, subscribed once: identity and country per dot, joined
		// at render. Fires only on admission, chunk crossing, and leave.
		rosterUnsub?.unsubscribe();
		rosterUnsub = client.store.subscribe("users", { limit: 2048 }, (rows) => {
			roster.clear();
			for (const row of rows as PlayerRow[]) roster.set(row.id, row);
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
			// The find bar and some browser modals swallow blur: clear held keys
			// whenever the document itself lost focus.
			if (!document.hasFocus()) release();
			void ensureJoined();
			publish();
			void locate();
		}, 500);
		setConnection("");
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
	// The camera keeps easing after the dot stops: stay active until it has
	// settled exactly on the target.
	const settling =
		position !== undefined &&
		(camera.x !== position.x + 0.5 || camera.y !== position.y + 0.5);
	if (!dirty && !moved && !settling) {
		// Keep the easing clock current: elapsed must never span an idle pause,
		// or the first frame after it would ease by the whole pause at once.
		lastFrame = now;
		return;
	}
	lastFrame += Math.floor((elapsed + 0.1) / FRAME_MS) * FRAME_MS;
	dirty = false;
	if (position) {
		drawnX = position.x;
		drawnY = position.y;
		camera.x = approach(camera.x, position.x + 0.5, elapsed, CAMERA_TAU);
		camera.y = approach(camera.y, position.y + 0.5, elapsed, CAMERA_TAU);
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
		const chunkX = (index % COUNTRY_COLUMNS) * COUNTRY_CHUNK_WIDTH,
			chunkY = Math.floor(index / COUNTRY_COLUMNS) * COUNTRY_CHUNK_HEIGHT;
		for (
			let k = Math.floor((xMin - chunkX) / WIDTH);
			k <= Math.floor((xMax - chunkX) / WIDTH);
			k++
		)
			ctx.drawImage(
				chunk.image,
				left + (chunkX + k * WIDTH) * zoom,
				top + chunkY * zoom,
				COUNTRY_CHUNK_WIDTH * zoom,
				COUNTRY_CHUNK_HEIGHT * zoom,
			);
	}
	// Coordinates arrive per user chunk, already bounded to the subscribed
	// viewport; join them here so the draw loop has a single dot map.
	for (const dots of userChunks.values())
		for (const dot of dots) visibleDots.set(dot.player_id, dot);
	// Draw yourself last so nearby dots and names do not cover your marker.
	const self = visibleDots.get(myPlayerId) ?? motion?.dot;
	if (self) {
		visibleDots.delete(self.player_id);
		visibleDots.set(self.player_id, self);
	}
	for (const dot of visibleDots.values()) {
		const key = dot.player_id;
		// Simple client-side join: hot dot plus its cold roster row. Dots
		// without a row are mid-join/leave races; draw them neutrally once.
		const meta = roster.get(key);
		const isBot = meta?.is_bot ?? false;
		const display =
			key === myPlayerId && position ? { x: position.x, y: position.y } : dot;
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
		ctx.strokeStyle = key === myPlayerId ? "#ffe3a0" : "#0d1822";
		ctx.stroke();
	}
	// Names in their own pass: font and text state change twice per frame
	// instead of once per visible player.
	ctx.textAlign = "center";
	ctx.lineJoin = "round";
	ctx.strokeStyle = "#0d1822";
	ctx.lineWidth = 3;
	ctx.font = "10px Silkscreen, monospace";
	ctx.fillStyle = "#bccacb";
	for (const dot of visibleDots.values()) {
		if (dot.player_id === myPlayerId) continue;
		const meta = roster.get(dot.player_id);
		if (!meta?.name || meta.is_bot) continue;
		const dotX = dot.x + WIDTH * Math.round((camera.x - dot.x) / WIDTH);
		const x = left + (dotX + 0.5) * zoom,
			y = top + (dot.y + 0.5) * zoom;
		ctx.strokeText(meta.name, x, y - zoom - 7, 120);
		ctx.fillText(meta.name, x, y - zoom - 7, 120);
	}
	const selfMeta = roster.get(myPlayerId);
	if (self && selfMeta?.name && !selfMeta.is_bot) {
		const display = position ?? self;
		const dotX = display.x + WIDTH * Math.round((camera.x - display.x) / WIDTH);
		const x = left + (dotX + 0.5) * zoom,
			y = top + (display.y + 0.5) * zoom;
		ctx.font = "bold 11px Silkscreen, monospace";
		ctx.fillStyle = "#ffe3a0";
		ctx.strokeText(selfMeta.name, x, y - zoom - 7, 120);
		ctx.fillText(selfMeta.name, x, y - zoom - 7, 120);
	}
}
requestAnimationFrame(draw);

// Canvas text does not repaint when a webfont finishes loading: mark the
// scene dirty once the display face lands.
void document.fonts.ready.then(() => {
	dirty = true;
});
