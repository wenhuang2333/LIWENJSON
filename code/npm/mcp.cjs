#!/usr/bin/env node
"use strict";

// `liwenjson-mcp` — start the local MCP server from npm.
//
// The MCP implementation lives in the native binary (`liwenjson mcp`), not in
// this package: there is exactly one server, the same one the release assets
// and the pip package start. This launcher only finds that binary and hands it
// this process's stdin/stdout, so the JSON-RPC channel stays clean (no Node
// process in the middle, no banner on stdout).
//
// Resolution order, mirroring the Python client:
//   1. `LIWENJSON_BIN`
//   2. `liwenjson` on PATH
//   3. the development build inside this repository
//
// A binary that is not found is a startup error on stderr with the install
// command, never a half-working server.

const { spawn } = require("node:child_process");
const { existsSync } = require("node:fs");
const { dirname, join } = require("node:path");
const { fileURLToPath } = require("node:url");

function findBinary() {
  const env = process.env.LIWENJSON_BIN;
  if (env) return env;

  const pathParts = (process.env.PATH || "").split(require("node:path").delimiter);
  const names = process.platform === "win32" ? ["liwenjson.exe", "liwenjson"] : ["liwenjson"];
  for (const dir of pathParts) {
    if (!dir) continue;
    for (const name of names) {
      const candidate = join(dir, name);
      if (existsSync(candidate)) return candidate;
    }
  }

  // Development checkout: code/npm/mcp.cjs -> code/
  const codeDir = join(__dirname, "..");
  for (const name of ["liwenjson.exe", "liwenjson"]) {
    const candidate = join(
      codeDir,
      "_build",
      "native",
      "release",
      "build",
      "cmd",
      "liwenjson",
      name,
    );
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function main() {
  const binary = findBinary();
  if (!binary) {
    process.stderr.write(
      [
        "liwenjson-mcp: the LIWENJSON engine was not found.",
        "",
        "Install it in one of these ways:",
        "  - download a release binary and put `liwenjson` on PATH",
        "  - set LIWENJSON_BIN=/absolute/path/to/liwenjson",
        "  - build it: cd code && moon build cmd/liwenjson --target native --release",
        "",
      ].join("\n"),
    );
    process.exit(127);
  }

  const child = spawn(binary, ["mcp", ...process.argv.slice(2)], {
    stdio: "inherit",
    windowsHide: true,
  });
  const forwardInterrupt = () => child.kill("SIGINT");
  const forwardTerminate = () => child.kill("SIGTERM");
  const removeSignalHandlers = () => {
    process.removeListener("SIGINT", forwardInterrupt);
    process.removeListener("SIGTERM", forwardTerminate);
  };
  process.on("SIGINT", forwardInterrupt);
  process.on("SIGTERM", forwardTerminate);
  child.on("error", (err) => {
    removeSignalHandlers();
    process.stderr.write(`liwenjson-mcp: failed to start ${binary}: ${err.message}\n`);
    process.exit(127);
  });
  child.on("exit", (code, signal) => {
    // Wait for the server to exit, then preserve its termination status. Remove
    // our forwarding handlers first, or self-signalling would hit them again.
    removeSignalHandlers();
    if (signal) {
      process.kill(process.pid, signal);
      process.exit(128 + (require("node:os").constants.signals[signal] || 0));
    }
    process.exit(code === null ? 1 : code);
  });
}

main();
