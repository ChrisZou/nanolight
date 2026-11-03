import * as esbuild from "esbuild";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));

await esbuild.build({
  absWorkingDir: root,
  entryPoints: ["src/cli.js"],
  bundle: true,
  platform: "node",
  format: "cjs",
  outfile: "dist/host.js",
  target: "node20",
  external: ["esbuild"],
  // Small: React's production build, minified; its licence notices kept.
  minify: true,
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "eof",
  logLevel: "info",
  banner: {
    js: "#!/usr/bin/env node",
  },
});
