#!/usr/bin/env python3
"""Differential test: the gate against an independent JSON Schema validator.

    python3 tests/json_schema_diff.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe

Why this exists
---------------
The Schema-gate audit (`marks/审计.md` §10) ends with a rule that cannot be
checked by testing the implementation against itself:

    every legal JSON value InterJSON calls executable must also be accepted by
    an independent validator; if the declared subset cannot express a
    declaration, InterJSON must refuse it with E070 at modelling time instead
    of running a looser check.

So this script runs a curated corpus of declarations through both the gate and
`jsonschema` (the reference implementation) and asserts the one direction that
matters:

    gate says executable  =>  the reference validator accepts the value

The other direction is deliberately *not* asserted. The skeleton is stricter
than JSON Schema in a few documented places (it infers `object` from a bare
`properties`/`required`, because a tool argument is always an object), and
being stricter is failing closed, which is the safe side of a gate. Those cases
are counted and printed rather than failed.

A declaration the gate refuses with `E070` is skipped: refusing a declaration is
the documented answer for a subset that cannot express it, and there is nothing
to compare.

Exit codes: 0 all good (including the "reference validator not installed"
skip), 1 a value the gate allowed was rejected by the reference, 2 the harness
could not run.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys


def load_reference():
    """The reference validator, or `None` when it is not installed."""
    try:
        import jsonschema
    except ImportError:
        return None
    return jsonschema


# (declaration, value) pairs. Every declaration is inside the subset the bridge
# claims to support, so a refusal here would be a bug in the bridge rather than
# an expected "cannot express it".
CORPUS: list[tuple[str, object]] = [
    # --- scalar roots: the type must participate in the decision ---
    ('{"type":"string"}', "42"),
    ('{"type":"string"}', 42),
    ('{"type":"integer"}', 42),
    ('{"type":"integer"}', 42.5),
    ('{"type":"integer"}', 42.0),
    ('{"type":"number"}', 42),
    ('{"type":"boolean"}', True),
    ('{"type":"boolean"}', 0),
    ('{"type":"null"}', None),
    ('{"type":"null"}', 0),
    # `{"type":"any"}` is the bridge's own extension, not a JSON Schema type;
    # the reference validator has nothing to say about it, so it is not here.
    # --- the audit's headline: const and enum are conjunctive ---
    (
        '{"type":"string","const":"read","enum":["read","write"]}',
        "read",
    ),
    (
        '{"type":"string","const":"read","enum":["read","write"]}',
        "write",
    ),
    (
        '{"type":"string","enum":["read","write"],"const":"read"}',
        "read",
    ),
    (
        '{"type":"string","enum":["read","write"],"const":"read"}',
        "write",
    ),
    ('{"const":42}', 42),
    ('{"const":42}', 43),
    ('{"type":"string","enum":["a","b"],"minLength":1,"maxLength":1}', "a"),
    ('{"type":"string","enum":["a","b"],"minLength":1,"maxLength":1}', "ab"),
    ('{"type":"integer","minimum":1,"maximum":2}', 1),
    ('{"type":"integer","minimum":1,"maximum":2}', 0),
    ('{"type":"integer","minimum":1,"maximum":2}', 3),
    ('{"type":"number","exclusiveMinimum":0,"exclusiveMaximum":1}', 0.5),
    ('{"type":"number","exclusiveMinimum":0,"exclusiveMaximum":1}', 0),
    ('{"type":"number","exclusiveMinimum":0,"exclusiveMaximum":1}', 1),
    ('{"type":"string","pattern":"^[a-z]+$"}', "abc"),
    ('{"type":"string","pattern":"^[a-z]+$"}', "ab1"),
    ('{"type":"string","pattern":"^[a-z]{2,4}$"}', "abc"),
    ('{"type":"string","pattern":"^[a-z]{2,4}$"}', "a"),
    ('{"type":"string","pattern":"^[a-z]{2,4}$"}', "abcde"),
    # --- objects: required members and optional members ---
    (
        '{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer"}},"required":["a"]}',
        {"a": "x"},
    ),
    (
        '{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer"}},"required":["a"]}',
        {"a": "x", "b": 1},
    ),
    (
        '{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer"}},"required":["a"]}',
        {"b": 1},
    ),
    (
        '{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer"}},"required":["a"]}',
        {"a": 1},
    ),
    # A member declared `required` without a `properties` entry means "any
    # value, but present".
    ('{"type":"object","required":["x"]}', {"x": 1}),
    ('{"type":"object","required":["x"]}', {}),
    # --- arrays ---
    ('{"type":"array","items":{"type":"integer"}}', [1, 2]),
    ('{"type":"array","items":{"type":"integer"}}', [1, "2"]),
    ('{"type":"array","items":{"type":"string","minLength":1}}', ["a"]),
    ('{"type":"array","items":{"type":"string","minLength":1}}', [""]),
    ('{"type":"array"}', []),
    ('{"type":"array"}', {}),
    # --- a container's value constraint is conjunctive with its shape ---
    (
        '{"type":"array","enum":[[1],["bad"]],"items":{"type":"integer"}}',
        [1],
    ),
    (
        '{"type":"array","enum":[[1],["bad"]],"items":{"type":"integer"}}',
        ["bad"],
    ),
    (
        '{"type":"array","enum":[[1],["bad"]],"items":{"type":"integer"}}',
        [2],
    ),
    (
        '{"type":"object","enum":[{"other":1},{"mode":"read","other":1}],"properties":{"mode":{"type":"string","const":"read"}},"required":["mode"]}',
        {"other": 1},
    ),
    (
        '{"type":"object","enum":[{"other":1},{"mode":"read","other":1}],"properties":{"mode":{"type":"string","const":"read"}},"required":["mode"]}',
        {"mode": "read", "other": 1},
    ),
    (
        '{"type":"object","enum":[{"other":1},{"mode":"read","other":1}],"properties":{"mode":{"type":"string","const":"read"}},"required":["mode"]}',
        {"mode": "write", "other": 1},
    ),
    # A constrained container nested two levels down.
    (
        '{"type":"object","properties":{"cfg":{"type":"object","enum":[{"a":1}],"properties":{"a":{"type":"integer"}},"required":["a"]}},"required":["cfg"]}',
        {"cfg": {"a": 1}},
    ),
    (
        '{"type":"object","properties":{"cfg":{"type":"object","enum":[{"a":1}],"properties":{"a":{"type":"integer"}},"required":["a"]}},"required":["cfg"]}',
        {"cfg": {}},
    ),
    (
        '{"type":"object","properties":{"cfg":{"type":"object","enum":[{"a":1}],"properties":{"a":{"type":"integer"}},"required":["a"]}},"required":["cfg"]}',
        {"cfg": {"a": 2}},
    ),
    # Structured `const` and `enum`: value equality, not text equality.
    ('{"type":"object","const":{"a":1,"b":2},"enum":[{"b":2,"a":1}]}', {"a": 1, "b": 2}),
    ('{"type":"object","const":{"a":1,"b":2},"enum":[{"b":2,"a":1}]}', {"a": 1}),
]


def gate_verdict(cli: str, declaration: str, value: object) -> dict:
    """One `analyze` request over `serve`; the result object."""
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "analyze",
        "params": {
            "text": json.dumps(value),
            "schema_json": json.loads(declaration),
        },
    }
    proc = subprocess.run(
        [cli, "serve"],
        input=json.dumps(request),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError(
            f"serve exited {proc.returncode}: {proc.stderr.strip()[:200]}"
        )
    response = json.loads(proc.stdout.splitlines()[0])
    if response.get("ok") is False:
        # A declaration-level refusal: E070. Reported by the caller.
        return {"refused": (response.get("error") or {}).get("code", "?")}
    return response["result"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True, help="the built interjson binary")
    args = parser.parse_args()

    jsonschema = load_reference()
    if jsonschema is None:
        print("jsonschema is not installed; skipping the differential check")
        return 0

    allowed = refused_declaration = stricter = 0
    mismatches: list[str] = []
    stricter_cases: list[str] = []

    for declaration, value in CORPUS:
        verdict = gate_verdict(args.cli, declaration, value)
        if "refused" in verdict:
            refused_declaration += 1
            print(f"skip  {declaration}  (gate refused it: {verdict['refused']})")
            continue
        executable = bool(verdict.get("executable"))
        reference = jsonschema.Draft202012Validator(
            json.loads(declaration)
        ).is_valid(value)
        if executable:
            allowed += 1
            if not reference:
                mismatches.append(
                    f"gate allowed {json.dumps(value)} under {declaration}, "
                    f"but the reference validator rejects it"
                )
                print(f"FAIL  {declaration}  {json.dumps(value)}  gate=allow reference=reject")
            else:
                print(f"ok    {declaration}  {json.dumps(value)}  gate=allow")
        else:
            if reference:
                stricter += 1
                stricter_cases.append(f"{declaration}  {json.dumps(value)}")
                print(
                    f"ok    {declaration}  {json.dumps(value)}  gate=reject reference=allow (stricter)"
                )
            else:
                print(f"ok    {declaration}  {json.dumps(value)}  gate=reject")

    print()
    print(f"cases: {len(CORPUS)}")
    print(f"allowed by the gate and confirmed by the reference: {allowed}")
    print(f"stricter than the reference (fails closed): {stricter}")
    print(f"declarations refused with E070: {refused_declaration}")
    if stricter_cases:
        print("\nthe stricter cases, for the record:")
        for case in stricter_cases:
            print(f"  {case}")

    if mismatches:
        print()
        for m in mismatches:
            print(f"FAIL  {m}")
        print(
            "\nA value the gate calls executable must be acceptable to the "
            "reference validator. This is the direction that matters: the gate "
            "may be stricter, never looser."
        )
        return 1
    print("\njson_schema_diff: OK — no value the gate allows is rejected by the reference")
    return 0


if __name__ == "__main__":
    sys.exit(main())
