// Node tests for the npm package. Run with `node --test test/`.
//
// The engine is the same MoonBit bundle the browser demo uses; these tests are
// about the wrapper contract (module shape, profile handling, error mapping),
// not about the repair rules, which have their own suite.

import test from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  LIWENJSONError,
  repair,
  repairResult,
  analyze,
  gate,
  report,
  snapshot,
  snapshotText,
  live,
  readiness,
  deltas,
  version,
} from "../index.mjs";

const here = dirname(fileURLToPath(import.meta.url));

test("repair fixes quotes and a trailing comma", () => {
  assert.equal(repair("{'a':1,}"), '{"a":1}');
  assert.equal(repair('{"a":[1,2]}'), '{"a":[1,2]}');
});

test("a profile can refuse a repair instead of guessing", () => {
  assert.throws(
    () => repair('{"path":"/tmp/x"', { profile: "agent" }),
    /E010/,
  );
  assert.equal(repair("{'a':1,}", { profile: "execution" }), '{"a":1}');
});

test("repairResult carries the decision fields", () => {
  const r = repairResult("{'a':1,}", { profile: "execution" });
  assert.equal(r.text, '{"a":1}');
  assert.equal(r.exactness, "cosmetic");
  assert.equal(r.executable, true);
  assert.equal(r.decision, "cosmetic_repair");
});

test("analyze blocks an ambiguous repair", () => {
  const plan = analyze('{"words":["a" "b"]}', { profile: "execution" });
  assert.equal(plan.decision, "ambiguous");
  assert.equal(plan.executable, false);
  assert.equal(plan.execution, "blocked");
  assert.equal(plan.error.code, "E011");
  assert.match(plan.retry.prompt, /Re-emit/);
});

test("analyze accepts a JSON Schema tool declaration", () => {
  const plan = analyze('{"query":"x","limit":0}', {
    profile: "agent",
    schemaJson: {
      type: "object",
      properties: {
        query: { type: "string" },
        limit: { type: "integer", minimum: 1 },
      },
      required: ["query", "limit"],
    },
  });
  assert.equal(plan.executable, false);
  assert.equal(plan.schema_total, 2);
  assert.equal(plan.schema_satisfied, 1);
});

test("an unsupported JSON Schema keyword is reported, not ignored", () => {
  assert.throws(
    () =>
      analyze("{}", {
        schemaJson: { $ref: "#/definitions/x" },
      }),
    /E070.*\$ref/,
  );
});

test("the gate defaults to the profile the MCP tools use", () => {
  // `analyze` with no profile used to run the permissive profile while the
  // MCP gate ran `agent`, so the same input got two answers depending on
  // which surface asked. `gate` is the MCP call.
  const refused = gate('{"a":1,"a":2}');
  assert.equal(refused.executable, false);
  assert.equal(refused.decision, "lossy_repair");
  assert.ok(refused.retry && refused.retry.prompt, "a refusal carries a prompt");
  assert.equal(refused.value, null, "a refusal carries no value");
  // ...and the permissive profile is one explicit argument away.
  assert.equal(analyze('{"a":1,"a":2}', { profile: "permissive" }).decision, "lossy_repair");
});

test("a refusal always carries a prompt and never a value", () => {
  const plan = gate('{"a":1}', { schemaJson: { type: "object", properties: { a: { type: "string" } }, required: ["a"] } });
  assert.equal(plan.executable, false);
  assert.equal(plan.value, null);
  assert.ok(plan.retry.prompt.length > 0);
  assert.equal(plan.retry.code, "E070");
});

test("errors carry their code as a field", () => {
  assert.throws(
    () => repair('{"a":1,}', { profile: "strict" }),
    (e) => e instanceof LIWENJSONError && e.code === "E010" && e instanceof Error,
  );
});

test("the whole engine surface is exported", () => {
  // `validate`, `readiness` and `deltas` were reachable from the browser demo
  // but not from the package, so a Node caller had to reimplement them.
  assert.equal(typeof readiness, "function");
  assert.equal(typeof deltas, "function");
  assert.equal(typeof snapshotText, "function");
  const curve = readiness('{"a":1}', "{!a:integer}");
  assert.ok(typeof curve.syntax_permille === "number");
  const stream = deltas('{"a":1}', 7);
  assert.ok(Array.isArray(stream.deltas) || typeof stream === "object");
});

test("report, snapshot and live keep their documented shapes", () => {
  assert.equal(report('{"a":1}'), "-");
  assert.match(report("{'a':1,}"), /^R003 1:2 /);
  assert.match(snapshotText('{"name":"Mo', 11), /Partial \| name$/);
  const snap = snapshot('{"name":"Mo', 11);
  assert.equal(snap.completeness, "Partial");
  assert.equal(snap.openPath, "name");
  const frame = live('{"query":"MoonBit","limit":10}', 12, "{!query:string}");
  assert.equal(frame.consumed, 12);
  assert.equal(frame.completeness, "Partial");
});

