// Regression tests for the Schema-gate audit (`marks/审计.md`).
//
// The audit found that the gate could *allow* a value the declaration forbids,
// and that the allow depended on things JSON Schema says are meaningless:
//
//   1. the order the keywords happen to appear in (`const` and `enum` were
//      written into the same slot, so the later one erased the earlier one);
//   2. whether a container carried a value constraint at all (a `Constrained`
//      object or array had its `required` members and `items` skipped);
//   3. a decimal quantifier that wrapped around Int32 (`{4294967296}` became
//      `{0}`);
//   4. `items` with no `type`, which was silently dropped;
//   5. a bare scalar root type, which `evaluate` did not check.
//
// Every test here is written as a *gate* assertion -- "this must not be
// executable" -- rather than as a statement about the implementation, because
// that is the property the audit says was missing. They are also written to
// fail on the pre-fix code: the comment above each group names the bug it
// pins, so a future change that reintroduces one is caught by a red test
// rather than by another audit.

// ---------------------------------------------------------------------------
// P0-1: `const` and `enum` are conjunctive, and the result does not depend on
// the order the keywords were written in.
// ---------------------------------------------------------------------------

///|
/// `Schema::parse_json_schema`, or `Any` when the declaration is refused.
fn gate_schema(text : String) -> Schema {
  Schema::parse_json_schema(text) catch {
    _ => Any
  }
}

///|
/// `"ok"`, or the `E` code the declaration was refused with.
fn gate_code(text : String) -> String {
  try {
    ignore(Schema::parse_json_schema(text))
    "ok"
  } catch {
    e => e.code()
  }
}

///|
/// Whether `value` (JSON text) passes `declaration` (JSON Schema text).
///
/// A declaration the bridge refuses is *not* a declaration that allows
/// everything: `false` is the only safe answer, and returning `Any` here would
/// make a test pass by accident.
fn gate_allows(declaration : String, value : String) -> Bool {
  let schema = Schema::parse_json_schema(declaration) catch {
    _ => return false
  }
  let v = parse(value) catch { _ => return false }
  schema.evaluate(v.value).ok
}

///|
/// Whether `value` (JSON text) passes `declaration` (the library's text form).
fn dsl_allows(declaration : String, value : String) -> Bool {
  let schema = Schema::parse(declaration) catch { _ => return false }
  let v = parse(value) catch { _ => return false }
  schema.evaluate(v.value).ok
}

///|
/// All six orderings of `type`, `const` and `enum` on one node.
///
/// The audit's reproducer was exactly this: `{type, const, enum}` allowed
/// `{"mode":"write"}` and `{type, enum, const}` refused it. A security decision
/// that moves when a JSON object's keys are reordered is not a decision.
fn const_enum_orders() -> Array[String] {
  [
    // The two orders the audit used, then every other permutation.
    "{\"type\":\"string\",\"const\":\"read\",\"enum\":[\"read\",\"write\"]}", "{\"type\":\"string\",\"enum\":[\"read\",\"write\"],\"const\":\"read\"}",
    "{\"const\":\"read\",\"type\":\"string\",\"enum\":[\"read\",\"write\"]}", "{\"const\":\"read\",\"enum\":[\"read\",\"write\"],\"type\":\"string\"}",
    "{\"enum\":[\"read\",\"write\"],\"type\":\"string\",\"const\":\"read\"}", "{\"enum\":[\"read\",\"write\"],\"const\":\"read\",\"type\":\"string\"}",
  ]
}

///|
test "TC-GATE-01 const and enum are conjunctive whatever the field order" {
  // `const:"read"` ∩ `enum:["read","write"]` is `{"read"}`: `read` passes and
  // `write` does not, in every ordering.
  for decl in const_enum_orders() {
    assert_true(gate_allows(decl, "\"read\""), msg=decl + " must allow read")
    assert_false(
      gate_allows(decl, "\"write\""),
      msg=decl + " must refuse write",
    )
  }
  // And the six orderings normalise to the same declaration: the intersection
  // is the constant, so the enum collapses to it.
  let first = gate_schema(const_enum_orders()[0]).stringify()
  for decl in const_enum_orders() {
    assert_eq(gate_schema(decl).stringify(), first, msg=decl)
  }
  assert_eq(first, "string(enum:[\"read\"])")
}

