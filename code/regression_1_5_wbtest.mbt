// The 1.5 regression suite.
//
// Every case here is a defect that shipped in 1.4.x and was found by reading
// the code rather than by running it. They are grouped in one file so that
// the next reader can see, in one place, what the review found and what now
// holds.
//
// The order is the order of severity: the two that let a wrong value through
// first, then the ones that refuse wrongly, then the ones that crash.

///|
/// A plan for `input` under the default options.
fn reg_analyze(input : String) -> RepairPlan {
  analyze(input, options=Options::default())
}

///|
/// A plan for `input` under one profile.
fn reg_analyze_with(input : String, opts : Options) -> RepairPlan {
  analyze(input, options=opts)
}

// ---------------------------------------------------------------------------
// R018 must compare the numbers themselves, not their Double approximation.
// ---------------------------------------------------------------------------

///|
test "TC-R-01 two integers that share a Double are two different values" {
  // 9007199254740993 and 9007199254740992 are adjacent integers beyond
  // 2^53. As `Double`s they are the same number, so the old comparison
  // called them equal, recorded the merge as harmless (`Info`), and the gate
  // reported `executable: true` for a value it had silently changed.
  let plan = reg_analyze("{\"id\":9007199254740993,\"id\":9007199254740992}")
  assert_true(plan.exactness == Lossy, msg="exactness")
  assert_true(plan.decision == LossyRepair, msg="decision")
  assert_eq(plan.is_executable(), false)
  assert_eq(plan.repairs.length(), 1)
  assert_eq(plan.repairs[0].rule, "R018")
  assert_true(plan.repairs[0].severity == Warning, msg="severity")
}

///|
test "TC-R-02 two spellings of one number are one value" {
  // The other direction matters too: `1` and `1.0` denote the same number,
  // so merging them loses nothing and must not be reported as a loss.
  for pair in [("1", "1.0"), ("100", "1e2"), ("0.5", "5e-1"), ("-0", "0")] {
    let (a, b) = pair
    let plan = reg_analyze("{\"v\":" + a + ",\"v\":" + b + "}")
    assert_true(
      plan.repairs[0].severity == Info,
      msg="merging " + a + " and " + b + " must not be a loss",
    )
    assert_true(plan.exactness == Cosmetic, msg="exactness")
    assert_eq(plan.is_executable(), true)
  }
}

///|
test "TC-R-03 equal duplicates stay harmless" {
  let plan = reg_analyze("{\"a\":[1,2],\"a\":[1,2]}")
  assert_eq(plan.repairs[0].rule, "R018")
  assert_true(plan.repairs[0].severity == Info, msg="severity")
  assert_true(plan.exactness == Cosmetic, msg="exactness")
}

///|
test "TC-R-04 different values still merge as a loss" {
  let plan = reg_analyze("{\"a\":1,\"a\":2}")
  assert_true(plan.repairs[0].severity == Warning, msg="severity")
  assert_true(plan.exactness == Lossy, msg="exactness")
}

// ---------------------------------------------------------------------------
// The rule table must be sized from the enum and must fail closed.
// ---------------------------------------------------------------------------

///|
test "TC-R-05 the rule table has a slot for every repair code" {
  // The table used to be a literal 22, which left `R022 NormalizeLiteral`
  // -- the code added in the same release -- outside it. The table is now
  // sized from `RepairCode::count()`, and this is the assertion that keeps
  // the two together when a 23rd code appears.
  assert_eq(RuleSet::all().flags.length(), RepairCode::count() + 1)
}

///|
test "TC-R-06 every repair code can be switched off" {
  // `disable` used to be a silent no-op for a code with no slot, so a caller
  // believed a rule was off when it was not.
  let all = RuleSet::all()
  let off = all.disable(NormalizeLiteral)
  assert_eq(off.is_enabled(NormalizeLiteral), false)
  assert_eq(off.enable(NormalizeLiteral).is_enabled(NormalizeLiteral), true)
  // The rule that fires on a re-cased literal is now really off.
  let mut saw = false
  try {
    let _ = repair("[True]", options={ ..Options::default(), rules: off, })
  } catch {
    StrictViolation(code, _, _) => saw = code is NormalizeLiteral
    _ => ()
  }
  assert_eq(saw, true)
}

// ---------------------------------------------------------------------------
// A refusal must carry the sentence to send back to the model, and no value.
// ---------------------------------------------------------------------------

///|
test "TC-R-07 a refusal carries a retry prompt" {
  // `plan_of_final` set `retry_hint: None` for an accepted result, so a plan
  // that was accepted but not executable serialised as `"retry": null` --
  // a refusal with no prompt, while the tool description told the caller to
  // send `retry.prompt` back to the model. Under `permissive` a lossy repair
  // is accepted (nothing was refused) and still not executable, which is
  // exactly the case that produced the empty retry.
  let plan = reg_analyze("{\"a\":1,\"a\":2}")
  assert_true(plan.decision == LossyRepair, msg="decision")
  assert_eq(plan.is_executable(), false)
  let json = plan.to_json()
  assert_true(json.contains("\"retry\":{"), msg=json)
  assert_true(json.contains("\"prompt\":"), msg=json)
  // A refusal under `strict` takes the other path -- `plan_of_error` with a
  // hint -- and must also carry a prompt.
  let strict_plan = analyze("{\"a\":1,}", options=Options::strict())
  assert_eq(strict_plan.is_executable(), false)
  assert_true(
    strict_plan.to_json().contains("\"prompt\":"),
    msg=strict_plan.to_json(),
  )
}