test("the CommonJS entry point works", () => {
  const require = createRequire(import.meta.url);
  const cjs = require("../index.cjs");
  assert.equal(cjs.repair("{'a':1,}"), '{"a":1}');
  assert.equal(typeof cjs.analyze, "function");
});

test("importing the package writes nothing to stdout", () => {
  const entry = resolve(here, "..", "index.cjs");
  const r = spawnSync(process.execPath, ["-e", `require(${JSON.stringify(entry)})`], {
    encoding: "utf8",
  });
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "");
  assert.equal(r.stderr, "");
});

test("the MCP launcher exposes the local server without touching stdout", () => {
  // The launcher is the npm install path for the MCP server. It must resolve a
  // binary (the development build here), pass the arguments through, and keep
  // the JSON-RPC channel clean. `--print-config` exits without reading stdin,
  // which is exactly the case a wrapper that printed a banner would break.
  const binary = resolve(
    here,
    "..",
    "..",
    "_build",
    "native",
    "release",
    "build",
    "cmd",
    "liwenjson",
    process.platform === "win32" ? "liwenjson.exe" : "liwenjson.exe",
  );
  const r = spawnSync(process.execPath, [resolve(here, "..", "mcp.cjs"), "--print-config=claude"], {
    encoding: "utf8",
    env: { ...process.env, LIWENJSON_BIN: binary },
  });
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), "claude mcp add liwenjson -- liwenjson mcp");
  assert.equal(r.stderr, "");
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  test(`the MCP launcher forwards ${signal} after a real handshake and reaps the server`, {
    skip: process.platform === "win32" ? "POSIX signal lifecycle" : false,
    timeout: 10000,
  }, async (t) => {
    const binary = resolve(here, "..", "..", "_build", "native", "release", "build", "cmd", "liwenjson", "liwenjson.exe");
    const launcher = spawn(process.execPath, [resolve(here, "..", "mcp.cjs")], {
      env: { ...process.env, LIWENJSON_BIN: binary },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let serverPid;
    let stderr = "";
    launcher.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
    const lines = createInterface({ input: launcher.stdout });
    t.after(() => {
      lines.close();
      // Even a broken handshake must not leave the server running after this
      // test times out; discover owned children before stopping the launcher.
      const processes = spawnSync("ps", ["-ax", "-o", "pid=,ppid="], { encoding: "utf8" });
      const owned = (processes.stdout || "").trim().split("\n")
        .map((row) => row.trim().split(/\s+/).map(Number))
        .filter(([, parent]) => parent === launcher.pid).map(([pid]) => pid);
      for (const pid of new Set([...owned, ...(serverPid ? [serverPid] : [])])) {
        try { process.kill(pid, "SIGKILL"); } catch {}
      }
      if (launcher.exitCode === null && launcher.signalCode === null) launcher.kill("SIGKILL");
      launcher.stdin.destroy();
      launcher.stdout.destroy();
      launcher.stderr.destroy();
    });
    const closed = once(launcher, "close", { signal: t.signal });
    closed.catch(() => {}); // The handshake may time out before close is awaited.
    const response = once(lines, "line", { signal: t.signal });
    launcher.stdin.write(`${JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "npm-lifecycle-test", version: "1" } },
    })}\n`);
    const [line] = await response;
    const handshake = JSON.parse(line);
    assert.equal(handshake.id, 1);
    assert.ok(handshake.result.serverInfo);
    launcher.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');

    const processes = spawnSync("ps", ["-ax", "-o", "pid=,ppid="], { encoding: "utf8" });
    assert.equal(processes.status, 0);
    const servers = processes.stdout.trim().split("\n")
      .map((row) => row.trim().split(/\s+/).map(Number))
      .filter(([, parent]) => parent === launcher.pid);
    assert.equal(servers.length, 1, "the launcher owns one native MCP server");
    serverPid = servers[0][0];
    // Keep stdin open and signal only the launcher, never the process group.
    assert.equal(launcher.kill(signal), true);
    const [code, exitSignal] = await closed;
    assert.ok(exitSignal === signal || code === (signal === "SIGINT" ? 130 : 143));
    assert.throws(() => process.kill(serverPid, 0), { code: "ESRCH" }, "the native server must not outlive its launcher");
    serverPid = undefined;
    assert.equal(stderr, "");
  });
}

test("the package reports the engine version", () => {
  // Read from `code/moon.mod` rather than pinning a literal: the version is
  // hardcoded in the MoonBit sources, so a pinned literal goes red on every
  // release. The test still fails when the bundle disagrees with the
  // declaration -- which is the part worth checking.
  const mod = readFileSync(resolve(here, "..", "..", "moon.mod"), "utf8");
  const declared = mod.match(/^version\s*=\s*"([^"]+)"/m)[1];
  assert.equal(version, declared);
  // The wrapper reports the package version; the package version must be the
  // engine version. Both are asserted against `moon.mod`, so a bump that
  // misses either file is caught here instead of by a reader.
  const pkg = JSON.parse(readFileSync(resolve(here, "..", "package.json"), "utf8"));
  assert.equal(pkg.version, declared);
});