///|
test "TC-GATE-02 an unsatisfiable const/enum pair is an E070 in either order" {
  // `{"const":"read","enum":["write"]}` can never be satisfied. The audit's
  // warning was specific: "const wins" is *not* a fix, because it would let
  // `"read"` through a declaration that forbids it.
  for
    decl in [
      "{\"type\":\"string\",\"const\":\"read\",\"enum\":[\"write\"]}", "{\"type\":\"string\",\"enum\":[\"write\"],\"const\":\"read\"}",
    ] {
    assert_eq(gate_code(decl), "E070", msg=decl)
  }
}

///|
test "TC-GATE-03 structured const and enum intersect by value, not by text" {
  // The same object written with its keys in a different order is the same
  // JSON value, and `enum` membership is value equality.
  assert_true(
    gate_allows(
      "{\"type\":\"object\",\"const\":{\"a\":1,\"b\":2},\"enum\":[{\"b\":2,\"a\":1}]}",
      "{\"a\":1,\"b\":2}",
    ),
  )
  assert_false(
    gate_allows(
      "{\"type\":\"object\",\"const\":{\"a\":1},\"enum\":[{\"a\":2}]}", "{\"a\":1}",
    ),
  )
  // A structured constant outside its enumeration is unsatisfiable.
  assert_eq(
    gate_code("{\"type\":\"object\",\"const\":{\"a\":1},\"enum\":[{\"a\":2}]}"),
    "E070",
  )
}

///|
test "TC-GATE-04 an empty enum is refused, not silently all-rejecting" {
  // The audit's §10 asks for a deterministic answer: an empty `enum` can never
  // be satisfied, so it is a declaration error rather than a gate that rejects
  // every value at runtime.
  assert_eq(gate_code("{\"type\":\"string\",\"enum\":[]}"), "E070")
}

///|
test "TC-GATE-05 every constraint is conjunctive, not an alternative" {
  // `const` alone rejects, `enum` alone rejects, and adding the other one
  // must not turn a rejection back into an allow.
  let decl = "{\"type\":\"string\",\"const\":\"read\",\"enum\":[\"read\",\"write\"],\"minLength\":4,\"pattern\":\"^[a-z]+$\"}"
  assert_true(gate_allows(decl, "\"read\""))
  // Each constraint on its own is enough to refuse, and adding the rest does
  // not undo it.
  assert_false(gate_allows(decl, "\"write\""))
  assert_false(gate_allows(decl, "\"rea\""))
  assert_false(gate_allows(decl, "\"READ\""))
  assert_false(gate_allows(decl, "\"read \""))
}

// ---------------------------------------------------------------------------
// P0-2: a value constraint on a container does not skip the container's shape.
// ---------------------------------------------------------------------------

///|
test "TC-GATE-06 a constrained array still checks its items" {
  // The audit's array reproducer: `["bad"]` is a member of the enum, but it
  // violates `items.type = integer`. Membership in `enum` is one claim, the
  // element kinds are another, and both apply.
  let decl = "{\"type\":\"object\",\"properties\":{\"items\":{\"type\":\"array\",\"enum\":[[1],[\"bad\"]],\"items\":{\"type\":\"integer\"}}},\"required\":[\"items\"]}"
  assert_false(gate_allows(decl, "{\"items\":[\"bad\"]}"))
  assert_true(gate_allows(decl, "{\"items\":[1]}"))
  // The same declaration in the library's own text form.
  assert_false(dsl_allows("[integer](enum:[[1],[\"bad\"]])", "[\"bad\"]"))
  assert_true(dsl_allows("[integer](enum:[[1],[\"bad\"]])", "[1]"))
}

///|
test "TC-GATE-07 a constrained object still checks its required members" {
  // The audit's object reproducer: `{"other":1}` is the first enum value but
  // it is missing the required `mode`.
  let decl = "{\"type\":\"object\",\"enum\":[{\"other\":1},{\"mode\":\"read\",\"other\":1}],\"properties\":{\"mode\":{\"type\":\"string\",\"const\":\"read\"}},\"required\":[\"mode\"]}"
  assert_false(gate_allows(decl, "{\"other\":1}"))
  assert_true(gate_allows(decl, "{\"mode\":\"read\",\"other\":1}"))
  assert_false(gate_allows(decl, "{\"mode\":\"write\",\"other\":1}"))
}