///|
test "TC-R-08 a value that fails its declaration is refused without a value" {
  let plan = analyze(
    "{\"a\":1}",
    options=Options::default(),
    schema=Schema::parse("{!a:string}"),
  )
  assert_true(plan.decision == Invalid, msg="decision")
  assert_eq(plan.is_executable(), false)
  assert_eq(plan.value, None)
  assert_eq(plan.error_code, "E070")
  let json = plan.to_json()
  assert_true(json.contains("\"value\":null"), msg=json)
  assert_true(json.contains("\"retry\":{"), msg=json)
  assert_true(json.contains("E070"), msg=json)
}

///|
test "TC-R-09 an executable plan keeps its value" {
  let plan = reg_analyze("{\"a\":1}")
  assert_eq(plan.is_executable(), true)
  assert_eq(plan.value is Some(_), true)
  let json = plan.to_json()
  assert_true(json.contains("\"value\":{\"a\":1}"), msg=json)
  assert_true(json.contains("\"retry\":null"), msg=json)
}

// ---------------------------------------------------------------------------
// The agent profile must be the agent profile, protocol included.
// ---------------------------------------------------------------------------

///|
test "TC-R-10 the agent profile skips prose" {
  // `Options::for_agent()` has always skipped prose, because a model in a
  // chat channel writes a sentence before the arguments. The MCP gate
  // selects its profile *by name*, and the name used to apply the safety
  // knobs only -- so the flagship tool refused the most common shape of
  // model output.
  let opts = Options::for_agent()
  assert_eq(opts.skip_prose, true)
  let plan = reg_analyze_with("Here are the args:\n{\"a\":1}", opts)
  assert_eq(plan.is_executable(), true)
  assert_eq(plan.value is Some(_), true)
}

///|
test "TC-R-11 the agent profile by name is the agent profile" {
  let by_name = Options::default().with_profile(SafetyPolicy::for_agent())
  let preset = Options::for_agent()
  assert_eq(by_name.skip_prose, preset.skip_prose)
  assert_true(by_name.max_loss == preset.max_loss, msg="max_loss")
  assert_eq(by_name.reject_ambiguous, preset.reject_ambiguous)
  assert_eq(by_name.max_depth, preset.max_depth)
  assert_eq(by_name.max_input_len, preset.max_input_len)
  assert_true(by_name.mode == preset.mode, msg="mode")
  assert_true(
    by_name.duplicate_keys == preset.duplicate_keys,
    msg="duplicate_keys",
  )
}

///|
test "TC-R-12 the other profiles do not skip prose" {
  // Only the agent profile is a chat channel. `execution` is the policy
  // behind a host that executes without a human, and it must still refuse a
  // document whose beginning is not the value.
  for
    policy in [
      SafetyPolicy::permissive(),
      SafetyPolicy::interactive(),
      SafetyPolicy::for_execution(),
      SafetyPolicy::strict(),
    ] {
    let opts = Options::default().with_profile(policy)
    assert_eq(
      opts.skip_prose,
      false,
      msg="profile " + policy.name() + " must not skip prose",
    )
  }
}

///|
test "TC-R-13 the agent profile refuses a lossy repair" {
  // Skipping prose must not soften the profile: the agent profile is the
  // execution profile plus the chat-channel protocol.
  let opts = Options::for_agent()
  let plan = reg_analyze_with("{\"a\":1,\"a\":2}", opts)
  assert_eq(plan.is_executable(), false)
  assert_true(plan.decision == LossyRepair, msg="decision")
}

///|
test "TC-R-13b rounded numeric duplicates are lossy in both safety profiles" {
  for
    (a, b) in [
      ("0", "1e-400"),
      ("1", "0.99999999999999999999"),
      ("9007199254740992", "9007199254740993"),
      ("0", "1e-9999999999"),
      ("1e-9999999999", "2e-9999999999"),
    ] {
    for (x, y) in [(a, b), (b, a)] {
      let input = "{\"n\":" + x + ",\"n\":" + y + "}"
      let permissive = analyze(input)
      assert_true(permissive.exactness == Lossy, msg=input)
      assert_eq(permissive.repairs.length(), 1, msg=input)
      assert_eq(permissive.repairs[0].rule, "R018", msg=input)
      assert_true(permissive.repairs[0].severity == Warning, msg=input)
      for opts in [Options::for_agent(), Options::for_execution()] {
        let plan = analyze(input, options=opts)
        assert_false(plan.is_executable(), msg=input)
        assert_true(plan.decision == LossyRepair, msg=input)
        assert_true(plan.value is None, msg=input)
        assert_eq(plan.error_code, "E010", msg=input)
      }
    }
  }
}

///|
test "TC-R-13c equal numeric spellings stay executable in both safety profiles" {
  for
    (a, b) in [
      ("1", "1.0"),
      ("100", "1e2"),
      ("-0", "0"),
      ("1e-400", "10e-401"),
      ("1e400", "10e399"),
      ("1e-9999999999", "1e-9999999999"),
    ] {
    for opts in [Options::for_agent(), Options::for_execution()] {
      let input = "{\"n\":" + a + ",\"n\":" + b + "}"
      let plan = analyze(input, options=opts)
      assert_true(plan.is_executable(), msg=input)
      assert_true(plan.exactness == Cosmetic, msg=input)
      assert_eq(plan.repairs.length(), 1, msg=input)
      assert_true(plan.repairs[0].severity == Info, msg=input)
    }
  }
}

// ---------------------------------------------------------------------------
// Recursion must be bounded: a declaration is external input.
// ---------------------------------------------------------------------------

///|
test "TC-R-14 a deep declaration is refused, not crashed" {
  let deep = "[".repeat(400) + "]".repeat(400)
  let mut code = ""
  try {
    let _ = Schema::parse(deep)
  } catch {
    e => code = e.code()
  }
  assert_eq(code, "E070")
}

