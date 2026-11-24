import { copyFile, mkdir } from "node:fs/promises";
import { join } from "node:path";

export async function buildBrowser(
	outdir = join(import.meta.dir, "dist"),
): Promise<string> {
	await mkdir(outdir, { recursive: true });
	const bundle = await Bun.build({
		entrypoints: [join(import.meta.dir, "client.tsx")],
		outdir,
		target: "browser",
		minify: true,
		define: { "process.env.NODE_ENV": '"production"' },
	});
	if (!bundle.success) {
		throw new AggregateError(bundle.logs, "Browser build failed");
	}
	await Promise.all(
		["index.html", "style.css", "favicon.svg"].map((name) =>
			copyFile(join(import.meta.dir, name), join(outdir, name)),
		),
	);
	return outdir;
}

if (import.meta.main) {
	console.log(`Browser assets: ${await buildBrowser()}`);
}