test("const and enum are conjunctive, whatever the field order", () => {
  // The audit's headline reproducer: the same declaration with `const` and
  // `enum` in either order must reach the same verdict.
  const orders = [
    {
      type: "object",
      properties: {
        mode: { type: "string", const: "read", enum: ["read", "write"] },
      },
      required: ["mode"],
    },
    {
      type: "object",
      properties: {
        mode: { type: "string", enum: ["read", "write"], const: "read" },
      },
      required: ["mode"],
    },
  ];
  for (const schemaJson of orders) {
    assert.equal(gate('{"mode":"write"}', { schemaJson }).executable, false);
    assert.equal(gate('{"mode":"read"}', { schemaJson }).executable, true);
  }
});

test("a container's constraint does not skip the shape inside it", () => {
  const schemaJson = {
    type: "object",
    properties: {
      items: {
        type: "array",
        enum: [[1], ["bad"]],
        items: { type: "integer" },
      },
    },
    required: ["items"],
  };
  assert.equal(gate('{"items":["bad"]}', { schemaJson }).executable, false);
  assert.equal(gate('{"items":[1]}', { schemaJson }).executable, true);
});

test("repair honours a declaration instead of ignoring it", () => {
  // `repair` read only `profile`, so `repair(text, {schemaJson})` returned a
  // document the Python client and the MCP tool both refuse (audit 4.2).
  assert.throws(
    () =>
      repair('{"a":1}', {
        schemaJson: {
          type: "object",
          properties: { a: { type: "string" } },
          required: ["a"],
        },
      }),
    (e) => e instanceof LIWENJSONError && e.code === "E070",
  );
  assert.equal(
    repair('{"a":"x"}', {
      schemaJson: {
        type: "object",
        properties: { a: { type: "string" } },
        required: ["a"],
      },
    }),
    '{"a":"x"}',
  );
});

for (const number of [
  "9007199254740993", "-9007199254740993",
  "0.10000000000000001", "1.0000000000000001",
  "1e400", "-1e400", "1e-400", "-1e-400",
]) {
  test(`host number conversion never yields an executable changed value (${number})`, () => {
    for (const input of [number, `{"amount":[${number}]}`]) {
      for (const decide of [analyze, gate]) {
        for (const options of [{}, { profile: "permissive", schemaJson: {} }]) {
          const plan = decide(input, options);
          assert.equal(plan.executable, false, input);
          assert.equal(plan.execution, "blocked");
          assert.equal(plan.decision, "invalid");
          assert.doesNotMatch(plan.label, /PASSED|SAFE/);
          assert.equal(plan.value, null);
          assert.equal(plan.text, input, "the engine text remains exact");
          assert.equal(plan.error.code, "E070");
          assert.equal(plan.refusal.kind, "host_declaration");
          assert.equal(plan.refusal.auto_retry, false);
          assert.match(plan.retry.prompt, /Do not automatically retry/);
          assert.equal(plan.business_authorized, false);
        }
      }
    }
    assert.equal(repair(number, { profile: "agent" }), number);
    assert.equal(repair(number, { profile: "agent", schema: "number" }), number);
    assert.equal(repair(number, { schemaJson: `{"const":${number}}` }), number);
    assert.equal(repair(`{'amount':${number},}`, {
      schemaJson: { type: "object", properties: { amount: { type: "number" } }, required: ["amount"] },
    }), `{"amount":${number}}`);
    assert.equal(repairResult(number).executable, false);
    const refused = analyze(`{"amount":${number},"words":["a" "b"]}`, { profile: "permissive" });
    assert.equal(refused.executable, false);
    assert.equal(refused.value, null);
    assert.equal(refused.error.code, "E070");
    assert.equal(refused.refusal.auto_retry, false);
  });
}

test("host equality accepts ordinary numbers and equivalent decimal spellings", () => {
  for (const number of ["1", "0.1", "1.0", "1e0", "1e+0", "0.10", "10e-2", "100e-3", "-0", "0e400", "9007199254740992", "1e300", "1e-300", "5e-324"]) {
    for (const decide of [analyze, gate]) {
      const plan = decide(`{"amount":[${number}]}`);
      assert.equal(plan.executable, true, number);
      assert.deepEqual(plan.value, { amount: [JSON.parse(number)] });
      assert.equal(plan.refusal, null);
    }
  }
  for (const number of ["1.0", "1e0", "10e-2", "100e-3"]) {
    const plan = gate(number, { schemaJson: { const: JSON.parse(number) } });
    assert.equal(plan.executable, true, number);
  }
});

