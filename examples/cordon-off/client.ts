import {
	ActionExecutionError,
	createClient,
	type JsonValue,
	type ListenHandle,
	type SubscriptionHandle,
	type ZyncBaseClient,
} from "@zyncbase/client";
import nipplejs from "nipplejs";
import {
	approach,
	JoystickSteering,
	LocalMotion,
	type MotionDot,
	steps,
} from "./motion";
import { setMood, startMusic, stopMusic } from "./music";
import { sfx } from "./sfx";
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
	PLAYER_RESUME_GRACE_MS,
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
const ctx = canvas.getContext("2d", { alpha: false });
if (!ctx) throw new Error("Your browser needs Canvas support");
const connection = element("connection");
const controlsHint = element("controls-hint");
const countriesList = element("countries");
const countryCount = element("country-count");
const countryDetail = element("country-detail");
const countryPreview = element("country-preview");
const countrySlots = element("country-slots");
const countrySwatch = element("country-swatch");
const errorLabel = element("error");
const joinForm = element("join");
const joinButton = element<HTMLButtonElement>("join-button");
const joystickZone = element("joystick");
const lobby = element("lobby");
const newCountry = element("new-country");
const playerInput = element<HTMLInputElement>("player-name");
const roundChip = element("round");
const scoreboardPanel = element("scoreboard");
const scoreboardToggle = element<HTMLButtonElement>("scoreboard-toggle");
const countryChoice = element<HTMLSelectElement>("country-choice");
const countryInput = element<HTMLInputElement>("country");
const countries = new Map<number, Country>();
// Cold roster from the users table, keyed by identity: one row per live
// player plus reconnect-grace tombstones. Updated only on admission, chunk
// crossing, and leave — never per tick. The by-slot view joins packed dots to
// names/countries at render.
const roster = new Map<string, PlayerRow>();
const rosterBySlot = new Map<number, PlayerRow>();
let rosterSubscription: SubscriptionHandle | undefined;
let countriesSubscription: SubscriptionHandle | undefined;
const chunks = new Map<
	number,
	{ image: HTMLCanvasElement; colorIndexes: Uint8Array }
