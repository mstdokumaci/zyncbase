import * as fs from "node:fs";
import * as path from "node:path";

const root = path.resolve(import.meta.dir, "../..");
const captureDir = path.join(root, "benchmark/corpus/raw");
const preload = path.join(root, "benchmark/capture/preload.ts");

fs.rmSync(captureDir, { recursive: true, force: true });
fs.mkdirSync(captureDir, { recursive: true });

const capture = Bun.spawn(
	[
		"bun",
		"test",
		"--preload",
		preload,
		"tests/e2e/src/e2e.test.ts",
		"-t",
		"combo stress",
	],
	{
		cwd: root,
		env: {
			...process.env,
			ZYNCBASE_COMBO_CAPTURE_DIR: captureDir,
			ZYNCBASE_COMBO_CAPTURE_PRELOAD: preload,
			// Corpus presence keys use this stride; replay hardcodes 2,500.
			ZYNCBASE_COMBO_CLIENTS_PER_PROCESS: "2500",
		},
		stdio: ["ignore", "inherit", "inherit"],
	},
);

const exitCode = await capture.exited;
if (exitCode !== 0) {
	throw new Error(`combo capture failed with exit code ${exitCode}`);
}

const build = Bun.spawn(["bun", "benchmark/capture/build-corpus.ts"], {
	cwd: root,
	stdio: ["ignore", "inherit", "inherit"],
});
if ((await build.exited) !== 0) {
	throw new Error("corpus build failed");
}
