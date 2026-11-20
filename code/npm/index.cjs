"use strict";

// Node entry point. The MoonBit engine is compiled to a plain JavaScript
// script that registers its entry points through three host hooks. This module
// installs the hooks, loads the script once, and exports the captured
// functions. The global namespace is restored afterwards, so importing
// `liwenjson` does not leave `liwenjsonRegister*` or a `liwenjson` object behind.

const path = require("node:path");

const HOOKS = ["liwenjsonRegister1", "liwenjsonRegister2", "liwenjsonRegister3"];

function loadEngine() {
  const registered = Object.create(null);
  const previous = Object.create(null);
  for (const hook of HOOKS) {
    previous[hook] = globalThis[hook];
    globalThis[hook] = (name, fn) => {
      registered[name] = fn;
    };
  }
  try {
    require(path.join(__dirname, "vendor", "liwenjson.js"));
  } finally {
    for (const hook of HOOKS) {
      if (previous[hook] === undefined) {
        delete globalThis[hook];
      } else {
        globalThis[hook] = previous[hook];
      }
    }
  }
  return registered;
}

const engine = loadEngine();

function requireString(name, value) {
  if (typeof value !== "string") {
    throw new TypeError(`liwenjson.${name}: input must be a string`);
  }
}

function profileOf(options) {
  const profile = options && options.profile ? String(options.profile) : "";
  if (profile && !["permissive", "interactive", "execution", "agent", "strict"].includes(profile)) {
    throw new TypeError(`liwenjson: unknown profile "${profile}"`);
  }
  return profile;
}

/**
 * A structured refusal from the engine.
 *
 * The engine's string channel reports a failure as `ERROR: E010 ...`, and the
 * package used to detect that with a prefix test and throw a bare `Error`
 * whose message was the rest of the line. A caller that wanted the code, or
 * the position, had to parse the message back out of an exception. This class
 * keeps them as fields, and it still subclasses `Error`, so `catch (e) { e.message }`
 * keeps working.
 */
class LIWENJSONError extends Error {
  constructor(message) {
    super(message);
    this.name = "LIWENJSONError";
    const match = /^(E\d{3})\b\s*(.*)$/.exec(message);
    this.code = match ? match[1] : "";
    this.detail = match ? match[2] : message;
  }
}

function unwrap(text) {
  if (text.startsWith("ERROR: ")) {
    throw new LIWENJSONError(text.slice("ERROR: ".length));
  }
  return text;
}

/**
 * Repair `input` and return the repaired text.
 *
 * With `options.profile` set, the safety profile decides what may be repaired:
 * `agent` and `execution` refuse a lossy or ambiguous repair instead of
 * guessing, and throw.
 */
function repair(input, options = {}) {
  requireString("repair", input);
  const profile = profileOf(options);
  // A declaration is honoured, not ignored. This function used to read only
  // `profile` and silently drop `schema`/`schemaJson`, so
  // `repair('{"a":1}', {schemaJson: {...a: string}})` returned `{"a":1}` while
  // the Python client and the MCP `liwenjson_repair` tool refused it (audit
  // 4.2). The engine has no separate "repair against a declaration" entry
  // point, and the decision fields `analyze` computes are the same check the
  // other two entry points make, so the declaration path goes through
  // `analyze` and returns its repaired text.
  if (options.schemaJson !== undefined || options.schema !== undefined) {
    const plan = analyze(input, {
      profile: profile || "agent",
      ...(options.schemaJson !== undefined ? { schemaJson: options.schemaJson } : {}),
      ...(options.schema !== undefined ? { schema: options.schema } : {}),
    });
    if (!plan.executable) {
      const reason = plan.error && plan.error.message ? plan.error.message : plan.decision;
      throw new LIWENJSONError(
        `${plan.error && plan.error.code ? plan.error.code : "E070"} ${reason}`,
      );
    }
    return plan.text === undefined ? plan.value === null ? "" : JSON.stringify(plan.value) : plan.text;
  }
  return unwrap(profile ? engine.repair_opts(input, profile) : engine.repair(input));
}

/**
 * The full decision plan. This is the call an agent integration should use
 * before executing tool arguments: it never throws on malformed JSON, and its
 * `executable` field is the gate.
 */
function analyze(input, options = {}) {
  requireString("analyze", input);
  const profile = profileOf(options);
  let plan;
  if (options.schemaJson !== undefined) {
    const json =
      typeof options.schemaJson === "string"
        ? options.schemaJson
        : JSON.stringify(options.schemaJson);
    plan = JSON.parse(engine.analyze_json_schema(input, profile, json));
  } else {
    plan = JSON.parse(engine.analyze(input, profile, options.schema || ""));
  }
  if (plan.decision === undefined) {
    throw new Error(plan.error || "liwenjson.analyze: could not build a plan");
  }
  return plan;
}

/**
 * Repair plus the decision fields, as one object.
 */
function repairResult(input, options = {}) {
  const plan = analyze(input, options);
  return {
    text: plan.text,
    exactness: plan.exactness,
    ambiguous: plan.ambiguous,
    repairs: plan.repairs,
    decision: plan.decision,
    executable: plan.executable,
    error: plan.error,
    retry: plan.retry,
  };
}

/** One `R005 3:14 message` line per repair, or `-`. */
function report(input) {
  requireString("report", input);
  return engine.report(input);
}

