// Adaptive background loop: two short synthesized patterns running on their
// own clocks into crossfaded gains. Calm plays on own/neutral/water cells, the
// tense pattern on another country's land. Switching is a gain ramp, not a
// restart, so the loop stays continuous; the mood must hold before it fades.
// Tempo tracks the dot's movement speed: slow at a standstill, quick on fast
// terrain.

import { audio, masterChannel, scheduleTone } from "./sfx";
import { RULES } from "./shared";

export type Mood = "calm" | "hostile";

type Track = {
	mood: Mood;
	notes: (number | null)[];
	baseStep: number;
	step: number;
	type: OscillatorType;
	volume: number;
	target: number;
	gain: GainNode;
	index: number;
	nextAt: number;
};

// A minor pentatonic arpeggio, and a low pulse with a tritone stab.
const CALM_NOTES = [
	220,
	null,
	329.63,
	null,
	392,
	null,
	329.63,
	null,
	293.66,
	null,
	261.63,
	null,
	293.66,
	null,
	329.63,
	null,
];
const HOSTILE_NOTES = [
	110,
	null,
	110,
	null,
	155.56,
	null,
	110,
	null,
	116.54,
	null,
	116.54,
	null,
	155.56,
	null,
	146.83,
	null,
];

const TICK_MS = 120;
const LOOKAHEAD_S = 0.5;
const DEBOUNCE_MS = 200;
const FADE_S = 0.6;

// The loop tempo follows the dot's step time: a slower pace at a standstill,
// quickening with movement until the fastest step (home land) is reached.
const FASTEST_STEP_MS = RULES.own * RULES.tickMs;
const IDLE_SCALE = 1.5;
const FAST_SCALE = 0.8;

let tracks: Track[] | undefined;
let timer: ReturnType<typeof setInterval> | undefined;
let current: Mood = "calm";
let requested: Mood = "calm";
let requestedAt = 0;

function ensureTracks(): Track[] | undefined {
	if (tracks?.length) return tracks;
	const audioContext = audio();
	const master = masterChannel();
	if (!audioContext || !master) return undefined;
	const make = (
		mood: Mood,
		notes: (number | null)[],
		step: number,
		type: OscillatorType,
		volume: number,
		target: number,
	) => {
		const gain = audioContext.createGain();
		gain.gain.value = mood === current ? target : 0;
		gain.connect(master);
		return {
			mood,
			notes,
			baseStep: step,
			step,
			type,
			volume,
			target,
			gain,
			index: 0,
			nextAt: 0,
		};
	};
	tracks = [
		make("calm", CALM_NOTES, 0.32, "triangle", 0.35, 0.4),
		make("hostile", HOSTILE_NOTES, 0.25, "square", 0.28, 0.34),
	];
	return tracks;
}

/** Ramp every track to its target gain; the shared crossfade primitive. */
function rampTracks(seconds: number, target: (track: Track) => number) {
	const audioContext = audio();
	if (!audioContext || !tracks) return;
	const at = audioContext.currentTime;
	for (const track of tracks) {
		track.gain.gain.cancelScheduledValues(at);
		track.gain.gain.setValueAtTime(track.gain.gain.value, at);
		track.gain.gain.linearRampToValueAtTime(target(track), at + seconds);
	}
}

function fadeTo(next: Mood) {
	current = next;
	rampTracks(FADE_S, (track) => (track.mood === next ? track.target : 0));
}

/** Match the loop tempo to the dot's current step time; Infinity is idle. */
export function setMusicTempo(stepMs: number) {
	const speed = Number.isFinite(stepMs)
		? Math.min(1, FASTEST_STEP_MS / stepMs)
		: 0;
	const scale = IDLE_SCALE + (FAST_SCALE - IDLE_SCALE) * speed;
	for (const track of tracks ?? []) track.step = track.baseStep * scale;
}

function scheduleTrack(track: Track, now: number, horizon: number) {
	// A hidden tab or a blocked context pauses the clocks; resume just ahead
	// of now instead of replaying the missed steps.
	if (!track.nextAt || track.nextAt < now - 0.1) track.nextAt = now + 0.05;
	while (track.nextAt < horizon) {
		const note = track.notes[track.index++ % track.notes.length];
		if (note !== null)
			scheduleTone(track.gain, {
				frequency: note,
				at: track.nextAt,
				duration: track.step * 0.75,
				type: track.type,
				volume: track.volume,
			});
		track.nextAt += track.step;
	}
}

function tick() {
	if (document.hidden) return;
	const audioContext = audio();
	const list = ensureTracks();
	if (!audioContext || !list) return;
	const now = audioContext.currentTime;
	const horizon = now + LOOKAHEAD_S;
	for (const track of list) scheduleTrack(track, now, horizon);
	if (requested !== current && performance.now() - requestedAt >= DEBOUNCE_MS)
		fadeTo(requested);
}

/** Fade the loop in; safe to call on every game entry. */
export function startMusic() {
	if (timer) return;
	timer = setInterval(tick, TICK_MS);
	const list = ensureTracks();
	if (list) for (const track of list) track.nextAt = 0;
	setMusicTempo(Number.POSITIVE_INFINITY);
	rampTracks(0.5, (track) => (track.mood === current ? track.target : 0));
	tick();
}

/** Fade the loop out and stop scheduling; the tracks are reused next entry. */
export function stopMusic() {
	clearInterval(timer);
	timer = undefined;
	for (const track of tracks ?? []) track.nextAt = 0;
	rampTracks(0.4, () => 0);
	// The next entry starts calm; a stale mood must not bleed into it.
	current = "calm";
	requested = "calm";
}

/** Request a mood; the switch happens after it holds for the debounce. */
export function setMood(next: Mood) {
	if (next === requested) return;
	requested = next;
	requestedAt = performance.now();
}
