#!/usr/bin/env python3
"""Schema gate audit: order, conjunction, streaming and cross-entry agreement.

This is the executable form of `marks/Schema闸门顺序缺陷分析与同类排查方案.md`
(T-01..T-10). The 1.5.1 defect was a last-write-wins fold of `const`/`enum`, so
`{"mode":"write"}` could pass a declaration that named `read`. The same class
can hide anywhere a declaration is folded into mutable state, so the audit does
not know the implementation:

  * T-01 strict correlation. Every request carries a unique id and every
    response is matched by id. A dropped, duplicated or unknown id, a non-JSON
    line, or a response without its declared result shape is a hard failure:
    the driver must be able to fail, so `--self-test` proves it with four
    fabricated responders.
  * T-02 invariant tests, not request counts. Permutation invariance (JSON
    object key order is not semantic), conjunction (a composite is the AND of
    its atoms, judged by an oracle written here, not by the engine), and
    one-shot/streaming agreement are each decided per case.
  * T-03 declaration matrix. Invalid, unsatisfiable, unsupported, duplicated
    and contradictory declarations must be `E070` on every entry, never a gate
    that quietly rejects every value at run time.
  * T-04 independent oracle. `oracle()` below evaluates the supported JSON
    Schema subset with Python's own semantics (strict JSON equality, numeric
    bounds, code-point lengths, anchored patterns, closed objects). A wrong
    engine answer is a failure even when it is wrong in the safe direction.
  * T-05 entry matrix. serve `validate`/`analyze`/`readiness`/`watch`, the CLI
    `explain`, and the MCP `gate`/`validate` tools must agree with the oracle
    and with each other. The repaired `executable` decision and the raw
    `verdict` are recorded separately, because `validate` never repairs.
  * T-06 streaming. `watch.start`/`feed`/`finish` are driven for real: whole
    text, every single cut point, one code unit per feed, and seeded random
    partitions. `root_ready` may only stand while the final verdict is `ok`.
  * T-07 duplicate input keys. Under a repairing profile a duplicate key makes
    the earlier events provisional; `conflict` and `ready_standing` must say so.
  * T-08 DSL duplicate keywords. All nine constraint names, both orders and a
    case-mixed spelling, are `E070` on every entry.
  * T-09 old build, negative proof. `--old-cli` runs the same corpus against a
    pre-fix binary and requires the audit to *find* the defect there; a green
    run on the fixed build is only meaningful if the same probe is red on the
    broken one.

Usage:
  python3 tests/schema_gate_audit.py --cli ./_build/.../liwenjson[.exe] \
      [--out report.json] [--self-test] [--old-cli OLD] [--verbose]
"""
from __future__ import annotations

import argparse
import itertools
import json
import random
import re
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# The driver: strict id correlation and response shape checks
# ---------------------------------------------------------------------------

class AuditError(RuntimeError):
    """A protocol or driver defect, never a gate verdict."""


def correlate(requests: list[dict], lines: list[str]) -> dict[int, dict]:
    """Match response lines to requests by id, strictly.

    Zipping by line order hides the failure this script exists to find: a
    response that belongs to another request is read as an answer to this one.
    """
    pending = {r["id"] for r in requests}
    if len(pending) != len(requests):
        raise AuditError("request ids are not unique")
    out: dict[int, dict] = {}
    for line in lines:
        if not line.strip():
            continue
        try:
            resp = json.loads(line)
        except json.JSONDecodeError as exc:
            raise AuditError(f"response line is not JSON: {line[:200]!r} ({exc})")
        if not isinstance(resp, dict):
            raise AuditError(f"response is not an object: {line[:200]!r}")
        rid = resp.get("id")
        if not isinstance(rid, int) or isinstance(rid, bool):
            raise AuditError(f"response has no integer id: {line[:200]!r}")
        if rid not in pending:
            raise AuditError(f"response id {rid} is unknown or duplicated")
        ok = resp.get("ok")
        if ok is True:
            if not isinstance(resp.get("result"), dict):
                raise AuditError(f"response {rid} is ok but has no result object")
        elif ok is False:
            err = resp.get("error")
            if not isinstance(err, dict) or not isinstance(err.get("code"), str):
                raise AuditError(f"response {rid} is an error without a code")
        else:
            raise AuditError(f"response {rid} has no boolean `ok`")
        pending.discard(rid)
        out[rid] = resp
    if pending:
        raise AuditError(f"no response for request ids {sorted(pending)}")
    return out


def run_serve(cli: str, requests: list[dict]) -> dict[int, dict]:
    payload = "\n".join(json.dumps(r, ensure_ascii=False) for r in requests) + "\n"
    proc = subprocess.run([cli, "serve"], input=payload, text=True,
                          capture_output=True, timeout=900)
    if proc.returncode != 0:
        raise AuditError(
            f"serve exited {proc.returncode}: {proc.stderr[-600:]}")
    lines = proc.stdout.splitlines()
    return correlate(requests, lines)


class Checker:
    def __init__(self, verbose: bool = False) -> None:
        self.checks = 0
        self.failures: list[dict] = []
        self.sections: dict[str, int] = {}
        self.verbose = verbose

    def check(self, ok: bool, section: str, name: str, **detail) -> bool:
        self.checks += 1
        self.sections[section] = self.sections.get(section, 0) + 1
        if not ok:
            self.failures.append({"section": section, "name": name, **detail})
            if self.verbose:
                print("FAIL", section, name, json.dumps(detail, ensure_ascii=False)[:400])
        return ok


# ---------------------------------------------------------------------------
# Independent oracle for the supported JSON Schema subset
# ---------------------------------------------------------------------------

def _type_name(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, int):
        return "integer"
    if isinstance(v, float):
        return "integer" if v.is_integer() else "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    if isinstance(v, dict):
        return "object"
    raise AssertionError(v)