///|
test "TC-GATE-08 a constrained container nested in a member is still walked" {
  // The constraint can sit at any depth, and so can the shape it wraps.
  let decl = "{\"type\":\"object\",\"properties\":{\"cfg\":{\"type\":\"object\",\"enum\":[{\"a\":1}],\"properties\":{\"a\":{\"type\":\"integer\"}},\"required\":[\"a\"]}},\"required\":[\"cfg\"]}"
  assert_true(gate_allows(decl, "{\"cfg\":{\"a\":1}}"))
  assert_false(gate_allows(decl, "{\"cfg\":{}}"))
  assert_false(gate_allows(decl, "{\"cfg\":{\"a\":\"x\"}}"))
}

///|
test "TC-GATE-09 a constrained array of objects checks every element" {
  let decl = "{\"type\":\"array\",\"enum\":[[{\"a\":1}],[{\"a\":2}]],\"items\":{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"}},\"required\":[\"a\"]}}"
  assert_true(gate_allows(decl, "[{\"a\":1}]"))
  assert_false(gate_allows(decl, "[{\"a\":\"x\"}]"))
  assert_false(gate_allows(decl, "[{\"b\":1}]"))
}

///|
test "TC-GATE-10 required_paths and at_path see through a container constraint" {
  // The streaming watcher follows `required_paths()` and resolves each one
  // with `at_path`; both used to stop at the `Constrained` wrapper, so a
  // required member inside a constrained container was never followed.
  let s = gate_schema(
    "{\"type\":\"object\",\"enum\":[{\"a\":1}],\"properties\":{\"a\":{\"type\":\"integer\"}},\"required\":[\"a\"]}",
  )
  assert_eq(s.required_paths(), ["a"])
  assert_true(s.at_path("a") is Some(_))
  assert_eq(s.member_keys(), ["a"])
  assert_true(s.field("a") is Some(_))
}

// ---------------------------------------------------------------------------
// P1-3: a `pattern` quantifier that cannot be represented is refused.
// ---------------------------------------------------------------------------

///|
test "TC-GATE-11 a quantifier beyond Int32 is an E070, never a wrap-around" {
  // The audit's reproducer: 4294967296 is 2^32, which wrapped to 0 and turned
  // "exactly 4294967296 characters" into "exactly 0 characters", so the empty
  // string passed a declaration that forbids it.
  assert_eq(
    gate_code("{\"type\":\"string\",\"pattern\":\"^[a-z]{4294967296}$\"}"),
    "E070",
  )
  assert_eq(
    gate_code("{\"type\":\"string\",\"pattern\":\"^[a-z]{2147483648}$\"}"),
    "E070",
  )
  // The boundary itself is representable and stays exact.
  assert_eq(
    gate_schema("{\"type\":\"string\",\"pattern\":\"^[a-z]{2147483647}$\"}").stringify(),
    "string(minLength:2147483647,maxLength:2147483647,pattern:[a-z])",
  )
  // A long digit string is a declaration error, not a panic and not a wrap.
  assert_eq(
    gate_code(
      "{\"type\":\"string\",\"pattern\":\"^[a-z]{999999999999999999999999}$\"}",
    ),
    "E070",
  )
  // Leading zeroes are the same number, and still cannot smuggle a wrap.
  assert_eq(
    gate_code("{\"type\":\"string\",\"pattern\":\"^[a-z]{0004294967296}$\"}"),
    "E070",
  )
}

///|
test "TC-GATE-12 a length bound beyond Int32 is an E070" {
  // `minLength`/`maxLength` go through the same "must be exactly representable"
  // rule, so a bound the implementation cannot hold is refused rather than
  // clamped.
  assert_eq(gate_code("{\"type\":\"string\",\"minLength\":4294967296}"), "E070")
  assert_eq(gate_code("{\"type\":\"string\",\"maxLength\":1e30}"), "E070")
}

