// Adaptive background loop: one four-bar Am-F piece arranged in layers, so
// calm and hostile share the same music and the mood switch is a layer mix,
// not a restart. Calm is the echo lead over a pad and half-note bass; hostile
// swaps the bass for a sub drone, tritone stabs and a heartbeat kick. The loop
// tempo tracks the dot's movement speed: slow at a standstill, quick on fast
// terrain.

import { audio, masterChannel, scheduleTone } from "./sfx";

export type Mood = "calm" | "hostile";

type Layer = {
	calm: number;
	hostile: number;
	gain: GainNode;
	run: (gain: GainNode, step: number, bar: number, at: number) => void;
};

// Lead: A4 C5 B4 E4, one note per half bar, each with three fading echoes.
// The grid is 16 steps per bar, so three steps is a dotted 8th.
const LEAD = [440, 523.25, 493.88, 329.63];
const ECHO_STEPS = 3;
const ECHO_DECAY = 0.35;

// Pad voicings, bass roots and the A3 + D#4 tritone for the Am Am F F loop.
const PAD_CHORDS = [
	[220, 261.63, 329.63, 440],
	[220, 261.63, 329.63, 440],
	[174.61, 220, 261.63, 349.23],
	[174.61, 220, 261.63, 349.23],
];
const BASS_ROOTS = [110, 110, 87.31, 87.31];
const STAB = [220, 311.13];
const SUB = 55;

const STEPS_PER_BAR = 16;
const BARS = PAD_CHORDS.length;
const TICK_MS = 120;
const LOOKAHEAD_S = 0.5;
const DEBOUNCE_MS = 200;
const FADE_S = 0.6;
const IDLE_BPM = 85;

// Movement step time (ms) -> loop BPM anchors. 110 BPM sits on neutral ground,
// own land quickens toward 126, slower terrain settles toward the idle pace.
// Linear between anchors and clamped outside them; Infinity is idle.
const TEMPO_ANCHORS: [number, number][] = [
	[50, 126],
	[100, 110],
	[200, 98],
	[300, 92],
	[500, 85],
];

let layers: Layer[] | undefined;
let timer: ReturnType<typeof setInterval> | undefined;
let step = 0;
let nextAt = 0;
let stepSeconds = 60 / 110 / 4;
let current: Mood = "calm";
let requested: Mood = "calm";
let requestedAt = 0;

/** Loop BPM for a movement step time; exported for the tempo-mapping test. */
export function musicBpm(stepMs: number) {
	if (!Number.isFinite(stepMs)) return IDLE_BPM;
	if (stepMs <= TEMPO_ANCHORS[0][0]) return TEMPO_ANCHORS[0][1];
	for (let i = 1; i < TEMPO_ANCHORS.length; i++) {
		const [ms, bpm] = TEMPO_ANCHORS[i];
		if (stepMs > ms) continue;
		const [previousMs, previousBpm] = TEMPO_ANCHORS[i - 1];
		return (
			previousBpm +
			((bpm - previousBpm) * (stepMs - previousMs)) / (ms - previousMs)
		);
	}
	return IDLE_BPM;
}

function barSeconds() {
	return stepSeconds * STEPS_PER_BAR;
}