///|
test "TC-R-15 a deep JSON Schema object is refused, not crashed" {
  let deep = "{\"type\":\"array\",\"items\":".repeat(300) +
    "{\"type\":\"string\"}" +
    "}".repeat(300)
  let mut code = ""
  try {
    let _ = Schema::parse_json_schema(deep)
  } catch {
    e => code = e.code()
  }
  assert_eq(code, "E070")
}

///|
test "TC-R-16 a deep value no longer exhausts the stack" {
  // This is the defect the whole depth redesign is about. `max_depth` used to
  // be capped at 512 because four walks were recursive and the wasm stack
  // gives out between 896 and 1024 frames; a caller could tighten the limit
  // but never loosen it. Every walk is iterative now, so a deep value parses,
  // renders, compares and copies without touching the native stack.
  let depth = 5000
  let doc = "[".repeat(depth) + "1" + "]".repeat(depth)
  let plan = analyze(doc, options={ ..Options::default(), max_depth: 100000, })
  assert_eq(plan.is_executable(), true)
  assert_eq(plan.text.length(), depth * 2 + 1)
}

///|
test "TC-R-17 max_depth above the ceiling is an option error" {
  // The ceiling still exists -- a typo should not ask for an allocation the
  // machine cannot make -- but it is now a sanity bound, not a stack bound.
  let plan = analyze("{}", options={
    ..Options::default(),
    max_depth: MAX_VALUE_DEPTH + 1,
  })
  assert_eq(plan.is_executable(), false)
  assert_eq(plan.error_code, "E050")
}

///|
test "TC-R-18 the default depth still refuses what it always refused" {
  // Loosening the ceiling must not loosen the default: a document deeper than
  // the documented 512 is still refused with `E020`.
  let plan = reg_analyze("[".repeat(600) + "]".repeat(600))
  assert_eq(plan.is_executable(), false)
  assert_eq(plan.error_code, "E020")
}

///|
test "TC-R-18b a legitimate nesting is still accepted" {
  let plan = reg_analyze("[".repeat(100) + "]".repeat(100))
  assert_eq(plan.is_executable(), true)
}

// ---------------------------------------------------------------------------
// The walks over a caller-supplied value are iterative, so their depth is
// bounded by the heap rather than by the native stack.
// ---------------------------------------------------------------------------

///|
test "TC-R-19 a deep value survives copy, compare, render and evaluate" {
  // The four walks that used to be recursive, all on one deep value. Before
  // the change each of these was a stack overflow waiting for a caller who
  // built the value themselves.
  let depth = 2000
  let mut v = Json::number(1.0)
  for _i = 0; _i < depth; _i = _i + 1 {
    v = Json::array([v])
  }
  let copy = copy_json(v)
  assert_eq(json_equal(v, copy), true)
  assert_eq(render(v, 0).length(), depth * 2 + 1)
  // The declaration is built, not parsed: the schema *parsers* are still
  // recursive and are still bounded by `MAX_SCHEMA_DEPTH` (TC-R-19c), but a
  // caller that constructs a `Schema` directly is not going through them.
  let mut schema = Schema::Int
  for _i = 0; _i < depth; _i = _i + 1 {
    schema = Schema::Arr(schema)
  }
  let verdict = schema.evaluate(v)
  assert_eq(verdict.ok, true)
}

///|
test "TC-R-19b the copy is independent of the original" {
  // The iterative copy has to be a real copy, not a share: mutating the copy
  // must not touch the source.
  let src = @json.parse("{\"a\":[1,2],\"b\":{\"c\":3}}") catch {
    _ => Json::null()
  }
  let copy = copy_json(src)
  match copy {
    Json::Object(m) =>
      match m.get("a") {
        Some(Json::Array(items)) => items.push(Json::number(9.0))
        _ => assert_true(false, msg="the copy has no array at a")
      }
    _ => assert_true(false, msg="the copy is not an object")
  }
  match src {
    Json::Object(m) =>
      match m.get("a") {
        Some(Json::Array(items)) => assert_eq(items.length(), 2)
        _ => assert_true(false, msg="the source has no array at a")
      }
    _ => assert_true(false, msg="the source is not an object")
  }
}

///|
test "TC-R-19c a declaration is still bounded" {
  // Declarations are parsed by two recursive parsers, so that bound is real
  // and stays: a declaration past `MAX_SCHEMA_DEPTH` is `E070`.
  let deep = "[".repeat(MAX_SCHEMA_DEPTH + 10) +
    "]".repeat(MAX_SCHEMA_DEPTH + 10)
  let mut code = ""
  try {
    let _ = Schema::parse(deep)
  } catch {
    e => code = e.code()
  }
  assert_eq(code, "E070")
}

///|
test "TC-R-20 a nested array mismatch names its path" {
  // The mismatch is reported against the path it was found at, not the root:
  // `[[integer]]` against `[["a"]]` fails at `.0.0`, and a report that says
  // `<root>` sends the caller to the wrong place.
  let schema = Schema::parse("[[integer]]")
  let value = @json.parse("[[\"a\"]]") catch { _ => Json::null() }
  let verdict = schema.evaluate(value)
  assert_eq(verdict.ok, false)
  assert_eq(verdict.mismatched.length(), 1)
  assert_eq(verdict.mismatched[0].path, "0.0")
}

///|
test "TC-R-21 a nested array where an array was expected names its path" {
  // The other half of the walk: the node is not an array at all.
  let schema = Schema::parse("[[integer]]")
  let value = @json.parse("[[1],2]") catch { _ => Json::null() }
  let verdict = schema.evaluate(value)
  assert_eq(verdict.ok, false)
  assert_eq(verdict.mismatched[0].path, "1")
}

