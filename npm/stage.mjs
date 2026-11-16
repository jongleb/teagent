import { chmod, copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const [version, binaries, out] = process.argv.slice(2);

if (!version || !binaries || !out) {
  console.error("usage: node npm/stage.mjs VERSION BINARIES_DIR OUT_DIR");
  process.exit(2);
}

const platforms = [
  { name: "darwin-arm64", os: "darwin", cpu: "arm64" },
  { name: "darwin-x64", os: "darwin", cpu: "x64" },
  { name: "linux-x64", os: "linux", cpu: "x64", libc: "glibc" },
  { name: "linux-arm64", os: "linux", cpu: "arm64", libc: "glibc" },
];

const here = new URL(".", import.meta.url).pathname;
const main = JSON.parse(await readFile(join(here, "teagent/package.json"), "utf8"));

const stagePlatform = async ({ name, os, cpu, libc }) => {
  const folder = join(out, name);
  await mkdir(join(folder, "bin"), { recursive: true });
  const binary = join(folder, "bin/teagent");
  await copyFile(join(binaries, `teagent-${name}`), binary);
  await chmod(binary, 0o755);
  await copyFile(join(here, "..", "LICENSE"), join(folder, "LICENSE"));
  const manifest = {
    name: `@teagent/${name}`,
    version,
    description: `The teagent binary for ${name}.`,
    homepage: main.homepage,
    repository: main.repository,
    license: main.license,
    os: [os],
    cpu: [cpu],
    ...(libc ? { libc: [libc] } : {}),
    files: ["bin"],
  };
  await writeFile(join(folder, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return folder;
};

const stageMain = async () => {
  const folder = join(out, "teagent");
  await mkdir(join(folder, "bin"), { recursive: true });
  await copyFile(join(here, "teagent/bin/teagent.js"), join(folder, "bin/teagent.js"));
  await chmod(join(folder, "bin/teagent.js"), 0o755);
  await copyFile(join(here, "..", "LICENSE"), join(folder, "LICENSE"));
  await copyFile(join(here, "..", "README.md"), join(folder, "README.md"));
  const manifest = {
    ...main,
    version,
    optionalDependencies: Object.fromEntries(
      platforms.map(({ name }) => [`@teagent/${name}`, version]),
    ),
  };
  await writeFile(join(folder, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return folder;
};

const staged = [...(await Promise.all(platforms.map(stagePlatform))), await stageMain()];
console.log(staged.join("\n"));