function ensureLayers(): Layer[] | undefined {
	if (layers?.length) return layers;
	const audioContext = audio();
	const master = masterChannel();
	if (!audioContext || !master) return undefined;
	const make = (calm: number, hostile: number, run: Layer["run"]): Layer => {
		const gain = audioContext.createGain();
		gain.gain.value = current === "hostile" ? hostile : calm;
		gain.connect(master);
		return { calm, hostile, gain, run };
	};
	layers = [
		// Echo lead: one note per half bar, echoed as fading dotted 8ths.
		make(0.45, 0.35, (gain, s, _bar, at) => {
			if (s % 4) return;
			const frequency = LEAD[s / 4];
			for (let echo = 0; echo < 3; echo++)
				scheduleTone(gain, {
					frequency,
					at: at + echo * ECHO_STEPS * stepSeconds,
					duration: stepSeconds * 1.2,
					type: "triangle",
					volume: 0.22 * ECHO_DECAY ** echo,
				});
		}),
		// Chord pad, one voicing per bar.
		make(0.3, 0.2, (gain, s, bar, at) => {
			if (s !== 0) return;
			for (const frequency of PAD_CHORDS[bar])
				scheduleTone(gain, {
					frequency,
					at,
					duration: barSeconds() * 0.98,
					type: "triangle",
					volume: 0.05,
					attack: 0.5,
				});
		}),
		// Bass half-notes, calm only: hostile hands the low end to the sub.
		make(0.15, 0, (gain, s, bar, at) => {
			if (s !== 0 && s !== 8) return;
			scheduleTone(gain, {
				frequency: BASS_ROOTS[bar],
				at,
				duration: stepSeconds * 5,
				type: "sine",
				volume: 0.35,
			});
		}),
		// Hostile: a sub drone under the bar, an octave below the bass.
		make(0, 1, (gain, s, _bar, at) => {
			if (s !== 0) return;
			scheduleTone(gain, {
				frequency: SUB,
				at,
				duration: barSeconds() * 0.95,
				type: "sine",
				volume: 0.3,
				attack: 0.3,
			});
		}),
		// Hostile: a tritone stab with one echo, twice per bar.
		make(0, 1, (gain, s, _bar, at) => {
			if (s !== 6 && s !== 14) return;
			for (const frequency of STAB)
				for (let echo = 0; echo < 2; echo++)
					scheduleTone(gain, {
						frequency,
						at: at + echo * ECHO_STEPS * stepSeconds,
						duration: stepSeconds * 1.2,
						type: "sawtooth",
						volume: 0.1 * 0.4 ** echo,
					});
		}),
		// Hostile: a heartbeat kick on beats 1 and 3.
		make(0, 1, (gain, s, _bar, at) => {
			if (s !== 0 && s !== 8) return;
			scheduleTone(gain, {
				frequency: 150,
				endFrequency: 40,
				at,
				duration: 0.16,
				type: "sine",
				volume: 0.5,
			});
		}),
	];
	return layers;
}

/** Ramp every layer to its target gain; the shared crossfade primitive. */
function rampLayers(seconds: number, target: (layer: Layer) => number) {
	const audioContext = audio();
	if (!audioContext || !layers) return;
	const at = audioContext.currentTime;
	for (const layer of layers) {
		layer.gain.gain.cancelScheduledValues(at);
		layer.gain.gain.setValueAtTime(layer.gain.gain.value, at);
		layer.gain.gain.linearRampToValueAtTime(target(layer), at + seconds);
	}
}

function fadeTo(next: Mood) {
	current = next;
	rampLayers(FADE_S, (layer) =>
		next === "hostile" ? layer.hostile : layer.calm,
	);
}

/** Match the loop tempo to the dot's current step time; Infinity is idle. */
export function setMusicTempo(stepMs: number) {
	stepSeconds = 60 / musicBpm(stepMs) / 4;
}

function tick() {
	if (document.hidden) return;
	const audioContext = audio();
	const list = ensureLayers();
	if (!audioContext || !list) return;
	const now = audioContext.currentTime;
	// A hidden tab or a blocked context pauses the clock; resume just ahead of
	// now instead of replaying the missed steps.
	if (!nextAt || nextAt < now - 0.1) nextAt = now + 0.05;
	const horizon = now + LOOKAHEAD_S;
	while (nextAt < horizon) {
		const stepInBar = step % STEPS_PER_BAR;
		const bar = Math.floor(step / STEPS_PER_BAR) % BARS;
		for (const layer of list) layer.run(layer.gain, stepInBar, bar, nextAt);
		step++;
		nextAt += stepSeconds;
	}
	if (requested !== current && performance.now() - requestedAt >= DEBOUNCE_MS)
		fadeTo(requested);
}

/** Fade the loop in; safe to call on every game entry. */
export function startMusic() {
	if (timer) return;
	timer = setInterval(tick, TICK_MS);
	if (ensureLayers()) {
		step = 0;
		nextAt = 0;
	}
	setMusicTempo(Number.POSITIVE_INFINITY);
	rampLayers(0.5, (layer) =>
		current === "hostile" ? layer.hostile : layer.calm,
	);
	tick();
}

/** Fade the loop out and stop scheduling; the layers are reused next entry. */
export function stopMusic() {
	clearInterval(timer);
	timer = undefined;
	step = 0;
	nextAt = 0;
	rampLayers(0.4, () => 0);
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