///|
test "TC-R-25 syntax readiness samples a prefix with no value yet" {
  // The sampling loop asks the partial parser for a snapshot at every step.
  // Before the first value is complete the snapshot has no value, and that
  // branch has to do nothing rather than stop the search: the answer is the
  // first offset at which the document *already* equals its final value, and
  // an empty prefix is simply not that offset yet.
  //
  // Leading whitespace guarantees at least one such sample: at offset 1 the
  // input is `" "`, which has no value.
  let ready = syntax_readiness_permille("   1", step=1)
  assert_eq(ready, 1000)
  let same = syntax_readiness_permille("   1")
  assert_eq(same, 1000)
}

// ---------------------------------------------------------------------------
// 1.5.2 — exact numbers, Unicode lengths, object closure, and the stream's
// final verdict (`marks/迭代.md` §3.2, §3.3, §4.1, §4.3, §5.3).
// ---------------------------------------------------------------------------

///|
/// `analyze` against a JSON Schema declaration, as the plan object.
fn gate_json_schema(text : String, declaration : String) -> RepairPlan {
  let schema = Schema::parse_json_schema(declaration) catch { _ => Schema::Any }
  analyze(text, options=Options::for_agent(), schema~)
}

///|
test "TC-NUM-01: a bound past 2^53 is compared exactly" {
  // Both values collapse onto the same `Double`; the exact decimal does not.
  let maximum = "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\",\"maximum\":9007199254740992}},\"required\":[\"n\"]}"
  let plan = gate_json_schema("{\"n\":9007199254740993}", maximum)
  assert_eq(plan.decision.name(), "invalid")
  assert_eq(plan.is_executable(), false)
  assert_true(
    plan.error_message.contains("number <= 9007199254740992"),
    msg=plan.error_message,
  )
  // The boundary itself is allowed, on both sides.
  assert_eq(
    gate_json_schema("{\"n\":9007199254740992}", maximum).is_executable(),
    true,
  )
  let minimum = "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\",\"minimum\":9007199254740993}},\"required\":[\"n\"]}"
  assert_eq(
    gate_json_schema("{\"n\":9007199254740992}", minimum).is_executable(),
    false,
  )
  assert_eq(
    gate_json_schema("{\"n\":9007199254740993}", minimum).is_executable(),
    true,
  )
}

///|
test "TC-NUM-02: exponential and negative bounds are exact too" {
  let decl = "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\",\"minimum\":-0.0015}},\"required\":[\"n\"]}"
  assert_eq(gate_json_schema("{\"n\":-1.5e-3}", decl).is_executable(), true)
  assert_eq(gate_json_schema("{\"n\":-0.0016}", decl).is_executable(), false)
  assert_eq(gate_json_schema("{\"n\":-15e-4}", decl).is_executable(), true)
  // A negative bound below zero is not confused with its magnitude.
  let below = "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\",\"maximum\":-1}},\"required\":[\"n\"]}"
  assert_eq(gate_json_schema("{\"n\":-2}", below).is_executable(), true)
  assert_eq(gate_json_schema("{\"n\":0}", below).is_executable(), false)
}

///|
test "TC-NUM-03: an integer past Int32 is an integer" {
  let decl = "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\"}},\"required\":[\"n\"]}"
  for text in ["2147483648", "-2147483649", "9007199254740993", "1e10", "1.0"] {
    let plan = gate_json_schema("{\"n\":" + text + "}", decl)
    assert_eq(
      plan.is_executable(),
      true,
      msg="`" + text + "` should be an integer",
    )
  }
  for text in ["1.5", "1e-1", "0.999999"] {
    let plan = gate_json_schema("{\"n\":" + text + "}", decl)
    assert_eq(
      plan.is_executable(),
      false,
      msg="`" + text + "` is not an integer",
    )
  }
}

///|
test "TC-UNI-01: `minLength` counts code points, not UTF-16 units" {
  let two = "{\"type\":\"object\",\"properties\":{\"s\":{\"type\":\"string\",\"minLength\":2}},\"required\":[\"s\"]}"
  // One emoji is one character, so `minLength:2` refuses it.
  assert_eq(gate_json_schema("{\"s\":\"😀\"}", two).is_executable(), false)
  assert_eq(gate_json_schema("{\"s\":\"😀a\"}", two).is_executable(), true)
  let one = "{\"type\":\"object\",\"properties\":{\"s\":{\"type\":\"string\",\"maxLength\":1}},\"required\":[\"s\"]}"
  assert_eq(gate_json_schema("{\"s\":\"😀\"}", one).is_executable(), true)
  assert_eq(
    gate_json_schema("{\"s\":\"😀😀\"}", one).is_executable(),
    false,
  )
  // A combining mark is its own code point, not a grapheme cluster.
  assert_eq(
    gate_json_schema("{\"s\":\"e\\u0301\"}", one).is_executable(),
    false,
  )
}

///|
test "TC-CLOSE-01: a closed object refuses an undeclared member" {
  let strict = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"],\"additionalProperties\":false}"
  assert_eq(
    gate_json_schema("{\"query\":\"MoonBit\"}", strict).is_executable(),
    true,
  )
  let extra = gate_json_schema("{\"query\":\"MoonBit\",\"x\":1}", strict)
  assert_eq(extra.is_executable(), false)
  assert_true(
    extra.error_message.contains("no member outside"),
    msg=extra.error_message,
  )
  // An open object still admits members: closure is opt-in.
  let open = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}"
  assert_eq(
    gate_json_schema("{\"query\":\"MoonBit\",\"x\":1}", open).is_executable(),
    true,
  )
  // Nested, and inside an array.
  let nested = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"object\",\"properties\":{\"b\":{\"type\":\"integer\"}},\"required\":[\"b\"],\"additionalProperties\":false}},\"required\":[\"a\"],\"additionalProperties\":false}"
  assert_eq(gate_json_schema("{\"a\":{\"b\":1}}", nested).is_executable(), true)
  assert_eq(
    gate_json_schema("{\"a\":{\"b\":1,\"c\":2}}", nested).is_executable(),
    false,
  )
  let array = "{\"type\":\"object\",\"properties\":{\"xs\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"b\":{\"type\":\"integer\"}},\"required\":[\"b\"],\"additionalProperties\":false}}},\"required\":[\"xs\"]}"
  assert_eq(
    gate_json_schema("{\"xs\":[{\"b\":1},{\"b\":2}]}", array).is_executable(),
    true,
  )
  assert_eq(
    gate_json_schema("{\"xs\":[{\"b\":1},{\"b\":2,\"c\":3}]}", array).is_executable(),
    false,
  )
}

