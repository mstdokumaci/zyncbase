// Synthesized audio: one lazily created context unlocked by the first user
// gesture, a master gain with a persisted mute, and small oscillator recipes.
// No assets and no dependencies: the whole soundtrack is waveform envelopes.
// Shared by effects (sfx) and the adaptive loop (music).

const MUTE_KEY = "cordon-off:muted";

let context: AudioContext | undefined;
let master: GainNode | undefined;
let muted = readMuted();

function readMuted() {
	try {
		return localStorage.getItem(MUTE_KEY) === "1";
	} catch {
		return false;
	}
}

function setMasterGain() {
	if (!context || !master) return;
	const at = context.currentTime;
	master.gain.cancelScheduledValues(at);
	master.gain.setValueAtTime(master.gain.value, at);
	master.gain.linearRampToValueAtTime(muted ? 0 : 1, at + 0.05);
}

function ensureAudio() {
	if (context && master) return context;
	const next = new AudioContext();
	const gain = next.createGain();
	gain.gain.value = muted ? 0 : 1;
	gain.connect(next.destination);
	context = next;
	master = gain;
	return next;
}

/** Create/resume the context from a user gesture; safe to call repeatedly. */
function unlockAudio() {
	try {
		const audio = ensureAudio();
		if (audio.state === "suspended") void audio.resume();
	} catch {
		// Audio is optional; a blocked context just means a silent game.
	}
}

for (const event of ["pointerdown", "keydown"] as const)
	addEventListener(event, unlockAudio, { capture: true });

function toggleMute() {
	muted = !muted;
	try {
		localStorage.setItem(MUTE_KEY, muted ? "1" : "0");
	} catch {
		// Persisting the choice is best-effort.
	}
	setMasterGain();
	renderMute();
}

// The mute key ignores keystrokes meant for the name and country inputs.
addEventListener("keydown", (event) => {
	if (
		event.code !== "KeyM" ||
		event.repeat ||
		event.ctrlKey ||
		event.metaKey ||
		event.altKey
	)
		return;
	const target = event.target as HTMLElement | null;
	if (
		target?.isContentEditable ||
		["INPUT", "SELECT", "TEXTAREA"].includes(target?.tagName ?? "")
	)
		return;
	toggleMute();
});

// The on-screen toggle mirrors the key: one state owner, two inputs.
const muteButton = document.querySelector<HTMLButtonElement>("#mute-toggle");

function renderMute() {
	if (!muteButton) return;
	muteButton.textContent = muted ? "UNMUTE" : "MUTE";
	muteButton.setAttribute("aria-pressed", String(muted));
}

muteButton?.addEventListener("click", toggleMute);
renderMute();

/** Running context, or undefined while locked/blocked/hidden. */
export function audio(): AudioContext | undefined {
	return context && context.state === "running" ? context : undefined;
}

/** Master gain both effects and music connect through. */
export function masterChannel(): GainNode | undefined {
	return master;
}

type Tone = {
	frequency: number;
	at: number;
	duration: number;
	endFrequency?: number;
	type?: OscillatorType;
	volume?: number;
};

/** Schedule one enveloped oscillator; a no-op when audio is unavailable. */
export function scheduleTone(target: GainNode, tone: Tone) {
	const audioContext = audio();
	if (!audioContext || document.hidden) return;
	const at = Math.max(tone.at, audioContext.currentTime);
	const duration = Math.max(0.02, tone.duration);
	const oscillator = audioContext.createOscillator();
	const gain = audioContext.createGain();
	oscillator.type = tone.type ?? "square";
	oscillator.frequency.setValueAtTime(tone.frequency, at);
	if (tone.endFrequency && tone.endFrequency !== tone.frequency)
		oscillator.frequency.exponentialRampToValueAtTime(
			Math.max(1, tone.endFrequency),
			at + duration,
		);
	gain.gain.setValueAtTime(0, at);
	gain.gain.linearRampToValueAtTime(tone.volume ?? 0.4, at + 0.008);
	gain.gain.exponentialRampToValueAtTime(0.0001, at + duration);
	oscillator.connect(gain);
	gain.connect(target);
	oscillator.start(at);
	oscillator.stop(at + duration + 0.02);
	oscillator.onended = () => {
		oscillator.disconnect();
		gain.disconnect();
	};
}

// Effects are short blips. A leading-edge refractory window merges bursts:
// the first event plays at once, repeats within the window drop instead of
// stacking into a trill.
const CUE_GAP_MS = 400;
const lastCue = new Map<string, number>();

type Blip = {
	frequency: number;
	endFrequency?: number;
	delay?: number;
	duration: number;
	type: OscillatorType;
	volume: number;
};

function cue(name: string, blips: Blip[]) {
	const now = performance.now();
	if (now - (lastCue.get(name) ?? Number.NEGATIVE_INFINITY) < CUE_GAP_MS)
		return;
	lastCue.set(name, now);
	const audioContext = audio();
	const master = masterChannel();
	if (!audioContext || !master) return;
	for (const blip of blips) {
		scheduleTone(master, {
			frequency: blip.frequency,
			endFrequency: blip.endFrequency,
			at: audioContext.currentTime + (blip.delay ?? 0),
			duration: blip.duration,
			type: blip.type,
			volume: blip.volume,
		});
	}
}

export const sfx = {
	/** Join jingle on deploy. */
	deploy() {
		const audioContext = audio();
		const master = masterChannel();
		if (!audioContext || !master) return;
		const start = audioContext.currentTime;
		[392, 523.25, 659.25].forEach((frequency, index) => {
			scheduleTone(master, {
				frequency,
				at: start + index * 0.09,
				duration: 0.14,
				volume: 0.32,
			});
		});
	},
	/** Our own paint closed an enclosure: a warm rising fifth. Rarer than a
	 * loss, so it gets the slightly longer, softer two-note chime. */
	capture() {
		cue("capture", [
			{ frequency: 523.25, duration: 0.09, type: "triangle", volume: 0.22 },
			{
				frequency: 783.99,
				delay: 0.08,
				duration: 0.14,
				type: "triangle",
				volume: 0.22,
			},
		]);
	},
	/** An enemy enclosure took our land: low falling blip. */
	lost() {
		cue("lost", [
			{
				frequency: 330,
				endFrequency: 220,
				duration: 0.1,
				type: "sawtooth",
				volume: 0.28,
			},
		]);
	},
};