>();
const userChunks = new Map<number, Dot[]>();
type PendingUnlisten = Promise<ListenHandle>;
const subscriptions = new Map<number, PendingUnlisten>();
const userSubscriptions = new Map<number, PendingUnlisten>();
const held = new Map<string, Direction>();
let client: ZyncBaseClient | undefined;
let online = false;
// Session phase. "lobby" (no session), "joining" (submit in flight), or
// "playing"; transport (`online`) and admission (`joined`) stay independent.
type Phase = "lobby" | "joining" | "playing";
let phase: Phase = "lobby";
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
let selectedCountryId: number | undefined;
let sessionId = "";
let lobbyCountries: Country[] = [];
let availableSlots = 0;
let myPlayerId = "",
	mySlot = 0,
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
// Dirty-frame rendering: the scene repaints only when something it draws changes.
let dirty = true;
let drawnX = Number.NaN;
let drawnY = Number.NaN;
let lastCountrySubKey = "";
let lastUserSubKey = "";
// A rejected listen removes itself from its map, but the key-gated check
// below would never notice — this flag forces the next frame to re-sync.
let subResyncNeeded = false;
let focusWatch: ReturnType<typeof setInterval> | undefined;
let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
let joinRetryTimer: ReturnType<typeof setTimeout> | undefined;
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
// Placeholder camera until locate() reads our roster row; applyOwnRow recenters.
const INITIAL_CAMERA = { x: 933, y: 276 };
// Join boot: retry while the worker starts, then give up.
const JOIN_ATTEMPTS = 30;
const JOIN_ATTEMPT_MS = 100;
// A rejected or in-flight join re-checks on this cadence.
const JOIN_RETRY_MS = 500;
const MOVE_RETRY_MS = 500;
const FOCUS_WATCH_MS = 500;
// Consecutive self-locate misses tolerated before returning to the lobby.
const MAX_OWN_ROW_MISSES = 3;
const LOCATE_THROTTLE_MS = 1500;
const HEALTH_TIMEOUT_MS = 3000;
const HEALTH_POLL_MS = 5000;
const ADMISSION_CHECK_MS = 3000;
// Navigate just after the server's round boundary so the deploy is in place.
const ROUND_NAV_BUFFER_MS = 1200;
const ROUND_URGENT_MS = 30_000;
const WHEEL_STEP_PX = 80;
const MIN_SCALE = 2;
const MAX_SCALE = 16;

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
	roundChip.classList.toggle("urgent", remaining <= ROUND_URGENT_MS);
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
	const remaining =
		roundEndsAt - (Date.now() + serverSkew) + ROUND_NAV_BUFFER_MS;
	roundTimer = setTimeout(
		() => {
			if (phase !== "playing") return;
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
	newCountry.hidden = !creating;
	countryInput.disabled = !creating;
	countryInput.required = creating;
	countryPreview.hidden = !country;
	if (country) {
		countrySwatch.style.background = country.color;
		countryDetail.textContent = `${country.name} · ${country.count.toLocaleString()} land pixels`;
	}
	joinButton.disabled =
		phase !== "lobby" || !worldReady || (!creating && !country);
}
countryChoice.addEventListener("change", updateCountryChoice);

// Keep the native picker intact during polling unless its options change.
function pickerNeedsRebuild(rows: Country[]) {
	return (
		countryChoice.options.length === 1 ||
		rows.length !== lobbyCountries.length ||
		rows.some(
			(country, i) => country.country_id !== lobbyCountries[i]?.country_id,
		)
	);
}

function rebuildPicker(rows: Country[], slots: number) {
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
function syncCreateOption(slots: number) {
	const createOption = countryChoice.options.item(
		countryChoice.options.length - 1,
	);
	if (createOption?.value !== "new") return;
	createOption.disabled = slots === 0;
	if (createOption.disabled && countryChoice.value === "new")
		countryChoice.value = "";
}

// One reconciliation pass must sync slots, rows, and the native picker.
function showLobbyCountries(all: Country[]) {
	const rows = all.filter((country) => !country.is_bot);
	rows.sort((a, b) => a.name.localeCompare(b.name));
	const slots = MAX_COUNTRIES - all.length;
	availableSlots = slots;
	if (pickerNeedsRebuild(rows)) rebuildPicker(rows, slots);
	syncCreateOption(slots);
	lobbyCountries = rows;
	countryChoice.disabled = false;
	countrySlots.textContent = slots
		? `${all.length} / ${MAX_COUNTRIES} countries · ${slots} ${slots === 1 ? "slot" : "slots"} available`
		: `All ${MAX_COUNTRIES} slots are taken. Join an existing country.`;
	updateCountryChoice();
}

type Health = {
	now?: number;
	round?: { number: number; endsAt: number };
	ready?: boolean;
	countries: Country[];
};

function applyHealth(response: Response, health: Health) {
	if (typeof health.now === "number") serverSkew = health.now - Date.now();
	if (health.round) {
		roundNumber = health.round.number;
		roundEndsAt = health.round.endsAt;
		updateRoundLabel();
	}
	if (!response.ok || health.ready !== true) throw new Error();
	worldReady = true;
	showLobbyCountries(health.countries);
	if (errorLabel.textContent === OFFLINE) errorLabel.textContent = "";
	if (connection.textContent.startsWith(OFFLINE)) setConnection("");
}

function markWorldOffline() {
	worldReady = false;
	countryChoice.disabled = true;
	updateCountryChoice();
	errorLabel.textContent = OFFLINE;
	setConnection(`${OFFLINE} · Retrying…`, true);
}

// In-flight health polls must not alter the UI after joining starts.
async function checkHealth() {
	if (phase !== "lobby") return;
	try {
		const response = await fetch("/health", {
			signal: AbortSignal.timeout(HEALTH_TIMEOUT_MS),
		});
		const health = (await response.json()) as Health;
		if (phase !== "lobby") return;
		applyHealth(response, health);
	} catch {
		if (phase !== "lobby") return;
		markWorldOffline();
	}
}
void checkHealth();
setInterval(() => void checkHealth(), HEALTH_POLL_MS);

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
	if (phase === "playing") updateSubscriptions();
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

function chunkImage(colorIndexes: Uint8Array, target?: HTMLCanvasElement) {
	const image = target ?? document.createElement("canvas");
	if (!target) {
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
	return a.x !== b.x || a.y !== b.y || a.slot !== b.slot;
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
	const self = dots.find((dot) => dot.slot === mySlot);
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

// The music tracks the land being painted, not the interpolated dot: the
// server paints each step's destination, so the cell under the dot is already
// ours. Looking one step ahead of the confirmed cell (the current cell when
// idle) keeps the mood stable through a crossing instead of flickering every
// time a step confirms.
function updateMood() {
	if (phase !== "playing" || !online || !motion) return;
	const [dx, dy] = steps[direction];
	const y = motion.dot.y + dy;
	if (y < 0 || y >= HEIGHT) {
		setMood("calm");
		return;
	}
	const owner = ownerAt(wrapX(motion.dot.x + dx), y);
	const mine = myColorIndex();
	setMood(owner && mine && owner !== mine ? "hostile" : "calm");
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

// Water-only country chunks can never change: never subscribe.
function addVisibleColumns(
	grid: ChunkGrid,
	visible: Set<number>,
	first: number,
	last: number,
	top: number,
	bottom: number,
) {
	for (let col = first; col <= last; col++)
		for (let y = top; y <= bottom; y++) {
			const index = y * grid.columns + col;
			if (!grid.water?.[index]) visible.add(index);
		}
}

// One walk covers seam copies, row bounds, and the water filter for either grid.
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
		addVisibleColumns(grid, visible, first, last, top, bottom);
	}
	return visible;
}

function subscriptionKey(grid: ChunkGrid) {
	const { xMin, xMax, yMin, yMax } = subscriptionBounds(grid);
	return `${Math.floor(xMin / grid.width)},${Math.floor(xMax / grid.width)},${Math.floor(yMin / grid.height)},${Math.floor(yMax / grid.height)}`;
}

// Serve exactly the currently visible chunks of one grid: unlisten and drop
// tiles that left the ring, listen for tiles that entered it. A listen issued
// while the transport is down queues until the session is ready, so ring
// changes during an outage are safe; a rejected handle would pin its chunk
// index forever, so it removes itself below.
function syncChunks<R>(
	store: ZyncBaseClient["store"],
	table: string,
	subs: Map<number, PendingUnlisten>,
	cache: Map<number, R>,
	receive: (row: JsonValue) => void,
	visible: Set<number>,
) {
	for (const [index, unlisten] of subs) {
		if (visible.has(index)) continue;
		void unlisten.then((handle) => handle.unlisten()).catch(() => {});
		subs.delete(index);
		cache.delete(index);
	}
	for (const index of visible) {
		if (subs.has(index)) continue;
		// Direct document listens: chunk ids are the store primary keys, so
		// no secondary index or query-subscription group is needed per tile.
		const key = index;
		const unlisten = store.listen([table, String(index)], (row) => {
			if (!subs.has(key)) return;
			if (row) receive(row);
			else {
				cache.delete(key);
				dirty = true;
			}
		});
		subs.set(index, unlisten);
		void unlisten.catch(() => {
			if (subs.get(key) !== unlisten) return;
			subs.delete(key);
			subResyncNeeded = true;
		});
	}
}

// Drop every served chunk of one grid (session end).
function clearChunks<R>(
	subs: Map<number, PendingUnlisten>,
	cache: Map<number, R>,
) {
	for (const unlisten of subs.values())
		void unlisten.then((handle) => handle.unlisten()).catch(() => {});
	subs.clear();
	cache.clear();
}

// Both grids need the same serve/unserve bookkeeping in one pass; bounds are
// recorded whenever they are served — offline ring changes queue on the wire
// and flush when the session comes back.
function updateSubscriptions() {
	if (!client || phase !== "playing") return;
	subResyncNeeded = false;
	lastCountrySubKey = subscriptionKey(COUNTRY_GRID);
	lastUserSubKey = subscriptionKey(USER_GRID);
	syncChunks(
		client.store,
		"country_chunks",
		subscriptions,
		chunks,
		(row) => receiveCountryChunk(row as CountryChunkRow),
		visibleChunks(COUNTRY_GRID),
	);
	syncChunks(
		client.store,
		"user_chunks",
		userSubscriptions,
		userChunks,
		(row) => receiveUserChunk(row as UserChunkRow),
		visibleChunks(USER_GRID),
	);
}

// Recompute tiles only when the prefetched bounds cross a chunk edge or a
// listen was rejected: chunk updates arrive at tick rate and must not
// rescan subscriptions each time.
function maybeUpdateSubscriptions() {
	if (
		!subResyncNeeded &&
		subscriptionKey(COUNTRY_GRID) === lastCountrySubKey &&
		subscriptionKey(USER_GRID) === lastUserSubKey
	)
		return;
	updateSubscriptions();
}

function scoreboard(rows: Country[]) {
	// roster rows include reconnect-grace tombstones, so a departed player
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
	countryCount.textContent = String(rows.length);
	const mine = myCountryId();
	countriesList.replaceChildren(
		...[...rows]
			.sort((a, b) => b.count - a.count)
			.map((country) => {
				const li = document.createElement("li");
				li.classList.toggle("local", country.country_id === mine);
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

// Loss cues come from the country rows: an enemy enclosure taking our land.
// First sight initializes silently: joining an already-active country must not
// replay its history.
const heardLosses = new Map<number, number>();

function watchCountryLosses(rows: Country[]) {
	if (phase !== "playing") return;
	const mine = myCountryId();
	for (const row of rows) {
		const lost = row.lost ?? 0;
		const seen = heardLosses.get(row.country_id);
		if (row.country_id === mine && seen !== undefined && lost > seen)
			sfx.lost();
		heardLosses.set(row.country_id, lost);
	}
}

// Capture cues come from our own player row: only fills our own paint closed.
// Teammates and bots gain land on their own rows. First sight initializes
// silently so a mid-round join does not replay history.
let heardCaptured: number | undefined;

function watchOwnCaptures(rows: PlayerRow[]) {
	if (phase !== "playing") return;
	const me = rows.find((row) => row.id === myPlayerId);
	if (!me) return;
	const captured = me.captured ?? 0;
	if (heardCaptured !== undefined && captured > heardCaptured) sfx.capture();
	heardCaptured = captured;
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
	})) as { user_id?: unknown; slot?: unknown };
	if (typeof result.user_id !== "string" || !result.user_id)
		throw new Error("Join returned no player identity");
	await client.presence.set({});
	myPlayerId = result.user_id;
	mySlot = Number.isSafeInteger(result.slot) ? (result.slot as number) : 0;
	joined = true;
	joinedAt = performance.now();
	lastOwnDot = 0;
	ownRowMisses = 0;
	setConnection("");
	publishDirection();
}

// A rejected join (full world, missing country, bad name) is final.
function retryJoinSoon() {
	if (joinRetryTimer !== undefined) return;
	joinRetryTimer = setTimeout(() => {
		joinRetryTimer = undefined;
		void ensureJoined();
	}, JOIN_RETRY_MS);
}

async function ensureJoined() {
	if (!client || !online || joined) return;
	if (joinInFlight) {
		retryJoinSoon();
		return;
	}
	joinInFlight = true;
	try {
		await joinWorld();
		clearTimeout(reconnectTimer);
		reconnectTimer = undefined;
		clearTimeout(joinRetryTimer);
		joinRetryTimer = undefined;
	} catch (error) {
		if (error instanceof ActionExecutionError) returnToLobby(error.message);
		else retryJoinSoon();
	} finally {
		joinInFlight = false;
	}
}

// Remove presence immediately on an intentional exit; connection teardown
// also removes it if this message cannot be sent.
function leave(): Promise<void> {
	if (!client || !joined) return Promise.resolve();
	return client.presence.remove();
}

function publishDirection() {
	motion?.update(motion.dot, online ? direction : "idle", performance.now());
	if (!online || !client || !joined) return;
	const moveClient = client;
	const moveDirection = direction;
	const moveSeq = ++seq;
	const isCurrent = () =>
		online &&
		joined &&
		client === moveClient &&
		direction === moveDirection &&
		seq === moveSeq;
	const send = () => {
		void moveClient.actions
			.call("player_move", { direction: moveDirection, seq: moveSeq })
			.catch(() => {
				if (!isCurrent()) return;
				setTimeout(() => {
					if (isCurrent()) send();
				}, MOVE_RETRY_MS);
			});
	};
	send();
}

function setDirection(next: Direction) {
	if (next === direction) return;
	direction = next;
	lastSentDirection = next;
	if (next !== "idle") prefetchDirection = next;
	publishDirection();
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
	if (phase !== "playing" || !online) return;
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
	if (phase === "playing") canvas.focus({ preventScroll: true });
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
	void leave().catch(() => {});
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
	const zone = joystickZone;
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
	joystickZone.hidden = true;
}

function setScale(next: number) {
	if (phase !== "playing") return;
	const clamped = Math.min(MAX_SCALE, Math.max(MIN_SCALE, Math.round(next)));
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
		if (phase !== "playing" || event.ctrlKey) return;
		event.preventDefault();
		const unit =
			event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? innerHeight : 1;
		wheelAccum += event.deltaY * unit;
		if (Math.abs(wheelAccum) >= WHEEL_STEP_PX) {
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
	const leavingClient = client;
	const leavePromise = leave();
	sessionGeneration++;
	clearTimeout(roundTimer);
	clearTimeout(admissionTimer);
	clearTimeout(reconnectTimer);
	reconnectTimer = undefined;
	clearTimeout(joinRetryTimer);
	joinRetryTimer = undefined;
	clearInterval(focusWatch);
	focusWatch = undefined;
	joined = false;
	ownRowMisses = 0;
	sessionId = "";
	phase = "lobby";
	online = false;
	void leavePromise.catch(() => {}).finally(() => leavingClient?.disconnect());
	clearChunks(subscriptions, chunks);
	clearChunks(userSubscriptions, userChunks);
	if (countriesSubscription)
		void countriesSubscription.unsubscribe().catch(() => {});
	countriesSubscription = undefined;
	if (rosterSubscription) void rosterSubscription.unsubscribe().catch(() => {});
	rosterSubscription = undefined;
	roster.clear();
	rosterBySlot.clear();
	lobby.hidden = false;
	scoreboardPanel.hidden = true;
	stopJoystick();
	stopMusic();
	heardLosses.clear();
	heardCaptured = undefined;
	if (document.fullscreenElement)
		void document.exitFullscreen().catch(() => {});
	errorLabel.textContent = message;
	setConnection("");
	dirty = true;
	updateCountryChoice();
	void checkHealth();
}

// The roster can change between the lobby poll and the join action.
function checkAdmission() {
	if (phase !== "playing" || lastOwnDot !== 0) return;
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
	if (phase !== "playing" || !joined || joinInFlight) return false;
	if (performance.now() - joinedAt < ADMISSION_GRACE_MS) return false;
	ownRowMisses++;
	if (ownRowMisses < MAX_OWN_ROW_MISSES) return false;
	returnToLobby("You were away too long — rejoin");
	return true;
}

function hasOwnRow(me: PlayerRow | undefined): me is PlayerRow {
	return (
		me !== undefined &&
		Number.isSafeInteger(me.slot) &&
		me.slot > 0 &&
		Number.isSafeInteger(me.last_x) &&
		Number.isSafeInteger(me.last_y) &&
		me.last_x >= 0 &&
		me.last_x < WIDTH &&
		me.last_y >= 0 &&
		me.last_y < HEIGHT
	);
}

function applyOwnRow(me: PlayerRow) {
	// The join reply carries the slot, but a reconnect that lands on an older
	// roster read can arrive first; the row is authoritative either way.
	mySlot = me.slot;
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
	if (
		!client ||
		!online ||
		locating ||
		performance.now() - lastOwnDot < LOCATE_THROTTLE_MS
	)
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

type SessionInfo = {
	session_id: string;
	token: string;
	now?: number;
	round?: { number: number; endsAt: number };
	country_id?: number;
	error?: string;
};

// Resolves what to join before any network I/O: nickname, target country,
// and create-vs-pick validation. Throws with the lobby error message.
function resolveJoinSelection() {
	nickname = playerName(playerInput.value);
	const selected = lobbyCountries.find(
		(country) => String(country.country_id) === countryChoice.value,
	);
	selectedCountryId = selected?.country_id;
	let countryNameToJoin: string;
	if (countryChoice.value === "new") {
		if (availableSlots === 0)
			throw new Error("All country slots are taken. Join an existing country.");
		countryNameToJoin = countryName(countryInput.value);
		if (
			lobbyCountries.some(
				(country) =>
					country.name.toLowerCase() === countryNameToJoin.toLowerCase(),
			)
		)
			throw new Error(
				"That country already exists. Choose it from the list to join.",
			);
	} else {
		if (!selected) throw new Error("Choose a country to join.");
		countryNameToJoin = selected.name;
	}
	return { selected, countryNameToJoin };
}

// POST /session: fetches the lease and applies round/skew/identity state.
async function requestSession(
	selected: Country | undefined,
	countryNameToJoin: string,
): Promise<SessionInfo> {
	const response = await fetch("/session", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(
			selected
				? { countryId: selected.country_id }
				: { countryName: countryNameToJoin },
		),
	});
	const session = (await response.json()) as SessionInfo;
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
	return session;
}

// A transient drop only emits "reconnecting" (the SDK resumes on its
// own and replays subscriptions), but input must stop until "connected",
// and a reconnect must also re-join: the worker may have restarted
// meanwhile.
function wireLifecycle(next: ZyncBaseClient) {
	next.on("error", (error) => {
		setConnection(`Connection issue: ${String(error)}`, true);
	});
	const offline = () => {
		online = false;
		joined = false;
		release();
		if (phase === "playing" && reconnectTimer === undefined) {
			reconnectTimer = setTimeout(() => {
				reconnectTimer = undefined;
				if (phase === "playing" && (!online || !joined))
					returnToLobby("You were away too long — rejoin");
			}, PLAYER_RESUME_GRACE_MS);
		}
		setConnection("Disconnected · Reconnecting…", true);
	};
	next.on("disconnected", offline);
	next.on("reconnecting", offline);
	next.on("connected", () => {
		if (phase === "playing") {
			online = true;
			joined = false;
			release();
			void ensureJoined().then(() => {
				if (phase !== "playing" || !online || !joined) return;
				setConnection("");
				void locate();
			});
		}
	});
}

// Creates and connects the session client, then retries the join action
// while the worker may still be booting.
async function startSessionClient(session: SessionInfo) {
	const next = createClient({
		url: `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/ws`,
		auth: { token: session.token },
		storeNamespace: NAMESPACE,
	});
	client = next;
	wireLifecycle(next);
	await next.connect();
	// The join action admits the player and returns the internal user id
	// the roster and dots are keyed by.
	for (let i = 0; i < JOIN_ATTEMPTS && !joined; i++) {
		try {
			await joinWorld();
		} catch (error) {
			if (error instanceof ActionExecutionError) throw error;
			await new Promise((resolve) => setTimeout(resolve, JOIN_ATTEMPT_MS));
		}
	}
	if (!joined) throw new Error("Could not join the world");
	return next;
}

function rebuildRoster(rows: PlayerRow[], generation: number) {
	if (generation !== sessionGeneration) return;
	roster.clear();
	rosterBySlot.clear();
	for (const row of rows) {
		roster.set(row.id, row);
		if (Number.isSafeInteger(row.slot) && row.slot > 0)
			rosterBySlot.set(row.slot, row);
	}
	watchOwnCaptures(rows);
	scoreboard(latestCountries);
	dirty = true;
}

// Country palette + counts for the scoreboard, plus the cold roster:
// identity and country per dot, joined at render. Returns false when a
// returnToLobby superseded the swap, so the caller must stop.
async function subscribeColdStores(next: ZyncBaseClient): Promise<boolean> {
	const countriesGeneration = sessionGeneration;
	if (countriesSubscription) await countriesSubscription.unsubscribe();
	if (countriesGeneration !== sessionGeneration) return false;
	countriesSubscription = undefined;
	const nextCountriesSubscription = await next.store.subscribe(
		"countries",
		{ limit: 1000 },
		(rows) => {
			if (countriesGeneration !== sessionGeneration) return;
			const list = rows as Country[];
			latestCountries = list;
			scoreboard(list);
			watchCountryLosses(list);
		},
	);
	if (countriesGeneration !== sessionGeneration) {
		await nextCountriesSubscription.unsubscribe();
		return false;
	}
	countriesSubscription = nextCountriesSubscription;
	const rosterGeneration = sessionGeneration;
	if (rosterSubscription) await rosterSubscription.unsubscribe();
	if (rosterGeneration !== sessionGeneration) return false;
	rosterSubscription = undefined;
	const nextRosterSubscription = await next.store.subscribe(
		"users",
		{ limit: 2048 },
		(rows) => rebuildRoster(rows as PlayerRow[], rosterGeneration),
	);
	if (rosterGeneration !== sessionGeneration) {
		await nextRosterSubscription.unsubscribe();
		return false;
	}
	rosterSubscription = nextRosterSubscription;
	return true;
}

// From lease to live world: admission state, lobby teardown, cold stores.
async function enterGame(next: ZyncBaseClient) {
	phase = "playing";
	online = true;
	clearTimeout(admissionTimer);
	admissionTimer = setTimeout(checkAdmission, ADMISSION_CHECK_MS);
	scheduleRoundEnd();
	lobby.hidden = true;
	scoreboardPanel.hidden = false;
	canvas.focus({ preventScroll: true });
	if (matchMedia("(pointer: coarse)").matches) startJoystick();
	else flash(controlsHint);
	sfx.deploy();
	startMusic();
	if (!(await subscribeColdStores(next))) return;
	motion = undefined;
	camera = { ...INITIAL_CAMERA };
	release();
	updateSubscriptions();
	dirty = true;
	clearInterval(focusWatch);
	focusWatch = setInterval(() => {
		// Some browser modals swallow blur, so keep only this local safety check.
		if (phase === "playing" && online && !document.hasFocus()) release();
	}, FOCUS_WATCH_MS);
	setConnection("");
	void locate();
}

joinForm.addEventListener("submit", async (event) => {
	event.preventDefault();
	if (phase !== "lobby" || !worldReady) return;
	if (matchMedia("(pointer: coarse)").matches && document.fullscreenEnabled)
		void document.documentElement
			.requestFullscreen({ navigationUI: "hide" })
			.catch(() => {});
	phase = "joining";
	updateCountryChoice();
	errorLabel.textContent = "";
	lastOwnDot = 0;
	latestCountries = [];
	clearTimeout(admissionTimer);
	try {
		const { selected, countryNameToJoin } = resolveJoinSelection();
		const session = await requestSession(selected, countryNameToJoin);
		const next = await startSessionClient(session);
		await enterGame(next);
	} catch (error) {
		returnToLobby(error instanceof Error ? error.message : String(error));
	} finally {
		updateCountryChoice();
	}
});

const visibleDots = new Map<number, Dot>();

// The visible world slice in screen space, shared by every draw layer.
type View = {
	left: number;
	top: number;
	xMin: number;
	xMax: number;
	zoom: number;
};

// Background plus one full world copy per seam-crossing segment (the world
// repeats every WIDTH, so the map pans forever), then every visible
// country-chunk copy.
function drawWorld(view: View) {
	ctx.fillStyle = "#0d1822";
	ctx.fillRect(0, 0, width, height);
	const firstCopy = Math.floor(view.xMin / WIDTH),
		lastCopy = Math.floor(view.xMax / WIDTH);
	for (let k = firstCopy; k <= lastCopy; k++)
		ctx.drawImage(
			base,
			view.left + k * WIDTH * view.zoom,
			view.top,
			WIDTH * view.zoom,
			HEIGHT * view.zoom,
		);
	for (const [index, chunk] of chunks) {
		const chunkX = (index % COUNTRY_COLUMNS) * COUNTRY_CHUNK_WIDTH,
			chunkY = Math.floor(index / COUNTRY_COLUMNS) * COUNTRY_CHUNK_HEIGHT;
		for (
			let k = Math.floor((view.xMin - chunkX) / WIDTH);
			k <= Math.floor((view.xMax - chunkX) / WIDTH);
			k++
		)
			ctx.drawImage(
				chunk.image,
				view.left + (chunkX + k * WIDTH) * view.zoom,
				view.top + chunkY * view.zoom,
				COUNTRY_CHUNK_WIDTH * view.zoom,
				COUNTRY_CHUNK_HEIGHT * view.zoom,
			);
	}
}

// Coordinates arrive per user chunk, already bounded to the subscribed
// viewport; join them here so the draw loop has a single dot map. Yourself
// goes last so nearby dots and names do not cover your marker.
function collectVisibleDots(): Dot | undefined {
	visibleDots.clear();
	for (const dots of userChunks.values())
		for (const dot of dots) visibleDots.set(dot.slot, dot);
	const self = visibleDots.get(mySlot) ?? motion?.dot;
	if (self) {
		visibleDots.delete(self.slot);
		visibleDots.set(self.slot, self);
	}
	return self;
}

function paintDot(
	dot: Dot,
	view: View,
	position: { x: number; y: number } | undefined,
) {
	const key = dot.slot;
	// Simple client-side join: hot dot plus its cold roster row. Dots
	// without a row are mid-join/leave races; draw them neutrally once.
	const meta = rosterBySlot.get(key);
	const isBot = meta?.is_bot ?? false;
	const display =
		key === mySlot && position ? { x: position.x, y: position.y } : dot;
	// Draw the dot in whichever world copy is nearest the camera.
	const dotX = display.x + WIDTH * Math.round((camera.x - display.x) / WIDTH);
	const x = view.left + (dotX + 0.5) * view.zoom,
		y = view.top + (display.y + 0.5) * view.zoom;
	ctx.beginPath();
	const radius = Math.max(3, view.zoom * 0.48);
	if (isBot) ctx.rect(x - radius, y - radius, radius * 2, radius * 2);
	else ctx.arc(x, y, radius, 0, Math.PI * 2);
	ctx.fillStyle = (meta && countries.get(meta.country_id)?.color) ?? "white";
	ctx.fill();
	ctx.lineWidth = 2;
	ctx.strokeStyle = key === mySlot ? "#ffe3a0" : "#0d1822";
	ctx.stroke();
}

function drawDots(view: View, position: { x: number; y: number } | undefined) {
	for (const dot of visibleDots.values()) paintDot(dot, view, position);
}

// Names in their own pass: font and text state change twice per frame
// instead of once per visible player.
function drawNames(
	view: View,
	position: { x: number; y: number } | undefined,
	self: Dot | undefined,
) {
	ctx.textAlign = "center";
	ctx.lineJoin = "round";
	ctx.strokeStyle = "#0d1822";
	ctx.lineWidth = 3;
	ctx.font = "10px Silkscreen, monospace";
	ctx.fillStyle = "#bccacb";
	for (const dot of visibleDots.values()) {
		if (dot.slot === mySlot) continue;
		const meta = rosterBySlot.get(dot.slot);
		if (!meta?.name || meta.is_bot) continue;
		const dotX = dot.x + WIDTH * Math.round((camera.x - dot.x) / WIDTH);
		const x = view.left + (dotX + 0.5) * view.zoom,
			y = view.top + (dot.y + 0.5) * view.zoom;
		ctx.strokeText(meta.name, x, y - view.zoom - 7, 120);
		ctx.fillText(meta.name, x, y - view.zoom - 7, 120);
	}
	const selfMeta = rosterBySlot.get(mySlot);
	if (self && selfMeta?.name && !selfMeta.is_bot) {
		const display = position ?? self;
		const dotX = display.x + WIDTH * Math.round((camera.x - display.x) / WIDTH);
		const x = view.left + (dotX + 0.5) * view.zoom,
			y = view.top + (display.y + 0.5) * view.zoom;
		ctx.font = "bold 11px Silkscreen, monospace";
		ctx.fillStyle = "#ffe3a0";
		ctx.strokeText(selfMeta.name, x, y - view.zoom - 7, 120);
		ctx.fillText(selfMeta.name, x, y - view.zoom - 7, 120);
	}
}

function draw(now: number) {
	requestAnimationFrame(draw);
	const elapsed = now - lastFrame;
	// Allow timestamp rounding at the frame boundary without accumulating drift.
	if (elapsed + 0.1 < FRAME_MS) return;
	const position = motion?.position(now);
	updateMood();
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
	const viewZoom =
		phase === "playing" ? scale : Math.max(width / WIDTH, height / HEIGHT);
	const view = {
		left: width / 2 - camera.x * viewZoom,
		top: height / 2 - camera.y * viewZoom,
		xMin: camera.x - width / viewZoom / 2,
		xMax: camera.x + width / viewZoom / 2,
		zoom: viewZoom,
	};
	drawWorld(view);
	const self = collectVisibleDots();
	drawDots(view, position);
	drawNames(view, position, self);
}
requestAnimationFrame(draw);

// Canvas text does not repaint when a webfont finishes loading: mark the
// scene dirty once the display face lands.
void document.fonts.ready.then(() => {
	dirty = true;
});
