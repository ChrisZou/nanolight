"use strict";

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const { downloadExtension, parseRef } = require("./github");

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function commandEntry(pkg) {
  return (pkg.commands || []).map((cmd) => ({
    name: cmd.name,
    title: cmd.title || cmd.name,
    subtitle: cmd.subtitle || "",
    description: cmd.description || "",
    mode: cmd.mode || "view",
    icon: cmd.icon || pkg.icon || null,
  }));
}

function resolveCommandSource(srcDir, name) {
  const exts = [".tsx", ".ts", ".jsx", ".js"];
  for (const ext of exts) {
    const file = path.join(srcDir, name + ext);
    if (fs.existsSync(file)) return file;
  }
  return null;
}

// npm beside the node running this (an app started from the desktop may
// have a short PATH); on Windows it is npm.cmd, which only a shell runs.
function npmCommand() {
  const win = process.platform === "win32";
  const beside = path.join(path.dirname(process.execPath), win ? "npm.cmd" : "npm");
  return fs.existsSync(beside) ? beside : win ? "npm.cmd" : "npm";
}

function run(cmd, args, cwd, extraEnv) {
  if (cmd === "npm") cmd = npmCommand();
  const shell = process.platform === "win32" && /\.cmd$/i.test(cmd);
  return new Promise((resolve, reject) => {
    const child = spawn(shell ? '"' + cmd + '"' : cmd, args, {
      cwd,
      shell,
      env: Object.assign({}, process.env, { PATH: path.dirname(process.execPath) + path.delimiter + (process.env.PATH || process.env.Path || "") }, extraEnv || {}),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let stderr = "";
    child.stderr.on("data", (c) => {
      stderr += c.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(stderr);
      else reject(new Error(cmd + " " + args.join(" ") + " failed (" + code + "): " + stderr.slice(-1200)));
    });
  });
}

async function ensureEsbuild(cacheDir) {
  const bin = path.join(cacheDir, "node_modules", "esbuild", "package.json");
  if (fs.existsSync(bin)) return path.join(cacheDir, "node_modules", "esbuild");
  fs.mkdirSync(cacheDir, { recursive: true });
  if (!fs.existsSync(path.join(cacheDir, "package.json"))) {
    fs.writeFileSync(path.join(cacheDir, "package.json"), JSON.stringify({ private: true, name: "nl-esbuild-cache" }));
  }
  await run("npm", ["install", "--ignore-scripts=false", "esbuild@0.25.5", "--no-fund", "--no-audit"], cacheDir);
  return path.join(cacheDir, "node_modules", "esbuild");
}

// `swift:` and `rust:` imports are native code Raycast's own build compiles
// for the Mac: there is nothing to run here, so the install says so.
const nativeCode = {
  name: "raycast-native",
  setup(b) {
    b.onResolve({ filter: /^(swift|rust):/ }, (args) => ({
      errors: [{ text: "this extension calls native " + args.path.split(":")[0] + " code that only Raycast's own app can build, so Nanolight can't run it" }],
    }));
  },
};

function copyAssets(src, dest) {
  if (!fs.existsSync(src)) return;
  fs.cpSync(src, dest, { recursive: true });
}

async function installExtension(nameOrRef, extensionsDir) {
  const parsed = parseRef(nameOrRef);
  const name = parsed.name;
  const dest = path.join(path.resolve(extensionsDir), name);
  const tmp = path.join(path.resolve(extensionsDir), ".tmp-" + name + "-" + Date.now());
  fs.mkdirSync(path.resolve(extensionsDir), { recursive: true });
  try {
    await downloadExtension(name, tmp);
    const pkgPath = path.join(tmp, "package.json");
    if (!fs.existsSync(pkgPath)) throw new Error("Downloaded extension has no package.json");
    const pkg = readJson(pkgPath);
    const deps = Object.assign({}, pkg.dependencies || {});
    delete deps["@raycast/api"];
    const depList = Object.keys(deps);
    if (depList.length) {
      const installDir = path.join(tmp, ".install");
      fs.mkdirSync(installDir, { recursive: true });
      const slim = {
        name: pkg.name || name,
        version: "0.0.0",
        private: true,
        dependencies: deps,
      };
      fs.writeFileSync(path.join(installDir, "package.json"), JSON.stringify(slim, null, 2));
      await run("npm", ["install", "--omit=dev", "--ignore-scripts", "--no-fund", "--no-audit"], installDir);
      fs.cpSync(path.join(installDir, "node_modules"), path.join(tmp, "node_modules"), { recursive: true });
    }
    const cacheDir = path.join(path.resolve(extensionsDir), ".cache");
    const esbuildPath = await ensureEsbuild(cacheDir);
    const esbuild = require(esbuildPath);
    const srcDir = path.join(tmp, "src");
    // Built beside the download, put in place once every command built.
    const built = path.join(tmp, ".built");
    const outDir = path.join(built, "commands");
    fs.mkdirSync(outDir, { recursive: true });
    const commands = pkg.commands || [];
    if (!commands.length) throw new Error("Extension has no commands");
    for (const cmd of commands) {
      const entry = resolveCommandSource(srcDir, cmd.name);
      if (!entry) throw new Error("Missing source for command " + cmd.name + " (expected src/" + cmd.name + ".tsx)");
      await esbuild.build({
        absWorkingDir: tmp,
        entryPoints: [entry],
        bundle: true,
        platform: "node",
        format: "cjs",
        outfile: path.join(outDir, cmd.name + ".js"),
        external: ["@raycast/api", "react", "react/jsx-runtime", "react/jsx-dev-runtime"],
        jsx: "automatic",
        logLevel: "silent",
        mainFields: ["module", "main"],
        plugins: [nativeCode],
      });
    }
    fs.copyFileSync(pkgPath, path.join(built, "package.json"));
    copyAssets(path.join(tmp, "assets"), path.join(built, "assets"));
    fs.rmSync(dest, { recursive: true, force: true });
    fs.renameSync(built, dest);
    return {
      ok: true,
      name: pkg.name || name,
      title: pkg.title || name,
      commands: commandEntry(pkg),
    };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function listExtensions(extensionsDir) {
  const dir = path.resolve(extensionsDir);
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const name of fs.readdirSync(dir)) {
    if (name.startsWith(".")) continue;
    const pkgPath = path.join(dir, name, "package.json");
    if (!fs.existsSync(pkgPath)) continue;
    let pkg;
    try {
      pkg = readJson(pkgPath);
    } catch {
      continue;
    }
    out.push({
      name: pkg.name || name,
      title: pkg.title || name,
      icon: pkg.icon ? path.join(dir, name, "assets", pkg.icon) : null,
      commands: commandEntry(pkg),
    });
  }
  return out;
}

function removeExtension(name, extensionsDir) {
  const parsed = parseRef(name);
  const dest = path.join(path.resolve(extensionsDir), parsed.name);
  if (!fs.existsSync(dest)) {
    return { ok: false, error: "Not installed: " + parsed.name };
  }
  fs.rmSync(dest, { recursive: true, force: true });
  return { ok: true, name: parsed.name };
}

module.exports = { installExtension, listExtensions, removeExtension };