///|
/// `finish()`, discarding both the result and a refusal. A test that is about
/// the final verdict of a *rejected* document still has to end the stream, and
/// whether that end raises is another test's subject.
fn ignore_finish(w : SemanticWatcher) -> Unit {
  try w.finish() |> ignore catch {
    _ => ()
  }
}

///|
/// Whether `events` contains an event of `kind`.
fn has_kind(events : Array[ReadinessEvent], kind : String) -> Bool {
  for e in events {
    if e.kind() == kind {
      return true
    }
  }
  false
}

///|
/// How many events of `kind` `events` contains.
fn count_kind(events : Array[ReadinessEvent], kind : String) -> Int32 {
  let mut n = 0
  for e in events {
    if e.kind() == kind {
      n = n + 1
    }
  }
  n
}

///|
test "TC-STREAM-01: a later optional member revokes `RootReady`" {
  let schema = Schema::parse("{!a:string,?b:integer}") catch { _ => Any }
  let w = SemanticWatcher::new(schema, options=Options::for_agent())
  w.feed("{\"a\":\"ok\",")
  let first = w.drain_events()
  assert_true(has_kind(first, "root_ready"), msg="first batch")
  w.feed("\"b\":\"bad\"}")
  let second = w.drain_events()
  ignore_finish(w)
  let last = w.drain_events()
  // The final value does not satisfy the declaration: the one-shot gate refuses
  // it, so the stream has to publish the refusal it owes. It arrives on the
  // delta that closed the root, which is inside the second feed.
  let verdict = schema.evaluate(parse("{\"a\":\"ok\",\"b\":\"bad\"}").value)
  assert_eq(verdict.ok, false)
  assert_true(
    has_kind(second, "root_invalid") || has_kind(last, "root_invalid"),
    msg="no root_invalid after the final value became wrong",
  )
  assert_true(has_kind(second, "root_ready") == false, msg="second batch")
  assert_eq(w.ready_standing(), false)
}

///|
test "TC-STREAM-02: a scalar root's watcher agrees with `analyze`" {
  // The engine's `skip_prose` retry adopts the value it recovered, so the
  // watcher's snapshot sees it too. Before that, `watcher_final.value` was `42`
  // while the event stream said `RootInvalid` (audit 5.3).
  for
    (decl, text) in [
      ("integer", "42"),
      ("string", "\"x\""),
      ("number", "1.5"),
      ("boolean", "true"),
      ("null", "null"),
    ] {
    let schema = Schema::parse(decl) catch { _ => Any }
    let w = SemanticWatcher::new(schema, options=Options::for_agent())
    w.feed(text)
    ignore_finish(w)
    let events = w.drain_events()
    assert_true(has_kind(events, "root_ready"), msg=decl + " " + text)
    let plan = analyze(text, options=Options::for_agent(), schema~)
    assert_eq(plan.is_executable(), true, msg=decl + " " + text)
  }
  // A scalar of the wrong kind is refused by both paths.
  let schema = Schema::parse("integer") catch { _ => Any }
  let w = SemanticWatcher::new(schema, options=Options::for_agent())
  w.feed("\"x\"")
  ignore_finish(w)
  assert_true(has_kind(w.drain_events(), "root_invalid"))
}

///|
test "TC-STREAM-03: the final value decides, whatever was published first" {
  let schema = Schema::parse("{!a:string,?b:integer}") catch { _ => Any }
  // A value that keeps the promise is not re-announced.
  let w = SemanticWatcher::new(schema, options=Options::for_agent())
  w.feed("{\"a\":\"ok\",\"b\":3}")
  ignore_finish(w)
  assert_eq(count_kind(w.drain_events(), "root_ready"), 1)
}

///|
test "TC-LIMIT-01: the quote lookahead cannot exceed the token limit" {
  // The lookahead holds a candidate closing quote and the whitespace after it.
  // Both end up inside the token when the quote turns out not to close the
  // string, so the limit has to cover them (audit 5.4).
  let opts = Options::for_agent()
  let tight = { ..opts, max_token_len: 4, quote_lookahead: true, }
  let code = try {
    ignore(repair("{\"a\":\"x\"   \"}", options=tight))
    "ok"
  } catch {
    e => e.code()
  }
  assert_eq(code, "E022")
  // The same input with room to spare is repaired.
  let room = { ..opts, max_token_len: 64, quote_lookahead: true, }
  let text = repair("{\"a\":\"x\"   \"}", options=room).text
  assert_true(text.contains("x\\\""), msg=text)
}

///|
test "TC-REFUSAL-01: a refusal says whether a retry is safe" {
  // A truncated document is a syntax problem: re-emitting is what a retry loop
  // should do.
  let truncated = analyze("{\"a\":", options=Options::for_agent())
  assert_eq(truncated.is_executable(), false)
  assert_eq(truncated.refusal_kind.name(), "syntax")
  assert_eq(truncated.refusal_kind.auto_retryable(), true)
  // A complete document that conflicts with the declaration is not.
  let schema = Schema::parse("{!mode:string(enum:[\"read\"])}") catch {
    _ => Any
  }
  let conflict = analyze(
    "{\"mode\":\"write\"}",
    options=Options::for_agent(),
    schema~,
  )
  assert_eq(conflict.is_executable(), false)
  assert_eq(conflict.refusal_kind.name(), "schema_or_intent")
  assert_eq(conflict.refusal_kind.auto_retryable(), false)
  // And an accepted plan has no refusal.
  let ok = analyze("{\"mode\":\"read\"}", options=Options::for_agent(), schema~)
  assert_eq(ok.refusal_kind.name(), "none")
}