test("agent web options skip prose without changing execution or strict defaults", () => {
  const input = 'Here are the arguments: {"a":1}';
  const accepted = gate(input);
  assert.equal(accepted.executable, true);
  assert.deepEqual(accepted.value, { a: 1 });
  assert.equal(gate(input, { schemaJson: { const: { a: 1 } } }).executable, true);
  assert.equal(repair(input, { profile: "agent" }), '{"a":1}');
  assert.equal(gate(input, { profile: "execution" }).executable, false);
  assert.equal(gate(input, { profile: "strict" }).executable, false);
});

test("a refusal says whether an automatic retry is safe", () => {
  // A truncated document is a syntax problem: re-emitting the same answer is
  // what a retry loop should do.
  const syntax = gate('{"a":', { profile: "agent" });
  assert.equal(syntax.executable, false);
  assert.equal(syntax.refusal.kind, "syntax");
  assert.equal(syntax.refusal.auto_retry, true);
  // A complete document that conflicts with the declaration is not: a retry
  // may come back with a *different action*, which is how a `write` became a
  // `read` and was executed (audit §7.2).
  const intent = gate('{"mode":"write"}', {
    schemaJson: {
      type: "object",
      properties: { mode: { type: "string", const: "read" } },
      required: ["mode"],
    },
  });
  assert.equal(intent.executable, false);
  assert.equal(intent.refusal.kind, "schema_or_intent");
  assert.equal(intent.refusal.auto_retry, false);
  // And every plan says the gate is not an authorization.
  assert.equal(intent.business_authorized, false);
  assert.equal(gate('{"a":1}').business_authorized, false);
});

test("snapshot splits on the value, not on every separator in it", () => {
  // A value, a lone key and a root string may all contain ` | `; splitting the
  // whole rendering on it used to hand a truncated slice to JSON.parse and
  // throw `SyntaxError: Unterminated string in JSON` (R-06).
  const value = snapshot('{"x":"a | b"}', 30);
  assert.deepEqual(value.value, { x: "a | b" });
  assert.equal(value.completeness, "Complete");
  assert.equal(value.openPath, "");

  const key = snapshot('{"a | b":"x"}', 30);
  assert.deepEqual(key.value, { "a | b": "x" });
  assert.equal(key.completeness, "Complete");

  const root = snapshot('"a | b | c"', 30);
  assert.equal(root.value, "a | b | c");
  assert.equal(root.completeness, "Complete");

  // Separators inside a value must not be mistaken for the completeness field,
  // and a value that *is* another field's rendering must stay intact.
  const poisoned = snapshot('{"k":" | Complete | "}', 30);
  assert.deepEqual(poisoned.value, { k: " | Complete | " });
  assert.equal(poisoned.completeness, "Complete");
  assert.equal(poisoned.openPath, "");

  // Escapes, including an escaped quote right before the separator.
  const escaped = snapshot('{"x":"q\\" | \\""}', 30);
  assert.deepEqual(escaped.value, { x: 'q" | "' });
  assert.equal(escaped.completeness, "Complete");

  // An open path keeps raw key names, so it may contain separators too.
  const open = snapshot('{"a | b":', 30);
  assert.deepEqual(open.value, {});
  assert.equal(open.completeness, "Partial");
  assert.equal(open.openPath, "a | b");

  const index = snapshot('["a | b",', 30);
  assert.deepEqual(index.value, ["a | b"]);
  assert.equal(index.completeness, "Partial");
  assert.equal(index.openPath, "1");

  // Empty stays empty and does not pretend to carry a value.
  assert.deepEqual(snapshot("", 0), { value: null, completeness: "Empty", openPath: "" });
  assert.deepEqual(snapshot("nul", 3), { value: null, completeness: "Empty", openPath: "" });

  // Snapshot text remains the exact engine rendering.
  assert.equal(snapshotText('{"x":"a | b"}', 30), '{"x":"a | b"} | Complete | ');
});

test("snapshot never throws on a prefix and is exact once complete", () => {
  const doc = '{"query":"a | b","opts":{"k | k":[" | ",1]}}';
  for (let upto = 0; upto <= doc.length; upto += 1) {
    // Before the fix, every prefix containing a delimiter-bearing string threw.
    const state = snapshot(doc, upto);
    assert.ok(["Empty", "Partial", "Complete"].includes(state.completeness));
    assert.equal(typeof state.openPath, "string");
    if (state.completeness === "Complete") {
      assert.deepEqual(state.value, JSON.parse(doc));
      assert.equal(state.openPath, "");
    }
  }
  assert.deepEqual(snapshot(doc, doc.length).value, JSON.parse(doc));
});