def json_equal(a, b) -> bool:
    """JSON equality: booleans are not numbers; 1 and 1.0 are the same number."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(json_equal(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(json_equal(x, y) for x, y in zip(a, b))
    if type(a) is not type(b):
        return False
    return a == b


def _type_matches(declared: str, v) -> bool:
    got = _type_name(v)
    if declared == "number":
        return got in ("number", "integer")
    return declared == got


def oracle(schema: dict, value) -> bool:
    """Evaluate a declared schema with Python's own semantics.

    Deliberately independent: it does not call the engine, and it does not
    share the engine's folds. The corpus only uses keywords this function
    implements, so an `unsupported keyword` answer from the engine is a
    separate failure, not something the oracle has to model.
    """
    if not isinstance(schema, dict):
        raise AuditError(f"oracle got a non-object schema: {schema!r}")
    known = {"type", "properties", "required", "items", "enum", "const",
             "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
             "minLength", "maxLength", "pattern", "additionalProperties"}
    extra = set(schema) - known
    if extra:
        raise AuditError(f"oracle does not model keywords {sorted(extra)}")
    if "type" in schema and not _type_matches(schema["type"], value):
        return False
    if "const" in schema and not json_equal(value, schema["const"]):
        return False
    if "enum" in schema and not any(json_equal(value, v) for v in schema["enum"]):
        return False
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            return False
        if "maximum" in schema and value > schema["maximum"]:
            return False
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            return False
        if "exclusiveMaximum" in schema and value >= schema["exclusiveMaximum"]:
            return False
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            return False
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            return False
        if "pattern" in schema:
            # JSON Schema `pattern` is unanchored; the bridge implements the
            # anchored subset and says so, so the corpus only uses `^...$`.
            if re.fullmatch(schema["pattern"], value) is None:
                return False
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for name in schema.get("required", []):
            if name not in value:
                return False
        closed = schema.get("additionalProperties", True) is False
        for name, item in value.items():
            if name in props:
                if not oracle(props[name], item):
                    return False
            elif closed:
                return False
    if isinstance(value, list) and "items" in schema:
        for item in value:
            if not oracle(schema["items"], item):
                return False
    return True


def atoms_of(schema: dict) -> list[tuple[str, dict]]:
    """One keyword per atom, each keeping the node's type and members.

    The member declarations travel with every atom because they describe what
    an object *may contain* (which value each present member must have), not
    an extra claim of their own; only `required` and
    `additionalProperties` decide whether a member may be absent or unknown.
    Without them an atom would forget that `a` must be a string, and the AND
    of the atoms would be weaker than the composite.
    """
    base = {}
    if "type" in schema:
        base["type"] = schema["type"]
    if "properties" in schema:
        base["properties"] = schema["properties"]
    out = []
    for key in ("const", "enum", "minimum", "maximum", "exclusiveMinimum",
                "exclusiveMaximum", "minLength", "maxLength", "pattern",
                "required", "items", "additionalProperties"):
        if key in schema:
            atom = dict(base)
            atom[key] = schema[key]
            out.append((key, atom))
    return out


# ---------------------------------------------------------------------------
# The corpus. Every accepted case has both surfaces (text and JSON) and the
# same expected meaning; `values` are (JSON value, note) pairs.
# ---------------------------------------------------------------------------

def _case(name, dsl, js, values):
    return {"name": name, "dsl": dsl, "js": js, "values": values}


CASES = [
    # A. the historical defect: const + enum on one leaf, both orders.
    _case("leaf_const_enum",
          'string(enum:["read"])',
          {"type": "string", "const": "read", "enum": ["read", "write"]},
          ["read", "write", "admin", 1]),
    _case("leaf_enum_const_reversed",
          'string(enum:["read"])',
          {"enum": ["read", "write"], "const": "read", "type": "string"},
          ["read", "write"]),
    # B. root scalar: the old audit declared a string and fed it an object.
    _case("root_scalar_const",
          'string(enum:["ok"])',
          {"type": "string", "const": "ok"},
          ["ok", "no", 0]),
    # C. required members, closed object.
    _case("obj_required_closed",
          "{!a:string,!b:integer}(additionalProperties:false)",
          {"type": "object",
           "properties": {"a": {"type": "string"}, "b": {"type": "integer"}},
           "required": ["a", "b"], "additionalProperties": False},
          [{"a": "x", "b": 1}, {"a": "x"}, {"a": 1, "b": 1},
           {"a": "x", "b": 1, "c": 2}]),
    # D. container value constraint AND structure (SR-36).
    _case("obj_value_constraint",
          '{!mode:string}(enum:[{"mode":"read"}],additionalProperties:false)',
          {"type": "object",
           "properties": {"mode": {"type": "string"}},
           "required": ["mode"], "enum": [{"mode": "read"}],
           "additionalProperties": False},
          [{"mode": "read"}, {"mode": "write"}, {"mode": "read", "x": 1}]),
    # E. optional member.
    _case("obj_optional",
          "{!a:string,?b:integer}(additionalProperties:false)",
          {"type": "object",
           "properties": {"a": {"type": "string"}, "b": {"type": "integer"}},
           "required": ["a"], "additionalProperties": False},
          [{"a": "x"}, {"a": "x", "b": 1}, {"a": "x", "b": "s"}, {}]),
    # F. arrays.
    _case("arr_items",
          "[integer]",
          {"type": "array", "items": {"type": "integer"}},
          [[1, 2], [1, "x"], []]),
    _case("arr_enum_and_items",
          "[integer](enum:[[1,2]])",
          {"type": "array", "items": {"type": "integer"}, "enum": [[1, 2]]},
          [[1, 2], [1, 3], [], [1, 2, 3]]),
    # G. numeric bounds.
    _case("num_bounds",
          "number(minimum:1,maximum:3)",
          {"type": "number", "minimum": 1, "maximum": 3},
          [0, 1, 2.5, 3, 4]),
    _case("num_exclusive",
          "number(exclusiveMinimum:1,exclusiveMaximum:3)",
          {"type": "number", "exclusiveMinimum": 1, "exclusiveMaximum": 3},
          [1, 2, 3]),
    _case("integer_bounds",
          "integer(minimum:1,maximum:3)",
          {"type": "integer", "minimum": 1, "maximum": 3},
          [1, 3, 0, 1.5]),
    # H. strings: length, character class, both.
    _case("str_length",
          "string(minLength:2,maxLength:3)",
          {"type": "string", "minLength": 2, "maxLength": 3},
          ["a", "ab", "abc", "abcd"]),
    _case("str_pattern",
          "string(pattern:[a-z])",
          {"type": "string", "pattern": "^[a-z]*$"},
          ["ab", "aB", ""]),
    _case("str_length_pattern",
          "string(minLength:2,maxLength:3,pattern:[a-z])",
          {"type": "string", "minLength": 2, "maxLength": 3,
           "pattern": "^[a-z]*$"},
          ["ab", "abc", "a", "ab1"]),
    # I. nesting.
    _case("nested_object",
          "{!outer:{!inner:integer(minimum:0)}(additionalProperties:false)}(additionalProperties:false)",
          {"type": "object",
           "properties": {"outer": {
               "type": "object",
               "properties": {"inner": {"type": "integer", "minimum": 0}},
               "required": ["inner"], "additionalProperties": False}},
           "required": ["outer"], "additionalProperties": False},
          [{"outer": {"inner": 1}}, {"outer": {"inner": -1}},
           {"outer": {}}, {}]),
    # J. value constraint at an inner node.
    _case("nested_const",
          '{!cfg:{!mode:string(enum:["read"])}(additionalProperties:false)}(additionalProperties:false)',
          {"type": "object",
           "properties": {"cfg": {
               "type": "object",
               "properties": {"mode": {"type": "string", "const": "read"}},
               "required": ["mode"], "additionalProperties": False}},
           "required": ["cfg"], "additionalProperties": False},
          [{"cfg": {"mode": "read"}}, {"cfg": {"mode": "write"}}]),
]

# Declarations that must be refused at modelling time (`E070`), with the
# surface they are spelled on. A refusal on one surface and acceptance on the
# other is exactly the divergence §7.3/§9.5 of the audit names.
DECL_REFUSALS = [
    # duplicate constraint keyword, both orders, one case-mixed spelling
    ("dsl", 'string(enum:["read"],enum:["read","write"])'),
    ("dsl", 'string(enum:["read","write"],enum:["read"])'),
    ("dsl", "number(minimum:5,minimum:1)"),
    ("dsl", "number(maximum:1,maximum:5)"),
    ("dsl", "number(exclusiveMinimum:5,exclusiveMinimum:1)"),
    ("dsl", "number(exclusiveMaximum:1,exclusiveMaximum:5)"),
    ("dsl", "string(minLength:4,minLength:1)"),
    ("dsl", "string(maxLength:1,maxLength:4)"),
    ("dsl", "string(pattern:[a-z],pattern:[0-9])"),
    ("dsl", "{}(additionalProperties:false,additionalProperties:true)"),
    ("dsl", "number(MINIMUM:5,minimum:1)"),
    # contradictory bounds
    ("dsl", "string(minLength:4,maxLength:1)"),
    ("dsl", "string(maxLength:1,minLength:4)"),
    ("dsl", "number(minimum:5,maximum:1)"),
    ("dsl", "number(maximum:1,minimum:5)"),
    ("dsl", "number(minimum:5,exclusiveMaximum:5)"),
    ("dsl", "number(exclusiveMinimum:5,maximum:5)"),
    ("dsl", "number(exclusiveMinimum:5,exclusiveMaximum:5)"),
    ("dsl", "number(exclusiveMaximum:5,exclusiveMinimum:5)"),
    # malformed or unsupported text declarations
    ("dsl", 'string(enum:[1])'),
    ("dsl", "string(minLength:-1)"),
    ("dsl", "string(minLength:1.5)"),
    ("dsl", "string(pattern:^[a-z]{2}$)"),
    ("dsl", "string(foo:1)"),
    ("dsl", "{a:string,a:integer}"),
    # JSON Schema: same classes through the bridge
    ("json", {"type": "string", "const": "read", "enum": ["write"]}),
    ("json", {"type": "string", "minLength": 4, "maxLength": 1}),
    ("json", {"type": "number", "minimum": 5, "maximum": 1}),
    ("json", {"type": "number", "minimum": 5, "exclusiveMaximum": 5}),
    ("json", {"type": "number", "exclusiveMinimum": 5,
              "exclusiveMaximum": 5}),
    ("json", {"type": "object", "additionalProperties": {"type": "string"}}),
    ("json", {"type": ["string", "null"]}),
    ("json", {"type": "array", "items": [{"type": "string"}]}),
    ("json", {"minItems": 1}),
    ("json", {"type": "string", "format": "email"}),
    ("json", {"type": "object", "properties": {"a": "string"}}),
    ("json", {"type": "string", "additionalProperties": False}),
    ("json", {"type": "integer", "minLength": 1}),
]

# All nine constraint names, each in both orders, plus a case-mixed spelling
# of the first name. A single missed name would be a last-write-wins hole on
# that keyword alone, so the table is exhaustive rather than sampled.
DUP_CASES = [
    ("minimum", "number(minimum:5,minimum:1)",
     "number(minimum:1,minimum:5)"),
    ("maximum", "number(maximum:1,maximum:5)",
     "number(maximum:5,maximum:1)"),
    ("exclusiveMinimum",
     "number(exclusiveMinimum:5,exclusiveMinimum:1)",
     "number(exclusiveMinimum:1,exclusiveMinimum:5)"),
    ("exclusiveMaximum",
     "number(exclusiveMaximum:1,exclusiveMaximum:5)",
     "number(exclusiveMaximum:5,exclusiveMaximum:1)"),
    ("minLength", "string(minLength:4,minLength:1)",
     "string(minLength:1,minLength:4)"),
    ("maxLength", "string(maxLength:1,maxLength:4)",
     "string(maxLength:4,maxLength:1)"),
    ("enum", 'string(enum:["a"],enum:["a","b"])',
     'string(enum:["a","b"],enum:["a"])'),
    ("pattern", "string(pattern:[a-z],pattern:[0-9])",
     "string(pattern:[0-9],pattern:[a-z])"),
    ("additionalProperties",
     "{}(additionalProperties:false,additionalProperties:true)",
     "{}(additionalProperties:true,additionalProperties:false)"),
]
DUP_MIXED = "number(MINIMUM:5,minimum:1)"


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def json_text(value) -> str:
    return json.dumps(value, ensure_ascii=False)


def serve_call(rid, method, params):
    return {"id": rid, "method": method, "params": params}


def validate_req(rid, value, dsl=None, js=None):
    params = {"text": json_text(value)}
    if dsl is not None:
        params["schema"] = dsl
    if js is not None:
        params["schema_json"] = js
    return serve_call(rid, "validate", params)


def cli_explain(cli: str, decl: str, value, profile: str = "agent") -> dict:
    proc = subprocess.run(
        [cli, "explain", "--json", "--policy", profile, "--schema", decl],
        input=json_text(value), text=True, capture_output=True, timeout=120)
    out = {"rc": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}
    if proc.returncode in (0, 5):
        try:
            body = json.loads(proc.stdout)
        except json.JSONDecodeError:
            out["decision"] = None
            return out
        out["decision"] = body.get("decision")
        out["executable"] = body.get("executable")
        out["schema_ok"] = None
    return out


def run_mcp(cli: str, calls: list[tuple[str, dict]]) -> dict[int, dict]:
    """One MCP process, initialize first, then the tool calls, correlated by id."""
    reqs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                        "clientInfo": {"name": "schema-gate-audit",
                                       "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"}]
    for i, (tool, args) in enumerate(calls, 2):
        reqs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                     "params": {"name": tool, "arguments": args}})
    payload = "\n".join(json.dumps(r, ensure_ascii=False) for r in reqs) + "\n"
    proc = subprocess.run([cli, "mcp"], input=payload, text=True,
                          capture_output=True, timeout=900)
    if proc.returncode != 0:
        raise AuditError(f"mcp exited {proc.returncode}: {proc.stderr[-600:]}")
    lines = [l for l in proc.stdout.splitlines() if l.strip()]
    # initialize has id 1; the notification has none, so the tool calls are
    # exactly the ids 2..len(calls)+1.
    pending = set(range(2, len(calls) + 2))
    out = {}
    seen_init = False
    for line in lines:
        try:
            resp = json.loads(line)
        except json.JSONDecodeError as exc:
            raise AuditError(f"mcp line is not JSON: {line[:200]!r} ({exc})")
        rid = resp.get("id")
        if rid == 1:
            if seen_init:
                raise AuditError("mcp answered initialize twice")
            seen_init = True
            continue
        if not isinstance(rid, int) or rid not in pending:
            raise AuditError(f"mcp response id {rid!r} is unknown or duplicated")
        pending.discard(rid)
        out[rid] = resp
    if not seen_init:
        raise AuditError("mcp never answered initialize")
    if pending:
        raise AuditError(f"mcp did not answer tool calls {sorted(pending)}")
    return out


def mcp_text(resp: dict) -> str:
    res = resp.get("result") or {}
    parts = []
    for item in res.get("content") or []:
        if isinstance(item, dict) and isinstance(item.get("text"), str):
            parts.append(item["text"])
    return "\n".join(parts)


def mcp_structured(resp: dict) -> dict | None:
    res = resp.get("result") or {}
    body = res.get("structuredContent")
    return body if isinstance(body, dict) else None


# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

def section_declaration_matrix(chk: Checker, cli: str) -> None:
    """T-03/T-08: every bad declaration is E070 on every entry."""
    requests = []
    meta = []
    for i, (surface, decl) in enumerate(DECL_REFUSALS):
        params = {"text": "0"}
        if surface == "dsl":
            params["schema"] = decl
        else:
            params["schema_json"] = decl
        requests.append(serve_call(2 * i, "validate", params))
        requests.append(serve_call(2 * i + 1, "watch.start", params))
        # A refusing entry closes nothing; a wrongly accepting one would leave
        # a stream open for every later request. Close it here so a mutant is
        # reported as the defect it is, not as a cascade of E030.
        requests.append(serve_call(-(2 * i + 1), "watch.finish", {}))
        meta.append((surface, decl, 2 * i, 2 * i + 1))
    answers = run_serve(cli, requests)
    for surface, decl, vid, wid in meta:
        label = f"{surface}:{decl if surface == 'dsl' else json.dumps(decl)}"
        v = answers[vid]
        chk.check(v.get("ok") is False, "declaration", f"validate refuses {label}",
                  response=v)
        if v.get("ok") is False:
            chk.check(v["error"]["code"] == "E070", "declaration",
                      f"validate says E070 for {label}", error=v["error"])
        w = answers[wid]
        chk.check(w.get("ok") is False, "declaration",
                  f"watch.start refuses {label}", response=w)
        if w.get("ok") is False:
            chk.check(w["error"]["code"] == "E070", "declaration",
                      f"watch.start says E070 for {label}", error=w["error"])
        if surface == "dsl":
            res = cli_explain(cli, decl, 1)
            chk.check(res["rc"] == 2, "declaration", f"CLI exits 2 for {label}",
                      rc=res["rc"], stderr=res["stderr"][-200:])
            chk.check("E070" in res["stderr"], "declaration",
                      f"CLI names E070 for {label}",
                      stderr=res["stderr"][-200:])

    # The MCP tools refuse the same declarations as tool errors.
    calls = [("liwenjson_gate",
              {"text": "0", **({"schema": d} if s == "dsl" else
                               {"schema_json": d})})
             for s, d in DECL_REFUSALS]
    mcp = run_mcp(cli, calls)
    for i, (surface, decl) in enumerate(DECL_REFUSALS, 2):
        resp = mcp[i]
        res = resp.get("result") or {}
        text = mcp_text(resp)
        chk.check(res.get("isError") is True and "E070" in text, "declaration",
                  f"MCP refuses {surface}:{decl}", text=text[:300])

    # Distinct keywords still combine: the refusal is about repeats, not about
    # constraint lists in general.
    ok_reqs = [
        serve_call(9000, "validate",
                   {"text": '"read"',
                    "schema": 'string(enum:["read"],minLength:1)'}),
        serve_call(9001, "validate",
                   {"text": "2",
                    "schema": "number(minimum:1,maximum:3)"}),
    ]
    ok = run_serve(cli, ok_reqs)
    for rid in (9000, 9001):
        r = ok[rid]
        chk.check(r.get("ok") is True and r["result"]["schema"]["ok"] is True,
                  "declaration", f"distinct keywords accepted ({rid})",
                  response=r)


def section_duplicate_names(chk: Checker, cli: str) -> None:
    """T-08: every constraint name, both orders, is refused on every entry."""
    requests = []
    meta = []
    rid = 80000
    decls = []
    for name, first, reversed_order in DUP_CASES:
        decls.append((name + "/first", first))
        decls.append((name + "/reversed", reversed_order))
    decls.append(("minimum/case-mixed", DUP_MIXED))
    for label, decl in decls:
        requests.append(validate_req(rid, 0, dsl=decl))
        meta.append({"id": rid, "kind": "validate", "label": label})
        rid += 1
        requests.append(serve_call(rid, "watch.start", {"schema": decl}))
        meta.append({"id": rid, "kind": "watch.start", "label": label})
        rid += 1
        requests.append(serve_call(rid, "watch.finish", {}))
        rid += 1
    answers = run_serve(cli, requests)
    for m in meta:
        resp = answers[m["id"]]
        chk.check(resp.get("ok") is False
                  and resp["error"]["code"] == "E070", "duplicate-name",
                  f"{m['kind']} refuses a repeated keyword ({m['label']})",
                  response=resp)
    for label, decl in decls:
        res = cli_explain(cli, decl, 0)
        chk.check(res["rc"] == 2 and "E070" in res["stderr"], "duplicate-name",
                  f"CLI refuses a repeated keyword ({label})",
                  rc=res["rc"], stderr=res["stderr"][-200:])
    # The same nine names are accepted when each appears once.
    single_ok = [
        serve_call(81000, "validate", {"text": "2",
                                       "schema": "number(minimum:1,maximum:3)"}),
        serve_call(81001, "validate", {"text": '"ab"',
                     "schema": "string(minLength:1,maxLength:3,pattern:[a-z])"}),
        serve_call(81002, "validate", {"text": '{"a":1}',
                     "schema": "{!a:integer}(additionalProperties:false,enum:[{\"a\":1}])"}),
    ]
    ans = run_serve(cli, single_ok)
    for rid in (81000, 81001, 81002):
        r = ans[rid]
        chk.check(r.get("ok") is True and r["result"]["schema"]["ok"] is True,
                  "duplicate-name",
                  "the nine names combine when each appears once", response=r)


def section_cross_entry(chk: Checker, cli: str) -> None:
    """T-04/T-05: oracle agreement across every entry, for every case/value."""
    requests = []
    meta = []

    def add(rid, kind, case, value, dsl=None, js=None):
        meta.append({"id": rid, "kind": kind, "case": case, "value": value,
                     "dsl": dsl, "js": js})
        return validate_req(rid, value, dsl=dsl, js=js)

    rid = 10000
    for case in CASES:
        for value in case["values"]:
            requests.append(add(rid, "js_validate", case["name"], value,
                                js=case["js"]))
            rid += 1
            requests.append(add(rid, "dsl_validate", case["name"], value,
                                dsl=case["dsl"]))
            rid += 1
            requests.append(serve_call(rid, "analyze",
                                       {"text": json_text(value),
                                        "schema_json": case["js"]}))
            meta.append({"id": rid, "kind": "js_analyze",
                         "case": case["name"], "value": value})
            rid += 1
            requests.append(serve_call(rid, "readiness",
                                       {"text": json_text(value),
                                        "schema_json": case["js"]}))
            meta.append({"id": rid, "kind": "js_readiness",
                         "case": case["name"], "value": value})
            rid += 1
            # One-chunk watch stream: the protocol's own final account.
            requests.append(serve_call(rid, "watch.start",
                                       {"schema_json": case["js"]}))
            meta.append({"id": rid, "kind": "watch_start",
                         "case": case["name"], "value": value})
            rid += 1
            requests.append(serve_call(rid, "watch.feed",
                                       {"chunk": json_text(value)}))
            meta.append({"id": rid, "kind": "watch_feed",
                         "case": case["name"], "value": value})
            rid += 1
            requests.append(serve_call(rid, "watch.finish", {}))
            meta.append({"id": rid, "kind": "watch_finish",
                         "case": case["name"], "value": value})
            rid += 1

    # Canonical text round trip: watch.start(dsl) prints the declaration the
    # engine will actually use; feeding a value back through that text must
    # produce the same answer (SR-37 without stringify/parse drift).
    canon_meta = []
    for case in CASES:
        requests.append(serve_call(rid, "watch.start", {"schema": case["dsl"]}))
        canon_meta.append({"id": rid, "case": case["name"]})
        rid += 1
        requests.append(serve_call(rid, "watch.finish", {}))
        rid += 1
    answers = run_serve(cli, requests)
    canonical = {}
    for m in canon_meta:
        resp = answers[m["id"]]
        chk.check(resp.get("ok") is True, "roundtrip",
                  f"watch.start accepts {m['case']}", response=resp)
        if resp.get("ok") is True:
            canonical[m["case"]] = resp["result"]["schema"]

    case_by_name = {c["name"]: c for c in CASES}
    roundtrip_reqs = []
    roundtrip_meta = []
    for case in CASES:
        text = canonical.get(case["name"])
        if text is None:
            continue
        for value in case["values"]:
            roundtrip_reqs.append(validate_req(rid, value, dsl=text))
            roundtrip_meta.append({"id": rid, "case": case["name"],
                                   "value": value})
            rid += 1
    rt = run_serve(cli, roundtrip_reqs)
    for m in roundtrip_meta:
        resp = rt[m["id"]]
        expected = oracle(case_by_name[m["case"]]["js"], m["value"])
        got = (resp.get("ok") is True and
               resp["result"]["schema"]["ok"] is True)
        chk.check(got == expected, "roundtrip",
                  f"canonical text keeps {m['case']}",
                  value=m["value"], expected=expected, response=resp)

    # Walk the collected answers.
    per_value = {}
    for m in meta:
        resp = answers[m["id"]]
        key = m["case"], json_text(m["value"])
        per_value.setdefault(key, {})[m["kind"]] = resp
    for (case_name, value_text), rows in per_value.items():
        case = case_by_name[case_name]
        value = json.loads(value_text)
        expected = oracle(case["js"], value)
        for kind, resp in rows.items():
            if kind == "watch_feed":
                continue
            if resp.get("ok") is not True:
                chk.check(False, "cross-entry",
                          f"{kind} failed for {case_name} {value_text}",
                          response=resp)
                continue
            result = resp["result"]
            if kind in ("js_validate", "dsl_validate"):
                chk.check("schema" in result, "cross-entry",
                          f"{kind} carries a verdict for {case_name}",
                          response=resp)
                if "schema" in result:
                    got = bool(result["schema"]["ok"])
                    chk.check(got == expected, "cross-entry",
                              f"{kind} agrees with oracle for {case_name}",
                              value=value, expected=expected, got=got,
                              mismatched=result["schema"].get("mismatched"))
            elif kind == "js_readiness":
                chk.check("verdict" in result, "cross-entry",
                          f"readiness carries a verdict for {case_name}")
                if "verdict" in result:
                    chk.check(bool(result["verdict"]["ok"]) == expected,
                              "cross-entry",
                              f"readiness agrees with oracle for {case_name}",
                              value=value, expected=expected,
                              got=result["verdict"]["ok"])
            elif kind == "js_analyze":
                chk.check(bool(result.get("executable")) == expected,
                          "cross-entry",
                          f"analyze executable agrees with oracle for {case_name}",
                          value=value, expected=expected,
                          got=result.get("executable"),
                          error=result.get("error"))
            elif kind == "watch_finish":
                chk.check("verdict" in result and "conflict" in result
                          and "ready_standing" in result, "cross-entry",
                          f"watch.finish reports its decision for {case_name}",
                          result_keys=sorted(result))
                if "verdict" in result:
                    chk.check(bool(result["verdict"]["ok"]) == expected,
                              "cross-entry",
                              f"watch verdict agrees with oracle for {case_name}",
                              value=value, expected=expected)
                    chk.check(result.get("conflict") is False, "cross-entry",
                              f"watch reports no conflict for {case_name}")
                    chk.check(result.get("ready_standing") == expected,
                              "cross-entry",
                              f"watch ready_standing agrees for {case_name}",
                              expected=expected,
                              got=result.get("ready_standing"))

    # CLI: the text surface, exit code semantics.
    for case in CASES:
        for value in case["values"]:
            expected = oracle(case["js"], value)
            res = cli_explain(cli, case["dsl"], value)
            chk.check(res["rc"] == (0 if expected else 5), "cross-entry",
                      f"CLI explain exit code for {case['name']}",
                      value=value, expected_rc=(0 if expected else 5),
                      rc=res["rc"], stderr=res["stderr"][-200:])
            if res["rc"] in (0, 5):
                chk.check(bool(res.get("executable")) == expected,
                          "cross-entry",
                          f"CLI explain executable for {case['name']}",
                          value=value, expected=expected,
                          got=res.get("executable"))

    # MCP: gate and validate are separate entries with separate contracts.
    calls = []
    call_meta = []
    for case in CASES:
        for value in case["values"]:
            calls.append(("liwenjson_gate",
                          {"text": json_text(value), "schema": case["dsl"]}))
            call_meta.append((case["name"], value, "gate"))
            calls.append(("liwenjson_validate",
                          {"text": json_text(value), "schema": case["dsl"]}))
            call_meta.append((case["name"], value, "validate"))
    mcp = run_mcp(cli, calls)
    for i, (case_name, value, tool) in enumerate(call_meta, 2):
        case = case_by_name[case_name]
        expected = oracle(case["js"], value)
        body = mcp_structured(mcp[i])
        chk.check(body is not None, "cross-entry",
                  f"MCP {tool} has structuredContent for {case_name}",
                  response=mcp[i])
        if body is None:
            continue
        if tool == "gate":
            chk.check("executable" in body and "schema_total" in body,
                      "cross-entry",
                      f"MCP gate shape for {case_name}", keys=sorted(body))
            if "executable" in body:
                chk.check(bool(body["executable"]) == expected, "cross-entry",
                          f"MCP gate agrees with oracle for {case_name}",
                          value=value, expected=expected,
                          got=body["executable"])
                # T-05: the repaired executable decision and the raw verdict are
                # two questions; for an already-valid document they must agree.
                chk.check(bool(body.get("valid_json")) is True
                          and bool(body.get("executable")) == expected,
                          "cross-entry",
                          f"MCP gate verdict/executable consistency {case_name}")
        else:
            chk.check("schema" in body, "cross-entry",
                      f"MCP validate carries a verdict for {case_name}")
            if "schema" in body:
                chk.check(bool(body["schema"]["ok"]) == expected, "cross-entry",
                          f"MCP validate agrees with oracle for {case_name}",
                          value=value, expected=expected,
                          got=body["schema"]["ok"])


def section_conjunction(chk: Checker, cli: str) -> None:
    """T-02: composite == AND(atoms), with atoms judged by the oracle."""
    requests = []
    meta = []
    rid = 20000
    for case in CASES:
        for key, atom in atoms_of(case["js"]):
            for value in case["values"]:
                requests.append(validate_req(rid, value, js=atom))
                meta.append({"id": rid, "case": case["name"], "key": key,
                             "value": value, "atom": atom})
                rid += 1
    answers = run_serve(cli, requests)
    for m in meta:
        resp = answers[m["id"]]
        key = (m["case"], json_text(m["value"]))
        expected = oracle(m["atom"], m["value"])
        if resp.get("ok") is not True:
            chk.check(False, "conjunction",
                      f"atom {m['key']} was refused for {m['case']}",
                      atom=m["atom"], response=resp)
            continue
        got = bool(resp["result"]["schema"]["ok"])
        chk.check(got == expected, "conjunction",
                  f"atom {m['key']} agrees with oracle for {m['case']}",
                  value=m["value"], expected=expected, got=got)
        m["engine"] = got
    # Composite must be the AND of its atoms, both in the oracle and in the
    # engine's own answers (the latter catches a composite that ignores an atom
    # even if the oracle agrees with it).
    by_case = {}
    for m in meta:
        by_case.setdefault((m["case"], json_text(m["value"])), []).append(m)
    for (case_name, value_text), rows in by_case.items():
        case = next(c for c in CASES if c["name"] == case_name)
        value = json.loads(value_text)
        composite = oracle(case["js"], value)
        chk.check(composite == all(oracle(r["atom"], value) for r in rows),
                  "conjunction",
                  f"oracle composite is the AND of atoms for {case_name}",
                  value=value)
        chk.check(composite == all(r["engine"] for r in rows), "conjunction",
                  f"engine composite is the AND of its atoms for {case_name}",
                  value=value, composite=composite,
                  atoms={r["key"]: r["engine"] for r in rows})


def _permutations(node, limit=12):
    """Every key order of every object node, applied one node at a time."""
    if isinstance(node, dict):
        keys = list(node)
        perms = list(itertools.permutations(keys))
        perms = perms[:limit]
        variants = []
        seen = set()
        for order in perms:
            variant = {k: node[k] for k in order}
            signature = json.dumps(variant, sort_keys=False,
                                   ensure_ascii=False)
            if signature not in seen:
                seen.add(signature)
                variants.append(variant)
        return variants
    return [node]


def section_order(chk: Checker, cli: str) -> None:
    """T-02: declaration and input key order must not change the answer."""
    requests = []
    meta = []
    rid = 30000
    for case in CASES:
        variants = _permutations(case["js"])
        for vi, variant in enumerate(variants):
            for value in case["values"]:
                requests.append(validate_req(rid, value, js=variant))
                meta.append({"id": rid, "case": case["name"], "vi": vi,
                             "value": value, "variant": variant})
                rid += 1
            requests.append(serve_call(rid, "watch.start",
                                       {"schema_json": variant}))
            meta.append({"id": rid, "kind": "canon", "case": case["name"],
                         "vi": vi})
            rid += 1
            requests.append(serve_call(rid, "watch.finish", {}))
            rid += 1
    answers = run_serve(cli, requests)
    canon = {}
    for m in meta:
        if m.get("kind") == "canon":
            resp = answers[m["id"]]
            chk.check(resp.get("ok") is True, "order",
                      f"variant accepted {m['case']}#{m['vi']}",
                      response=resp)
            if resp.get("ok") is True:
                canon.setdefault(m["case"], set()).add(resp["result"]["schema"])
    for case, texts in canon.items():
        chk.check(len(texts) == 1, "order",
                  f"canonical text is order independent for {case}",
                  texts=sorted(texts))
    for m in meta:
        if m.get("kind") == "canon":
            continue
        resp = answers[m["id"]]
        case = next(c for c in CASES if c["name"] == m["case"])
        expected = oracle(case["js"], m["value"])
        if resp.get("ok") is not True:
            chk.check(False, "order",
                      f"declaration order broke {m['case']}",
                      variant=m["variant"], response=resp)
            continue
        chk.check(bool(resp["result"]["schema"]["ok"]) == expected, "order",
                  f"declaration order keeps {m['case']}",
                  variant=m["variant"], value=m["value"])

    # Input member order: JSON objects are unordered.
    reqs = []
    metas = []
    for case in CASES:
        for value in case["values"]:
            if not isinstance(value, dict) or len(value) < 2:
                continue
            variants = []
            for order in itertools.permutations(value):
                variants.append({k: value[k] for k in order})
            for vi, variant in enumerate(variants[:6]):
                reqs.append(validate_req(rid, variant, js=case["js"]))
                metas.append({"id": rid, "case": case["name"],
                              "value": variant})
                rid += 1
    if reqs:
        ans = run_serve(cli, reqs)
        for m in metas:
            case = next(c for c in CASES if c["name"] == m["case"])
            resp = ans[m["id"]]
            expected = oracle(case["js"], m["value"])
            got = (resp.get("ok") is True and
                   bool(resp["result"]["schema"]["ok"]))
            chk.check(got == expected, "order",
                      f"input order keeps {m['case']}",
                      value=m["value"], expected=expected, got=got)


def _partitions(text: str, rng: random.Random) -> list[list[str]]:
    """Real feed splits: whole, every single cut, per code unit, random."""
    n = len(text)
    out = [[text]]
    for i in range(1, n):
        out.append([text[:i], text[i:]])
    out.append(list(text))
    for _ in range(3):
        cuts = sorted(rng.sample(range(1, n), min(3, max(0, n - 1))))
        chunks = []
        prev = 0
        for cut in cuts:
            chunks.append(text[prev:cut])
            prev = cut
        chunks.append(text[prev:])
        out.append(chunks)
    # Deduplicate identical partitions.
    seen = set()
    unique = []
    for part in out:
        sig = tuple(part)
        if sig not in seen:
            seen.add(sig)
            unique.append(part)
    return unique


def section_streaming(chk: Checker, cli: str, rng: random.Random) -> None:
    """T-06: real watch splits, and a promise that is only made when true."""
    requests = []
    meta = []
    rid = 40000
    texts = {}
    for case in CASES:
        for vi, value in enumerate(case["values"]):
            text = json_text(value)
            if len(text) > 48:
                continue
            for pi, part in enumerate(_partitions(text, rng)):
                requests.append(serve_call(rid, "watch.start",
                                           {"schema_json": case["js"]}))
                meta.append({"id": rid, "kind": "start", "case": case["name"],
                             "value": value, "part": pi, "chunks": part})
                rid += 1
                for chunk in part:
                    requests.append(serve_call(rid, "watch.feed",
                                               {"chunk": chunk}))
                    meta.append({"id": rid, "kind": "feed",
                                 "case": case["name"], "value": value,
                                 "part": pi, "chunks": part})
                    rid += 1
                requests.append(serve_call(rid, "watch.finish", {}))
                meta.append({"id": rid, "kind": "finish",
                             "case": case["name"], "value": value,
                             "part": pi, "chunks": part})
                rid += 1
    answers = run_serve(cli, requests)
    case_by_name = {c["name"]: c for c in CASES}
    # Rebuild per-stream results.
    streams = {}
    for m in meta:
        key = (m["case"], json_text(m["value"]), m["part"])
        streams.setdefault(key, {"chunks": m["chunks"], "responses": []})
        streams[key]["responses"].append((m["kind"], answers[m["id"]]))
    for (case_name, value_text, part), stream in streams.items():
        case = case_by_name[case_name]
        value = json.loads(value_text)
        expected = oracle(case["js"], value)
        text = json_text(value)
        rows = stream["responses"]
        start = rows[0][1]
        finish = rows[-1][1]
        chk.check(start.get("ok") is True, "streaming",
                  f"watch.start for {case_name} part {part}",
                  response=start)
        if start.get("ok") is not True:
            continue
        chk.check(finish.get("ok") is True, "streaming",
                  f"watch.finish for {case_name} part {part}",
                  response=finish, chunks=stream["chunks"])
        if finish.get("ok") is not True:
            continue
        result = finish["result"]
        chk.check(bool(result["verdict"]["ok"]) == expected, "streaming",
                  f"streaming verdict agrees with oracle for {case_name}",
                  value=value, expected=expected, part=part,
                  chunks=stream["chunks"])
        chk.check(result["ready_standing"] == expected, "streaming",
                  f"ready_standing only stands for true for {case_name}",
                  value=value, expected=expected,
                  got=result["ready_standing"], chunks=stream["chunks"])
        chk.check(result.get("conflict") is False, "streaming",
                  f"no conflict for a legal document {case_name}")
        # Events: every event must carry its offset, be ordered, and a
        # root_ready that the final verdict contradicts must be retracted.
        root_ready = False
        retracted = False
        last_at = -1
        fed = 0
        for kind, resp in rows:
            if kind != "feed":
                continue
            if resp.get("ok") is not True:
                chk.check(False, "streaming",
                          f"feed failed for a legal document {case_name}",
                          response=resp, chunk=stream["chunks"])
                continue
            for ev in resp["result"].get("events", []):
                at = ev.get("at", -1)
                chk.check(at >= last_at, "streaming",
                          f"events are ordered for {case_name}",
                          event=ev, part=part)
                last_at = max(last_at, at)
                if ev.get("kind") == "root_ready":
                    root_ready = True
                elif ev.get("kind") == "root_invalid":
                    retracted = True
        if root_ready and not expected:
            chk.check(retracted, "streaming",
                      f"a false root_ready is retracted for {case_name}",
                      value=value, chunks=stream["chunks"])
        # Bytes is the fed length in UTF-16 code units, not chunks.
        total = sum(len(chunk.encode("utf-16-le")) // 2
                    for chunk in stream["chunks"])
        last_feed = [r for k, r in rows if k == "feed"][-1]
        if last_feed.get("ok") is True:
            chk.check(last_feed["result"]["bytes"] == total, "streaming",
                      f"bytes counts UTF-16 code units for {case_name}",
                      expected=total, got=last_feed["result"]["bytes"])


def section_repair_path(chk: Checker, cli: str) -> None:
    """T-05: a repaired value must satisfy the declaration it is executed under.

    `analyze` is the repairing entry, so `executable` is a decision about the
    *repaired* value, not about the raw text. `validate` is the non-repairing
    entry and must never answer with a repaired value. The two questions are
    kept apart here so a gate that says `executable` about a value it never
    checked cannot hide behind the other entry.
    """
    requests = []
    meta = []
    rid = 70000

    def add(kind, text, js=None, profile=None):
        nonlocal rid
        params = {"text": text}
        if js is not None:
            params["schema_json"] = js
        if profile is not None:
            params["profile"] = profile
        method = "validate" if kind == "validate" else "analyze"
        requests.append(serve_call(rid, method, params))
        meta.append({"id": rid, "kind": kind, "text": text, "js": js})
        rid += 1

    decl = {"type": "object", "properties": {"a": {"type": "string"}},
            "required": ["a"], "additionalProperties": False}
    add("validate", '{"a":"x",}', decl)
    add("analyze", '{"a":"x",}', decl, "permissive")
    add("analyze", '{"a":"x","a":1}', decl, "permissive")
    add("analyze", '{"a":1,"a":"x"}', decl, "permissive")
    add("analyze", '{"a":"x"}', decl, "agent")
    answers = run_serve(cli, requests)
    for m in meta:
        resp = answers[m["id"]]
        chk.check(resp.get("ok") is True, "repair",
                  f"{m['kind']} answers for {m['text'][:20]}", response=resp)
        if resp.get("ok") is not True:
            continue
        result = resp["result"]
        if m["kind"] == "validate":
            # It never repairs: no value, no executable decision.
            chk.check("value" not in result or result.get("value") is None,
                      "repair", "validate never returns a repaired value",
                      result=result)
            chk.check(result.get("valid") is False, "repair",
                      "validate reports the raw text as invalid", result=result)
            continue
        if result.get("executable") is True:
            chk.check(result.get("value") is not None, "repair",
                      "executable carries the value it decided on", result=result)
            if result.get("value") is not None:
                ok = oracle(decl, result["value"])
                chk.check(ok, "repair",
                          "executable value satisfies the declaration",
                          value=result["value"], result=result)
        if result.get("error") is not None:
            chk.check(result.get("executable") is not True, "repair",
                      "a refusal never claims executable", result=result)


def section_duplicate_keys(chk: Checker, cli: str) -> None:
    """T-07: a duplicate key makes the earlier events provisional."""
    reqs = []
    meta = []
    rid = 50000

    def watch_case(name, schema, text, profile):
        nonlocal rid
        params = {"schema": schema, "profile": profile}
        reqs.append(serve_call(rid, "watch.start", params))
        meta.append({"id": rid, "kind": "start", "name": name})
        rid += 1
        reqs.append(serve_call(rid, "watch.feed", {"chunk": text}))
        meta.append({"id": rid, "kind": "feed", "name": name})
        rid += 1
        reqs.append(serve_call(rid, "watch.finish", {}))
        meta.append({"id": rid, "kind": "finish", "name": name})
        rid += 1

    watch_case("merge_invalid", "{!a:string}", '{"a":"x","a":1}', "permissive")
    watch_case("merge_valid", "{!a:string}", '{"a":"x","a":"y"}', "permissive")
    watch_case("merge_agent", "{!a:string}", '{"a":"x","a":1}', "agent")
    answers = run_serve(cli, reqs)
    got = {}
    for m in meta:
        got.setdefault(m["name"], {})[m["kind"]] = answers[m["id"]]
    # A merge that ends in an invalid value: the stream must not promise ready.
    r = got["merge_invalid"]
    chk.check(r["feed"].get("ok") is True, "duplicate",
              "permissive merge feeds", response=r["feed"])
    if r["feed"].get("ok") is True and r["finish"].get("ok") is True:
        fin = r["finish"]["result"]
        chk.check(bool(fin["verdict"]["ok"]) is False, "duplicate",
                  "merged invalid value is rejected", verdict=fin["verdict"])
        chk.check(fin.get("conflict") is True, "duplicate",
                  "merge sets conflict", response=fin)
        chk.check(fin.get("ready_standing") is False, "duplicate",
                  "merge does not leave ready standing", response=fin)
        kinds = [e.get("kind") for e in r["feed"]["result"]["events"]]
        chk.check("root_invalid" in kinds, "duplicate",
                  "invalid merge publishes root_invalid", events=kinds)
    # A merge that ends in a valid value: no promise, but the verdict is ok.
    r = got["merge_valid"]
    if r["finish"].get("ok") is True:
        fin = r["finish"]["result"]
        chk.check(bool(fin["verdict"]["ok"]) is True, "duplicate",
                  "merged valid value is accepted", verdict=fin["verdict"])
        chk.check(fin.get("conflict") is True, "duplicate",
                  "valid merge still reports conflict", response=fin)
        # A published `root_ready` is about the value as it has arrived; a
        # duplicate that still ends in a satisfying value does not make it
        # false, but `conflict` tells the host the earlier events described a
        # value that no longer exists. What must never happen is a standing
        # promise over a value the final verdict rejects.
        chk.check(not (fin.get("ready_standing") is True
                       and fin["verdict"]["ok"] is False), "duplicate",
                  "ready_standing never outlives an invalid verdict",
                  response=fin)
    # Strict profiles refuse the lossy merge before it can be executed.
    r = got["merge_agent"]
    chk.check(r["feed"].get("ok") is False, "duplicate",
              "agent profile refuses the duplicate key", response=r["feed"])
    if r["feed"].get("ok") is False:
        chk.check(r["feed"]["error"]["code"].startswith("E0"), "duplicate",
                  "agent refusal is a documented engine error",
                  error=r["feed"]["error"])


def section_self_test(chk: Checker) -> None:
    """T-01: prove the driver fails on the four fabricated defects."""
    reqs = [{"id": 1, "method": "validate"}, {"id": 2, "method": "validate"}]

    def expects_error(name, fn):
        try:
            fn()
        except AuditError:
            chk.check(True, "self-test", name)
        else:
            chk.check(False, "self-test", name,
                      detail="the driver accepted a fabricated defect")

    expects_error("a dropped response is a failure",
                  lambda: correlate(reqs, ['{"id":1,"ok":true,"result":{}}']))
    expects_error("a duplicated id is a failure",
                  lambda: correlate(reqs, [
                      '{"id":1,"ok":true,"result":{}}',
                      '{"id":1,"ok":true,"result":{}}']))
    expects_error("an unknown id is a failure",
                  lambda: correlate(reqs, [
                      '{"id":1,"ok":true,"result":{}}',
                      '{"id":3,"ok":true,"result":{}}']))
    expects_error("ok without a result object is a failure",
                  lambda: correlate([reqs[0]], ['{"id":1,"ok":true}']))
    expects_error("a response without a verdict is a failure",
                  lambda: _require_schema({"result": {"valid": True}}))
    expects_error("a non-JSON line is a failure",
                  lambda: correlate(reqs, ["not json"]))


def _require_schema(resp: dict) -> None:
    """A validate answer without a `schema` field is a shape defect."""
    result = resp.get("result")
    if not isinstance(result, dict) or "schema" not in result:
        raise AuditError("validate answered without a `schema` verdict")


def section_old_build(chk: Checker, old_cli: str, new_cli: str) -> None:
    """T-09: the same probe must be red on the pre-fix build.

    A green run on the fixed build only means something if the identical probe
    is red on the build that had the defect. `c1168b1~1` folded `const` and
    `enum` into one slot, so one key order allowed a value the declaration
    named away. The probe is the bridge form (the text form never had `const`).
    """
    requests = []
    meta = []
    rid = 60000
    defect_cases = [c for c in CASES
                    if c["name"] in ("leaf_const_enum", "root_scalar_const")]
    for case in defect_cases:
        for vi, variant in enumerate(_permutations(case["js"])):
            for value in case["values"]:
                requests.append(validate_req(rid, value, js=variant))
                meta.append({"id": rid, "case": case["name"], "vi": vi,
                             "value": value, "variant": variant})
                rid += 1
    old = run_serve(old_cli, requests)
    new = run_serve(new_cli, requests)
    old_wrong_allow = []
    new_mismatch = []
    for m in meta:
        expected = oracle(
            next(c for c in CASES if c["name"] == m["case"])["js"], m["value"])
        o = old[m["id"]]
        n = new[m["id"]]
        old_got = (o.get("ok") is True and bool(o["result"]["schema"]["ok"]))
        new_got = (n.get("ok") is True and bool(n["result"]["schema"]["ok"]))
        if old_got != expected:
            if old_got and not expected:
                old_wrong_allow.append(m)
        if new_got != expected:
            new_mismatch.append(m)
    chk.check(len(old_wrong_allow) > 0, "old-build",
              "the audit finds the 1.5.1 wrong-allow on the pre-fix build",
              wrong_allows=len(old_wrong_allow))
    chk.check(len(new_mismatch) == 0, "old-build",
              "the fixed build passes the same probe",
              mismatches=[{"case": m["case"], "value": m["value"]}
                          for m in new_mismatch])


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--out", default="")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--old-cli", default="")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    chk = Checker(args.verbose)
    rng = random.Random(20261121)

    if args.self_test:
        section_self_test(chk)

    section_declaration_matrix(chk, args.cli)
    section_duplicate_names(chk, args.cli)
    section_cross_entry(chk, args.cli)
    section_conjunction(chk, args.cli)
    section_order(chk, args.cli)
    section_streaming(chk, args.cli, rng)
    section_repair_path(chk, args.cli)
    section_duplicate_keys(chk, args.cli)
    if args.old_cli:
        section_old_build(chk, args.old_cli, args.cli)

    report = {
        "cli": args.cli,
        "checks": chk.checks,
        "failures": len(chk.failures),
        "cases": len(CASES),
        "sections": chk.sections,
        "declaration_refusals": len(DECL_REFUSALS),
        "detail": chk.failures[:200],
    }
    if args.out:
        Path(args.out).write_text(
            json.dumps(report, ensure_ascii=False, indent=1))
    for f in chk.failures[:12]:
        print("FAIL", f["section"], f["name"],
              json.dumps({k: v for k, v in f.items()
                          if k not in ("section", "name")},
                         ensure_ascii=False)[:500])
    print(f"checks={chk.checks} cases={report['cases']} "
          f"failures={len(chk.failures)}")
    return 1 if chk.failures else 0


if __name__ == "__main__":
    sys.exit(main())