// ---------------------------------------------------------------------------
// 1.5.2 — the parts of the iteration that only a unit test can pin: the exact
// declaration text of a numeric bound, the closure keyword in both declaration
// languages, and the repair record's single shape.
// ---------------------------------------------------------------------------

///|
test "TC-DECL-01: a numeric bound keeps the text it was written with" {
  // A bound past 2^53 must survive the round trip through the declaration
  // language: `stringify` is the form a host stores and re-reads.
  let s = Schema::parse("number(maximum:9007199254740993)") catch { _ => Any }
  assert_eq(s.stringify(), "number(maximum:9007199254740993)")
  let back = Schema::parse(s.stringify()) catch { _ => Any }
  assert_eq(back.stringify(), "number(maximum:9007199254740993)")
  // The canonical spelling of a bound that has one.
  assert_eq(
    (Schema::parse("number(minimum:1.50)") catch { _ => Any }).stringify(),
    "number(minimum:1.5)",
  )
  // A bound the library cannot compare exactly is a declaration error, not a
  // silently weaker gate.
  assert_eq(parse_code("number(maximum:1e9999999999)"), "E070")
}

///|
test "TC-DECL-02: the closure keyword round trips in both languages" {
  // The skeleton's own spelling.
  let dsl = Schema::parse("{!a:integer}(additionalProperties:false)") catch {
    _ => Any
  }
  assert_eq(dsl.stringify(), "{!a:integer}(additionalProperties:false)")
  assert_eq(dsl.accepts(jv("{\"a\":1}")), true)
  assert_eq(dsl.accepts(jv("{\"a\":1,\"b\":2}")), false)
  // `true` is the default, and writing it is accepted rather than refused.
  assert_eq(
    (Schema::parse("{!a:integer}(additionalProperties:true)") catch {
      _ => Any
    }).stringify(),
    "{!a:integer}",
  )
  // The keyword applies to an object only, and takes a boolean.
  assert_eq(parse_code("string(additionalProperties:false)"), "E070")
  assert_eq(parse_code("{!a:integer}(additionalProperties:maybe)"), "E070")
  // A number text that is not JSON's grammar is named, not coerced.
  assert_eq(parse_code("number(minimum:1.2.3)"), "E070")
  assert_eq(parse_code("number(minimum:--)"), "E070")
}

///|
test "TC-DECL-03: a closed object reports the member it refuses" {
  let s = Schema::parse("{!a:integer}(additionalProperties:false)") catch {
    _ => Any
  }
  let v = s.evaluate(jv("{\"a\":1,\"b\":2}"))
  assert_eq(v.ok, false)
  assert_eq(v.mismatched.length(), 1)
  assert_true(
    v.mismatched[0].expected.contains("no member outside {a}"),
    msg=v.mismatched[0].expected,
  )
  assert_true(
    v.mismatched[0].expected.contains("`b`"),
    msg=v.mismatched[0].expected,
  )
  // An object with no declared members admits only the empty object when closed.
  let empty = Schema::parse("{}(additionalProperties:false)") catch { _ => Any }
  assert_eq(empty.accepts(jv("{}")), true)
  assert_eq(empty.accepts(jv("{\"x\":1}")), false)
}

///|
test "TC-RECORD-01: the repair record has one shape" {
  // `repair_record_fields()` is the list the MCP output schema is written from,
  // and `repair_record_json` is the only writer. A field added to one side and
  // not the other is a schema violation a strict MCP client rejects (audit 3.7).
  let r : Repair = {
    code: RemoveExtraComma,
    position: { offset: 4, line: 1, column: 5, },
    severity: Info,
    message: "extra comma removed",
    ambiguity: Unambiguous,
  }
  let json = repair_record_json(r)
  let fields = repair_record_fields()
  let obj = match json {
    Json::Object(m) => m
    _ => Map([])
  }
  assert_eq(obj.length(), fields.length())
  for f in fields {
    assert_true(obj.contains(f), msg=f)
  }
  // The values are the ones the record says.
  assert_eq(obj["rule"], Json::string("R005"))
  assert_eq(obj["name"], Json::string("RemoveExtraComma"))
  assert_eq(obj["action"], Json::string("remove"))
  assert_eq(obj["severity"], Json::string("info"))
  assert_eq(obj["information_loss"], Json::boolean(false))
  assert_eq(obj["message"], Json::string("extra comma removed"))
}

///|
test "TC-REFUSAL-02: every refusal kind has a name and a retry answer" {
  assert_eq(NoRefusal.name(), "none")
  assert_eq(Syntax.name(), "syntax")
  assert_eq(SchemaOrIntent.name(), "schema_or_intent")
  assert_eq(HostDeclaration.name(), "host_declaration")
  assert_eq(Provider.name(), "provider")
  assert_eq(Syntax.auto_retryable(), true)
  for k in [NoRefusal, SchemaOrIntent, HostDeclaration, Provider] {
    assert_eq(k.auto_retryable(), false, msg=k.name())
  }
}