const SNAPSHOT_STATES = ["Empty", "Partial", "Complete"];

/**
 * The index just past the JSON value that starts at `start`.
 *
 * The snapshot is rendered as `value | completeness | open path`. A value is
 * JSON, so its strings (and lone string keys) may contain the separator; an
 * open path keeps raw key names, so it may contain it too. Splitting the
 * whole rendering on `" | "` therefore cut values in half and threw
 * `SyntaxError: Unterminated string in JSON` for `{"x":"a | b"}`. This
 * scanner finds where the value ends so the rest is split at a known offset.
 */
function jsonValueEnd(text, start) {
  const fail = () => {
    throw new Error("liwenjson returned an unreadable snapshot: the value is not JSON");
  };
  const first = text[start];
  if (first === '"') {
    let i = start + 1;
    while (i < text.length) {
      const ch = text[i];
      if (ch === "\\") {
        i += 2;
      } else if (ch === '"') {
        return i + 1;
      } else {
        i += 1;
      }
    }
    fail();
  }
  if (first === "{" || first === "[") {
    let depth = 0;
    let i = start;
    while (i < text.length) {
      const ch = text[i];
      if (ch === '"') {
        i += 1;
        while (i < text.length) {
          if (text[i] === "\\") {
            i += 2;
          } else if (text[i] === '"') {
            i += 1;
            break;
          } else {
            i += 1;
          }
        }
        if (i > text.length) {
          fail();
        }
        continue;
      }
      if (ch === "{" || ch === "[") {
        depth += 1;
      } else if (ch === "}" || ch === "]") {
        depth -= 1;
        if (depth === 0) {
          return i + 1;
        }
      }
      i += 1;
    }
    fail();
  }
  const match = /^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(
    text.slice(start),
  );
  if (!match || match[0] === "-" || match[0] === "") {
    fail();
  }
  return start + match[0].length;
}

/**
 * Split one `value | completeness | open path` rendering.
 *
 * Never throw on a value that contains the separator: scan the leading JSON
 * value, then require the fixed `" | "`, one known state token and the second
 * `" | "`. Whatever follows is the open path verbatim (it may itself contain
 * `" | "`). The engine renders "no value yet" as `-`, which cannot collide
 * with JSON because `-` is not a value on its own.
 */
function parseSnapshotText(text) {
  const corrupt = (why) => {
    throw new Error(`liwenjson returned an unreadable snapshot (${why}): ${JSON.stringify(text)}`);
  };
  let value;
  let end;
  if (text.startsWith("- | ")) {
    value = null;
    end = 1;
  } else {
    end = jsonValueEnd(text, 0);
    try {
      value = JSON.parse(text.slice(0, end));
    } catch (error) {
      corrupt(error.message);
    }
    if (text.slice(end, end + 3) !== " | ") {
      corrupt("no separator after the value");
    }
  }
  const rest = text.slice(end + 3);
  const bar = rest.indexOf(" | ");
  if (bar === -1) {
    corrupt("no separator after the completeness");
  }
  const completeness = rest.slice(0, bar);
  if (!SNAPSHOT_STATES.includes(completeness)) {
    corrupt(`unknown completeness ${JSON.stringify(completeness)}`);
  }
  return { value, completeness, openPath: rest.slice(bar + 3) };
}

/**
 * The partial value of the first `upto` code units.
 *
 * The engine's own snapshot is a `value | completeness | open path` string,
 * which is what the browser demo draws. A programmatic caller wants the
 * three fields separately, so they are returned as an object: the string
 * form is still available through `snapshotText`.
 */
function snapshot(input, upto) {
  return parseSnapshotText(snapshotText(input, upto));
}

/** The partial value of the first `upto` code units, as `value | state | path`. */
function snapshotText(input, upto) {
  requireString("snapshot", input);
  return engine.snapshot(input, upto | 0);
}

/** One frame of the streaming view, as an object. */
function live(input, upto, schema = "") {
  requireString("live", input);
  return JSON.parse(engine.live(input, upto | 0, schema));
}

/**
 * The readiness curve for `input` against a skeleton declaration: the three
 * document-level numbers, every field-ready event, and the verdict.
 */
function readiness(input, schema = "") {
  requireString("readiness", input);
  return JSON.parse(engine.readiness(input, schema));
}

/**
 * The delta stream for the first `upto` code units: the protocol a consumer
 * subscribes to instead of re-reading the document on every frame.
 */
function deltas(input, upto) {
  requireString("deltas", input);
  return JSON.parse(engine.deltas(input, upto | 0));
}

/**
 * The gate, with the profile the MCP tools use.
 *
 * `analyze` with no profile used to run the *permissive* profile -- the
 * library's default -- while the MCP gate, which is the product, runs the
 * `agent` profile. A caller who read the MCP documentation and then called
 * the npm package got a different answer from the same input. The npm package
 * is the same product, so it defaults to the same profile; `permissive` is
 * one explicit argument away.
 */
function gate(input, options = {}) {
  return analyze(input, { profile: "agent", ...options });
}

module.exports = {
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
  // The engine version is the package version: one declaration, one source.
  // A literal here went stale once already (it said 1.1.0 while the
  // package was 1.1.1), and nothing noticed, because the test pinned the
  // same stale literal.
  version: require("./package.json").version,
};