// ---------------------------------------------------------------------------
// P1-4: a structural keyword the kind never reads is an E070.
// ---------------------------------------------------------------------------

///|
test "TC-GATE-13 items without type is refused, not silently dropped" {
  // `{"items":{"type":"integer"}}` means "if this is an array, its elements
  // are integers". The skeleton has no conditional, and inferring `array`
  // would reject the non-arrays JSON Schema allows, so the declaration is
  // refused instead of being read as `any`.
  assert_eq(gate_code("{\"items\":{\"type\":\"integer\"}}"), "E070")
  assert_eq(
    gate_code("{\"type\":\"object\",\"items\":{\"type\":\"integer\"}}"),
    "E070",
  )
  assert_eq(
    gate_code(
      "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}},\"items\":{\"type\":\"integer\"}}",
    ),
    "E070",
  )
}

///|
test "TC-GATE-14 properties and required on a non-object kind are refused" {
  assert_eq(
    gate_code(
      "{\"type\":\"string\",\"properties\":{\"a\":{\"type\":\"string\"}}}",
    ),
    "E070",
  )
  assert_eq(gate_code("{\"type\":\"string\",\"required\":[\"a\"]}"), "E070")
  assert_eq(gate_code("{\"type\":\"array\",\"required\":[\"a\"]}"), "E070")
}

// ---------------------------------------------------------------------------
// P1-5: a root declaration is a claim about the value, constrained or not.
// ---------------------------------------------------------------------------

///|
test "TC-GATE-15 a bare scalar root type participates in the decision" {
  // The audit's reproducer: `{"type":"string"}` accepted the number `42`.
  // A declaration the caller wrote and the gate ignored is not a gate.
  assert_false(gate_allows("{\"type\":\"string\"}", "42"))
  assert_true(gate_allows("{\"type\":\"string\"}", "\"42\""))
  assert_false(gate_allows("{\"type\":\"integer\"}", "\"42\""))
  assert_false(gate_allows("{\"type\":\"boolean\"}", "1"))
  assert_false(gate_allows("{\"type\":\"null\"}", "0"))
  assert_false(gate_allows("{\"type\":\"array\"}", "{}"))
  assert_false(gate_allows("{\"type\":\"object\"}", "[]"))
  // `any` is the declaration that accepts everything, and still does.
  assert_true(gate_allows("{\"type\":\"any\"}", "42"))
}

///|
test "TC-GATE-16 a bare scalar root type is checked in the library's own text form" {
  // The same rule through `Schema::parse`, so the two declaration languages
  // cannot disagree about it.
  assert_false(dsl_allows("string", "42"))
  assert_true(dsl_allows("string", "\"42\""))
  assert_false(dsl_allows("integer", "\"42\""))
  assert_false(dsl_allows("null", "0"))
}

// ---------------------------------------------------------------------------
// P2-7: the text form is lossless for the declarations the bridge builds.
// ---------------------------------------------------------------------------

///|
test "TC-GATE-17 stringify keeps a container's value constraint" {
  // The audit's §9: `Constrained(Arr/Obj, c).stringify()` returned the inner
  // container, dropping `c`, so the text could not be used as an equivalent
  // declaration.
  let obj = gate_schema(
    "{\"type\":\"object\",\"enum\":[{\"a\":1}],\"properties\":{\"a\":{\"type\":\"integer\"}},\"required\":[\"a\"]}",
  )
  let text = obj.stringify()
  assert_eq(text, "{!a:integer}(enum:[{\"a\":1}])")
  // Re-parsing the text yields a declaration with the same verdicts.
  let again = schema_or_any(text)
  assert_eq(again.stringify(), text)
  assert_true(dsl_allows(text, "{\"a\":1}"))
  assert_false(dsl_allows(text, "{\"a\":2}"))
  assert_false(dsl_allows(text, "{}"))

  let arr = gate_schema(
    "{\"type\":\"array\",\"enum\":[[1]],\"items\":{\"type\":\"integer\"}}",
  )
  assert_eq(arr.stringify(), "[integer](enum:[[1]])")
  assert_true(dsl_allows("[integer](enum:[[1]])", "[1]"))
  assert_false(dsl_allows("[integer](enum:[[1]])", "[2]"))
  assert_false(dsl_allows("[integer](enum:[[1]])", "[\"x\"]"))
}

