import { copyFile, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { renderMapPng } from "./history";
import { HEIGHT, terrain, WIDTH } from "./shared";

export async function buildBrowser(outdir = join(import.meta.dir, "dist")) {
	await mkdir(outdir, { recursive: true });
	const bundle = await Bun.build({
		entrypoints: [join(import.meta.dir, "client.ts")],
		outdir,
		target: "browser",
		minify: true,
	});
	if (!bundle.success)
		throw new AggregateError(bundle.logs, "Browser build failed");
	await Promise.all(
		["index.html", "style.css", "history.html", "favicon.svg"].map((name) =>
			copyFile(join(import.meta.dir, name), join(outdir, name)),
		),
	);
	await writeFile(
		join(outdir, "og.png"),
		renderMapPng(
			new Uint16Array(WIDTH * HEIGHT),
			terrain(),
			new Map<number, string>(),
			WIDTH,
			HEIGHT,
		),
	);
	await writeFile(
		join(outdir, "_headers"),
		"/*\n  X-Content-Type-Options: nosniff\n  Referrer-Policy: no-referrer\n  Cache-Control: public, max-age=0, must-revalidate\n",
	);
	return outdir;
}

if (import.meta.main) console.log(`Browser assets: ${await buildBrowser()}`);
