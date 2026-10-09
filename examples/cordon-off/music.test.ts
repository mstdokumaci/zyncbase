import { expect, test } from "bun:test";

// sfx.ts (imported by music.ts) touches the DOM at module load; stub the bare
// minimum before the dynamic import so the module graph can evaluate.
(globalThis as { document?: unknown }).document = {
	querySelector: () => null,
	hidden: false,
};

test("music tempo maps movement step times to BPM anchors", async () => {
	const { musicBpm } = await import("./music");
	expect(musicBpm(50)).toBeCloseTo(126);
	expect(musicBpm(100)).toBeCloseTo(110);
	expect(musicBpm(200)).toBeCloseTo(98);
	expect(musicBpm(500)).toBeCloseTo(85);
	expect(musicBpm(Number.POSITIVE_INFINITY)).toBe(85);
	expect(musicBpm(150)).toBeCloseTo(104);
	expect(musicBpm(25)).toBe(126);
	expect(musicBpm(1000)).toBe(85);
});