///|
test "TC-GATE-18 the text form round trips structured enum literals" {
  // A structured `const` becomes a one-element `enum`; the text form has to be
  // able to write it and read it back, or `parse(stringify(s))` is a weaker
  // gate than `s`.
  let s = gate_schema("{\"const\":{\"a\":1}}")
  assert_eq(s.stringify(), "any(enum:[{\"a\":1}])")
  let again = schema_or_any(s.stringify())
  assert_eq(again.stringify(), s.stringify())
  assert_true(dsl_allows(s.stringify(), "{\"a\":1}"))
  assert_false(dsl_allows(s.stringify(), "{\"a\":2}"))
}

// ---------------------------------------------------------------------------
// Cross-check: the gate's verdict and `accepts` agree on the fixed cases.
// ---------------------------------------------------------------------------

///|
test "TC-GATE-19 a value the gate allows satisfies the declaration it was checked against" {
  // The audit's closing recommendation: every value the gate calls executable
  // must also be accepted by the declaration. These are the declarations the
  // audit found wrong, now asserted in the direction that matters.
  let cases : Array[(String, String)] = [
    (
      "{\"type\":\"string\",\"const\":\"read\",\"enum\":[\"read\",\"write\"]}", "\"read\"",
    ),
    (
      "{\"type\":\"object\",\"properties\":{\"items\":{\"type\":\"array\",\"enum\":[[1],[\"bad\"]],\"items\":{\"type\":\"integer\"}}},\"required\":[\"items\"]}",
      "{\"items\":[1]}",
    ),
    (
      "{\"type\":\"object\",\"enum\":[{\"other\":1},{\"mode\":\"read\",\"other\":1}],\"properties\":{\"mode\":{\"type\":\"string\",\"const\":\"read\"}},\"required\":[\"mode\"]}",
      "{\"mode\":\"read\",\"other\":1}",
    ),
    ("{\"type\":\"string\"}", "\"42\""),
  ]
  for pair in cases {
    let (decl, value) = pair
    assert_true(gate_allows(decl, value), msg=decl)
  }
}

///|
test "TC-GATE-26 a hand-built nested constraint is conjunctive" {
  // `Schema` and `Constraints` are public, so a caller can build a
  // `Constrained` inside a `Constrained`. Every layer is a claim about the
  // same value, and the outer one must not erase the inner one.
  let inner : Constraints = {
    ..Constraints::none(),
    enum_values: Some([Json::string("a"), Json::string("ab")]),
  }
  let outer : Constraints = { ..Constraints::none(), min_length: Some(2), }
  let s = Schema::Constrained(Schema::Constrained(Schema::Str, inner), outer)
  assert_false(s.accepts(Json::string("a")), msg="outer minLength 2")
  assert_true(s.accepts(Json::string("ab")))
  assert_false(s.accepts(Json::string("cd")), msg="inner enum")
  // The same through `evaluate`, which is what the gate uses.
  assert_false(s.evaluate(Json::string("a")).ok)
  assert_true(s.evaluate(Json::string("ab")).ok)
  assert_false(s.evaluate(Json::string("cd")).ok)
}

///|
test "TC-GATE-27 schema_violation names a violation and is empty when satisfied" {
  // One sentence for the gate and for `repair`, so the two cannot disagree.
  let s = gate_schema(
    "{\"type\":\"object\",\"properties\":{\"mode\":{\"type\":\"string\",\"enum\":[\"read\"]}},\"required\":[\"mode\"]}",
  )
  assert_eq(schema_violation(s, jv("{\"mode\":\"read\"}")), "")
  let refused = schema_violation(s, jv("{\"mode\":\"write\"}"))
  assert_true(
    refused.contains("does not satisfy the declared skeleton"),
    msg=refused,
  )
  assert_true(refused.contains("mismatch mode"), msg=refused)
  let missing = schema_violation(s, jv("{}"))
  assert_true(missing.contains("missing mode"), msg=missing)
}
