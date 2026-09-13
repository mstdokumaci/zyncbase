import { createHash } from "node:crypto";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { join, relative } from "node:path";

export type DeployResult = "deployed" | "unchanged" | "skipped" | "failed";
export type DeployRunner = (
	command: string[],
	cwd: string,
	log: (message: string) => void,
) => Promise<number>;

const HASH_FILE = "deploy-hash";
const DEPLOY_TIMEOUT_MS = 120_000;

/** sha256 over sorted relative paths and contents of every asset file. */
export async function computeAssetsHash(assetsDir: string): Promise<string> {
	const files: string[] = [];
	const walk = async (dir: string) => {
		for (const entry of await readdir(dir, { withFileTypes: true })) {
			const path = join(dir, entry.name);
			if (entry.isDirectory()) await walk(path);
			else if (entry.isFile()) files.push(path);
		}
	};
	await walk(assetsDir);
	files.sort();
	const hash = createHash("sha256");
	for (const file of files) {
		hash.update(relative(assetsDir, file));
		hash.update(await readFile(file));
	}
	return hash.digest("hex");
}

/**
 * Deploys the asset directory only when its content hash changed since the
 * last successful deploy. Failures never throw; the caller may retry.
 */
export async function deployIfChanged(options: {
	assetsDir: string;
	stateDir: string;
	command: string[];
	cwd: string;
	run?: DeployRunner;
	log?: (message: string) => void;
}): Promise<DeployResult> {
	const {
		assetsDir,
		stateDir,
		command,
		cwd,
		run = runCommand,
		log = () => {},
	} = options;
	const hash = await computeAssetsHash(assetsDir);
	const stateFile = join(stateDir, HASH_FILE);
	const previous = await readFile(stateFile, "utf8").catch(() => "");
	if (previous.trim() === hash) return "unchanged";
	if (!(await exists(join(assetsDir, "index.html")))) {
		log("Deploy skipped: assets directory has no index.html");
		return "skipped";
	}
	const code = await run(command, cwd, log);
	if (code !== 0) {
		log(`Deploy failed with exit code ${code}`);
		return "failed";
	}
	await mkdir(stateDir, { recursive: true });
	await writeFile(stateFile, hash);
	return "deployed";
}

async function runCommand(
	command: string[],
	cwd: string,
	log: (message: string) => void,
): Promise<number> {
	log(`Deploying assets: ${command.join(" ")}`);
	const child = Bun.spawn(command, {
		cwd,
		stdout: "inherit",
		stderr: "inherit",
	});
	const timer = setTimeout(() => child.kill(), DEPLOY_TIMEOUT_MS);
	try {
		return await child.exited;
	} finally {
		clearTimeout(timer);
	}
}

async function exists(path: string) {
	try {
		await stat(path);
		return true;
	} catch {
		return false;
	}
}