///|
test "TC-PLAN-01: the plan's JSON carries the refusal kind and the disclaimer" {
  let schema = Schema::parse("{!mode:string(enum:[\"read\"])}") catch {
    _ => Any
  }
  let plan = analyze(
    "{\"mode\":\"write\"}",
    options=Options::for_agent(),
    schema~,
  )
  let json = @json.parse(plan.to_json_with_text(false)) catch {
    _ => Json::null()
  }
  let obj = match json {
    Json::Object(m) => m
    _ => Map([])
  }
  assert_eq(obj["business_authorized"], Json::boolean(false))
  match obj.get("refusal") {
    Some(Json::Object(r)) => {
      assert_eq(r["kind"], Json::string("schema_or_intent"))
      assert_eq(r["auto_retry"], Json::boolean(false))
    }
    _ => fail("the refusal object is missing")
  }
  // An executable plan has no refusal object.
  let ok = analyze("{\"mode\":\"read\"}", options=Options::for_agent(), schema~)
  let ok_json = @json.parse(ok.to_json_with_text(false)) catch {
    _ => Json::null()
  }
  let ok_obj = match ok_json {
    Json::Object(m) => m
    _ => Map([])
  }
  assert_eq(ok_obj.get("refusal").unwrap(), Json::null())
}

///|
test "TC-COV-01: a bound whose exponent is unreadable is refused, not clamped" {
  // `is_json_number_text` walks the exponent; a declaration can reach it with a
  // malformed tail because the token reader is a character run, not a grammar.
  assert_eq(parse_code("number(minimum:1e)"), "E070")
  assert_eq(parse_code("number(minimum:1e+)"), "E070")
  assert_eq(parse_code("number(minimum:1e-)"), "E070")
  // `1.` has no fraction digit. `Dec` reads it as `1`; JSON does not have the
  // spelling, so the declaration is refused.
  assert_eq(parse_code("number(minimum:1.)"), "E070")
  assert_eq(parse_code("number(minimum:1.e5)"), "E070")
  // `01` is not a JSON number either (leading zero); `0`, `0.5` and `1E5` are.
  assert_eq(parse_code("number(minimum:01)"), "E070")
  assert_eq(parse_code("number(minimum:0)"), "ok")
  assert_eq(parse_code("number(minimum:0.5)"), "ok")
  assert_eq(parse_code("number(minimum:1E5)"), "ok")
}

///|
test "TC-COV-02: a JSON Schema bound with no exact value is refused" {
  // `1e9999999999` is a JSON number whose text cannot be normalised into an
  // `Int32` exponent. A bound the gate cannot enforce exactly must not be
  // weakened to a double: the declaration is refused instead.
  assert_eq(js_code("{\"type\":\"number\",\"maximum\":1e9999999999}"), "E070")
  let ok = try {
    ignore(
      Schema::parse_json_schema("{\"type\":\"number\",\"maximum\":1.0e400}"),
    )
    "ok"
  } catch {
    e => e.code()
  }
  assert_eq(ok, "ok")
}

///|
test "TC-COV-03: an unreadable decimal cannot prove the integer kind" {
  // The reader kept a text the decimal type cannot read. The number kind
  // accepts it, but `integer` must refuse rather than trust a rounded Double.
  let v = @json.parse("1e9999999999", preserve_number_repr=true) catch {
    _ => Json::null()
  }
  assert_eq(v.stringify(), "1e9999999999")
  // A value with no bound is not asked to be exactly comparable by the number
  // kind; proving integer-ness still requires an exact decimal.
  let any = Schema::parse("number") catch { _ => Any }
  assert_eq(any.accepts(v), true)
  // `1e400` normalises (its exponent fits), so it *is* a whole number: the
  // value is `1` followed by four hundred zeros.
  let big = @json.parse("1e400", preserve_number_repr=true) catch {
    _ => Json::null()
  }
  let integer = Schema::parse("integer") catch { _ => Any }
  assert_eq(integer.accepts(big), true)
  // An unrepresentable exponent is refused even when the Double underflows
  // to zero, so tiny fractions cannot become integers.
  assert_eq(integer.accepts(v), false)
  for text in ["1e-9999999999", "-1e-9999999999"] {
    let tiny = @json.parse(text, preserve_number_repr=true)
    assert_false(integer.accepts(tiny), msg=text)
    assert_true(any.accepts(tiny), msg=text)
  }
  assert_true(integer.accepts(Json::number(1.0)))
  assert_false(integer.accepts(Json::number(0.0, repr="invalid")))
}

///|
test "TC-COV-04: the member-list spelling of a closed object" {
  // Two names, so the separator branch runs; and a non-object so the empty
  // spelling is used.
  let two = Schema::parse("{!a:integer,!b:integer}(additionalProperties:false)") catch {
    _ => Any
  }
  let v = two.evaluate(jv("{\"a\":1,\"b\":2,\"c\":3}"))
  assert_true(
    v.mismatched[0].expected.contains("{a, b}"),
    msg=v.mismatched[0].expected,
  )
  // A closed declaration whose structure is not an object reports `{}`.
  let weird = Schema::parse("{!a:integer}(additionalProperties:false)") catch {
    _ => Any
  }
  assert_eq(weird.accepts(jv("[1]")), false)
}

///|
test "TC-COV-05: a severity is reported by its protocol word" {
  let warning : Repair = {
    code: FixEscape,
    position: { offset: 0, line: 1, column: 1, },
    severity: Warning,
    message: "escape repaired",
    ambiguity: Unambiguous,
  }
  let json = repair_record_json(warning)
  match json {
    Json::Object(m) => {
      assert_eq(m["severity"], Json::string("warning"))
      assert_eq(m["information_loss"], Json::boolean(true))
    }
    _ => fail("not an object")
  }
}

///|
test "TC-COV-06: the `Ambiguity` spellings have one name each" {
  // `Ambiguity` has an `Eq` that goes through `name()`; both sides of the
  // comparison are exercised so the implementation is not a constant `true`.
  assert_eq(Unambiguous.name(), "unambiguous")
  assert_eq(BareWord.name(), "bare_word")
  assert_eq(AdjacentStrings.name(), "adjacent_strings")
  assert_eq(ConcatOperator.name(), "concat_operator")
  assert_eq(TrailingContent.name(), "trailing_content")
  assert_true(Unambiguous == Unambiguous)
  assert_true(BareWord == BareWord)
  assert_true(!(Unambiguous == BareWord))
}

