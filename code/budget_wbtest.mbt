// 1120 P2-01 — the rendered-output budget (E023) and the indent bound.
//
// The render path used to be unbounded: `indent` only had to be non-negative,
// and `depth * indent` plus the accumulated text were both unchecked. A legal
// document could therefore ask for a gigabyte and get it, or overflow Int32.
// The budget is counted incrementally while rendering, in UTF-8 bytes, and a
// crossing is refused with `E023` at the point it happens.

///|
/// JSON value from text; a parse error becomes `null` so the test can continue.
fn budget_json(text : String) -> Json {
  @json.parse(text) catch {
    _ => Json::null()
  }
}

///|
/// The limit of the `E023` a render refuses with, or `-1` for another error.
fn e023_limit(v : Json, indent : Int32, limit : Int32) -> Int32 {
  try {
    ignore(render_checked(v, indent, limit))
    -1
  } catch {
    OutputLimit(l) => l
    _ => -2
  }
}

///|
test "the output budget counts UTF-8 bytes and refuses E023 midway" {
  // `render(v, 0)` is the compact form: `{"a":1}` is 7 bytes.
  let v = budget_json("{\"a\":1}")
  assert_eq(render(v, 0), "{\"a\":1}")
  assert_eq(utf8_byte_len(render(v, 0)), 7)
  // Exactly the budget is allowed; one byte under is refused.
  assert_eq(render_checked(v, 0, 7) catch { _ => "" }, "{\"a\":1}")
  assert_eq(e023_limit(v, 0, 6), 6)
  // The error is E023 with a fixed English message that names the limit.
  assert_eq(OutputLimit(6).code(), "E023")
  assert_eq(
    OutputLimit(6).to_string(),
    "E023 OutputLimit: rendered output exceeds 6 bytes",
  )
  // A non-ASCII character costs its UTF-8 width (`é` is 2 bytes), not one
  // UTF-16 code unit: `"é"` with its quotes is 4 bytes.
  let s = Json::string("é")
  assert_eq(render(s, 0), "\"é\"")
  assert_eq(utf8_byte_len(render(s, 0)), 4)
  assert_eq(render_checked(s, 0, 4) catch { _ => "" }, "\"é\"")
  assert_eq(e023_limit(s, 0, 3), 3)
  // An escaped control character is counted in its JSON form (`\n` is two
  // bytes), which is the size the caller actually receives.
  let nl = Json::string("\n")
  assert_eq(render(nl, 0), "\"\\n\"")
  assert_eq(utf8_byte_len(render(nl, 0)), 4)
  assert_eq(render_checked(nl, 0, 4) catch { _ => "" }, "\"\\n\"")
}

///|
test "the indent budget is refused during rendering, not after" {
  // Depth 4000 with indent 64 is the ~1 GB render from the audit. It must be
  // refused from the budget check, without building the padding first.
  let mut v = Json::number(1.0)
  for _i = 0; _i < 4_000; _i = _i + 1 {
    v = Json::array([v])
  }
  assert_eq(e023_limit(v, 64, 1_024), 1_024)
  // The same budget through the public API: `parse` renders the repaired text,
  // so the finish path must surface E023 rather than allocate.
  let sb = StringBuilder()
  for _i = 0; _i < 4_000; _i = _i + 1 {
    sb.write_char('[')
  }
  for _i = 0; _i < 4_000; _i = _i + 1 {
    sb.write_char(']')
  }
  let opts : Options = {
    ..Options::default(),
    max_depth: 8_192,
    indent: 64,
    max_output_len: 1_024,
  }
  let via_parse = try {
    ignore(parse(sb.to_string(), options=opts))
    -1
  } catch {
    OutputLimit(l) => l
    _ => -2
  }
  assert_eq(via_parse, 1_024)
  // A within-budget render is still produced normally.
  let small = parse("{\"a\":1}", options={
    ..Options::default(),
    max_output_len: 64,
  }) catch {
    _ => return assert_true(false, msg="within-budget parse failed")
  }
  assert_eq(small.value.stringify(), "{\"a\":1}")
}

///|
test "option validation refuses an unusable budget or indent" {
  let defaults = Options::default()
  assert_eq(defaults.max_output_len, 67_108_864)
  assert_eq(MAX_INDENT, 64)
  assert_eq(MAX_SCHEMA_WALK_DEPTH, 1_048_576)
  assert_eq(MAX_SCHEMA_WALK_NODES, 4_194_304)
  // The boundary itself is legal for both knobs.
  let at_boundary : Options = {
    ..Options::default(),
    max_output_len: 1,
    indent: MAX_INDENT,
  }
  at_boundary.validate() catch {
    _ => return assert_true(false, msg="the boundary must validate")
  }
  // A zero or negative budget is a configuration error (E050), not a stream
  // that renders nothing.
  for bad in [0, -1] {
    let opts : Options = { ..Options::default(), max_output_len: bad, }
    let msg = try {
      opts.validate()
      "ok"
    } catch {
      InvalidOption(m) => m
      _ => "other"
    }
    assert_eq(msg, "max_output_len must be a positive integer")
  }
  // The indent bound is the CLI's 0..64; the library used to accept any
  // non-negative value and then render it.
  for bad in [-1, MAX_INDENT + 1, 10_000] {
    let opts : Options = { ..Options::default(), indent: bad, }
    let msg = try {
      opts.validate()
      "ok"
    } catch {
      InvalidOption(m) => m
      _ => "other"
    }
    assert_true(msg != "ok", msg=bad.to_string())
  }
  let indent_msg = try {
    let opts : Options = { ..Options::default(), indent: MAX_INDENT + 1, }
    opts.validate()
    "ok"
  } catch {
    InvalidOption(m) => m
    _ => "other"
  }
  assert_true(
    indent_msg.contains("0..64"),
    msg="the message should name the range: " + indent_msg,
  )
  // Both refusals are E050.
  assert_eq(InvalidOption("x").code(), "E050")
}
