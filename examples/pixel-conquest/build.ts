import { copyFile, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

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
		["index.html", "style.css"].map((name) =>
			copyFile(join(import.meta.dir, name), join(outdir, name)),
		),
	);
	await writeFile(
		join(outdir, "_headers"),
		"/*\n  X-Content-Type-Options: nosniff\n  Referrer-Policy: no-referrer\n  Cache-Control: public, max-age=0, must-revalidate\n",
	);
	return outdir;
}

if (import.meta.main) console.log(`Browser assets: ${await buildBrowser()}`);