///|
test "TC-COV-07: the closure and exactness helpers answer `None` where they must" {
  // `undeclared_member` and `declared_names` are only meaningful for an object.
  // A declaration that constrains a container's value and closes it never
  // reaches them with a non-object; the `_` arms are reachable through the
  // public helpers, and a test that never runs them leaves a branch that could
  // silently start returning a wrong answer.
  let closed = Schema::parse("{!a:integer}(additionalProperties:false)") catch {
    _ => Any
  }
  let open = Schema::parse("{!a:integer}") catch { _ => Any }
  // A value of the wrong kind is refused by the kind check before the closure
  // check, and both orders refuse.
  assert_eq(closed.accepts(jv("[1,2]")), false)
  assert_eq(closed.accepts(jv("3")), false)
  assert_eq(open.accepts(jv("[1,2]")), false)
  // `is_integer` on a non-number is `false`, not a panic.
  let integer = Schema::parse("integer") catch { _ => Any }
  assert_eq(integer.accepts(jv("\"1\"")), false)
  assert_eq(integer.accepts(jv("true")), false)
  assert_eq(integer.accepts(jv("null")), false)
  // Two `RefusalKind`s compare by their name, so `Eq` is exercised both ways.
  assert_true(Syntax == Syntax)
  assert_true(!(Syntax == Provider))
}

///|
test "TC-COV-08: an uncomparable value is refused when a bound was declared" {
  // A number whose text cannot be normalised has no exact decimal. With a bound
  // that is a refusal (fail closed); with no bound the kind check is the whole
  // answer.
  let v = @json.parse("1e9999999999", preserve_number_repr=true) catch {
    _ => Json::null()
  }
  let bounded = Schema::parse("number(maximum:1)") catch { _ => Any }
  let verdict = bounded.evaluate(v)
  assert_eq(verdict.ok, false)
  assert_true(
    verdict.mismatched[0].expected.contains("exactly comparable"),
    msg=verdict.mismatched[0].expected,
  )
  // No bound: the same value is accepted by the kind.
  let unbounded = Schema::parse("number") catch { _ => Any }
  assert_eq(unbounded.evaluate(v).ok, true)
}

///|
test "TC-COV-09: the exponent of a declaration's number is read exactly" {
  // The token reader is a character run, so every malformed exponent reaches
  // `is_json_number_text` and must be refused by name rather than coerced.
  for
    text in [
      "number(maximum:1e)", "number(maximum:1e+)", "number(maximum:1e-)", "number(maximum:1.5e)",
      "number(maximum:1.5E+)", "number(maximum:007)",
    ] {
    assert_eq(parse_code(text), "E070", msg=text)
  }
  // And the well-formed ones are accepted, including a signed exponent.
  for
    text in [
      "number(maximum:1e5)", "number(maximum:1E+5)", "number(maximum:1e-5)", "number(maximum:-0)",
      "number(maximum:0.5)",
    ] {
    assert_eq(parse_code(text), "ok", msg=text)
  }
}

///|
test "TC-COV-10: closure is not asked of a value whose kind is already wrong" {
  // The text form refuses `string(additionalProperties:false)`, but the public
  // struct can be built by hand, and the value can be of another kind. Both
  // answer `None` from the closure check: the kind refusal is the answer, and
  // closure must not add a second, misleading one.
  let odd : Schema = Constrained(Str, {
    ..Constraints::none(),
    additional_properties_closed: true,
  })
  assert_eq(odd.accepts(jv("{\"a\":1}")), false)
  // A string satisfies the kind, and closure has nothing to add: a string has
  // no members. The declaration is odd but consistent.
  assert_eq(odd.accepts(jv("\"x\"")), true)
  // An object declaration closed and given a non-object value: the kind check
  // refuses it, and closure is silent.
  let closed = Schema::parse("{!a:integer}(additionalProperties:false)") catch {
    _ => Any
  }
  match closed {
    Constrained(inner, c) => {
      assert_eq(closure_problem(inner, c, jv("[1]")), None)
      assert_eq(closure_problem(inner, c, jv("{\"a\":1}")), None)
      assert_true(closure_problem(inner, c, jv("{\"b\":1}")) is Some(_))
      // And an open declaration is silent about any value.
      assert_eq(
        closure_problem(inner, Constraints::none(), jv("{\"b\":1}")),
        None,
      )
    }
    _ => fail("the declaration is not constrained")
  }
}

///|
test "TC-STREAM-04: a refusal is never revoked by a later duplicate key" {
  // A duplicate key that is repaired by its second value would satisfy the
  // declaration at the root closer. The stream has already told the caller
  // "no" -- the first value was refused at the offset where it arrived -- and
  // a later repair does not turn that refusal into a licence.
  let schema = Schema::parse("{!b:integer}") catch { _ => Any }
  let w = SemanticWatcher::new(schema, options=Options::for_agent())
  // `for_agent` refuses a lossy repair mid-stream, and a duplicate key is one;
  // the watcher's own `feed` re-raises that. The test is about the verdict,
  // so the feed is allowed to refuse.
  let _ = w.feed("{\"b\":\"bad\",") catch { _ => () }
  let first = w.drain_events()
  assert_true(has_kind(first, "field_invalid"), msg="the bad value is reported")
  let _ = w.feed("\"b\":2}") catch { _ => () }
  ignore_finish(w)
  let all = first + w.drain_events()
  assert_true(has_kind(all, "root_invalid"), msg="the refusal stands")
  assert_true(
    !has_kind(all, "root_ready"),
    msg="no execution licence after a refusal",
  )
  assert_eq(w.ready_standing(), false)
}
