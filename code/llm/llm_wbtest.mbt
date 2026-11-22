// FR-23 tests: the provider adapters must route fragments to the right call and
// the streamed result must be byte identical to repairing the accumulated
// argument text in one shot.

///|
/// Feed every line of an embedded fixture, then finish.
fn fx_play(
  provider : Provider,
  fixture : String,
) -> ToolStream raise @liwenjson.LIWENJSONError {
  let s = ToolStream::new(provider)
  for line in fx_lines(fixture) {
    ignore(s.push_event(line))
  }
  ignore(s.finish())
  s
}

///|
/// Check every expected call of a fixture against the finished stream.
fn fx_expect(
  s : ToolStream,
  calls : Array[(Int32, String, String)],
) -> Unit raise {
  let views = s.finish()
  assert_eq(views.length(), calls.length())
  for i = 0; i < calls.length(); i = i + 1 {
    let (index, name, args) = calls[i]
    let v = views[i]
    assert_eq(v.index, index)
    assert_eq(v.name, name)
    assert_eq(v.done, true)
    assert_eq(s.arguments(index), args)
    if args.length() == 0 {
      // A finished no-argument call is the empty object, not `null`.
      assert_eq(v.snapshot.value.unwrap().stringify(), "{}")
      assert_eq(v.exactness.name(), "exact")
      assert_eq(v.is_executable(), true)
    } else {
      // The streamed value equals repairing the accumulated text in one shot.
      let once = @liwenjson.parse(args)
      assert_eq(v.snapshot.value.unwrap().stringify(), once.value.stringify())
      assert_eq(v.exactness.name(), once.exactness.name())
      assert_eq(v.snapshot.completeness is @liwenjson.Complete, true)
    }
  }
}

///|
/// Run a fixture and check it, reporting a raised error as a failure message.
fn fx_case(
  provider : Provider,
  fixture : String,
  calls : Array[(Int32, String, String)],
) -> Unit raise {
  let err = try {
    fx_expect(fx_play(provider, fixture), calls)
    ""
  } catch {
    e => e.to_string()
  }
  assert_eq(err, "")
}

///|
test "anthropic: a single tool call split into fragments" {
  fx_case(Anthropic, fx_anthropic_single, fx_anthropic_single_calls)
}

///|
test "anthropic: a split inside an escape and inside a surrogate pair" {
  fx_case(Anthropic, fx_anthropic_escape_split, fx_anthropic_escape_split_calls)
  // The decoded value must be the emoji, not a replacement character.
  let s = Some(fx_play(Anthropic, fx_anthropic_escape_split)) catch {
    _ => None
  }
  match s {
    Some(stream) =>
      assert_eq(
        stream.finish()[0].snapshot.value.unwrap().stringify(),
        "{\"note\":\"caf\u00e9 \u{1F600} done\"}",
      )
    None => assert_true(false, msg="fixture raised")
  }
}

///|
test "anthropic: three interleaved tool calls" {
  fx_case(Anthropic, fx_anthropic_parallel, fx_anthropic_parallel_calls)
}

///|
test "anthropic: a mixed stream ignores text and message events" {
  fx_case(Anthropic, fx_anthropic_mixed, fx_anthropic_mixed_calls)
}

///|
test "anthropic: a truncated call is closed and marked lossy" {
  fx_case(Anthropic, fx_anthropic_truncated, fx_anthropic_truncated_calls)
  let s = fx_play(Anthropic, fx_anthropic_truncated)
  // The arguments never finished, so the repair invented the closing brace.
  assert_eq(s.views()[0].exactness.name(), "lossy")
}

///|
test "openai: a single tool call split into fragments" {
  fx_case(OpenAICompat, fx_openai_single, fx_openai_single_calls)
}

///|
test "openai: two interleaved tool calls" {
  fx_case(OpenAICompat, fx_openai_parallel, fx_openai_parallel_calls)
}

///|
test "openai: a length limited call is closed and marked lossy" {
  fx_case(OpenAICompat, fx_openai_truncated, fx_openai_truncated_calls)
  let s = fx_play(OpenAICompat, fx_openai_truncated)
  assert_eq(s.views()[0].exactness.name(), "lossy")
}

///|
test "openai: a call whose arguments never arrive" {
  fx_case(OpenAICompat, fx_openai_name_only, fx_openai_name_only_calls)
}

///|
test "views are available while the call is still being written" {
  let s = ToolStream::new(Anthropic)
  ignore(
    s.push_event(
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"f\",\"input\":{}}}",
    ),
  )
  let mid = s.push_event(
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":\\\"x\"}}",
  )
  assert_eq(mid.length(), 1)
  assert_eq(mid[0].done, false)
  // The value is visible while it is still being written ...
  assert_eq(mid[0].snapshot.value.unwrap().stringify(), "{\"a\":\"x\"}")
  assert_eq(mid[0].snapshot.completeness is @liwenjson.Partial, true)
  // ... and the exactness only moves once a repair has actually happened.
  assert_eq(mid[0].exactness.name(), "exact")
  let mid2 = s.push_event(
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\",}\"}}",
  )
  assert_eq(mid2[0].snapshot.value.unwrap().stringify(), "{\"a\":\"x\"}")
  assert_eq(mid2[0].exactness.name(), "cosmetic")
  // Before any fragment the call is known by name only.
  let only = s.views()
  assert_eq(only.length(), 1)
  assert_eq(only[0].name, "f")
}

///|
test "a malformed event payload raises E060" {
  let s = ToolStream::new(Anthropic)
  let msg = try {
    ignore(s.push_event("{\"type\":"))
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(msg.contains("E060"), msg~)
  // An event that is valid JSON but not an event of the provider is ignored.
  let views = s.push_event("{\"type\":\"ping\"}")
  assert_eq(views.length(), 0)
  // A chunk that names itself as a Chat Completions chunk but carries no
  // `choices` is not readable, and saying so is what stops a wrong-provider
  // stream from becoming "no tool calls" (audit 3.5).
  let s2 = ToolStream::new(OpenAICompat)
  let wrong = try {
    ignore(s2.push_event("{\"id\":\"x\"}"))
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(wrong.contains("E060"), msg=wrong)
  // A payload that is neither is ignored, as before.
  assert_eq(s2.push_event("{\"ping\":true}").length(), 0)
}

///|
test "the adapters never require the network" {
  // A stream is usable from a string alone, which is what makes it testable.
  let s = ToolStream::new(OpenAICompat)
  ignore(
    s.push_event(
      "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"f\",\"arguments\":\"[1,\"}}]}}]}",
    ),
  )
  let views = s.finish()
  assert_eq(views[0].snapshot.value.unwrap().stringify(), "[1]")
}

///|
test "sse reader splits a stream into event payloads" {
  let b = SseBuffer::new()
  let out : Array[String] = []
  for
    piece in [
      "event: content_block_delta\ndata: {\"a\":", "1}\n\ndata: [2]\n\n: comment\n",
    ] {
    for e in b.push(piece) {
      out.push(e)
    }
  }
  assert_eq(out.length(), 2)
  assert_eq(out[0], "{\"a\":1}")
  assert_eq(out[1], "[2]")
}

///|
test "sse reader handles CRLF, multi line data and a cut inside a line" {
  let b = SseBuffer::new()
  let out : Array[String] = []
  for e in b.push("data: one\r\ndata: two\r\n\r\n") {
    out.push(e)
  }
  for e in b.push("data: thr") {
    out.push(e)
  }
  for e in b.push("ee\n") {
    out.push(e)
  }
  for e in b.flush() {
    out.push(e)
  }
  assert_eq(out.length(), 2)
  assert_eq(out[0], "one\ntwo")
  assert_eq(out[1], "three")
  assert_eq(sse_data("data: x"), Some("x"))
  assert_eq(sse_data("data:x"), Some("x"))
  assert_eq(sse_data("event: x"), None)
}

///|
test "an sse wrapped fixture drives the adapter" {
  let s = ToolStream::new(Anthropic)
  let b = SseBuffer::new()
  let lines = fx_lines(fx_anthropic_parallel)
  for line in lines {
    for payload in b.push("event: message\ndata: " + line + "\n\n") {
      ignore(s.push_event(payload))
    }
  }
  fx_expect(s, fx_anthropic_parallel_calls)
}

///|
test "json helpers read the event envelope" {
  let v = @json.parse("{\"i\":3,\"s\":\"x\",\"a\":[1],\"o\":{\"k\":true}}")
  assert_eq(as_int(field(v, "i").unwrap()), Some(3))
  assert_eq(as_string(field(v, "s").unwrap()), Some("x"))
  assert_eq(as_array(field(v, "a").unwrap()).unwrap().length(), 1)
  assert_eq(as_object(field(v, "o").unwrap()).unwrap().length(), 1)
  assert_eq(field_string(v, "s"), Some("x"))
  assert_eq(field_int(v, "i"), Some(3))
  assert_eq(field_int(v, "s"), None)
  assert_eq(field(v, "missing"), None)
  assert_eq(as_int(Json::string("x")), None)
  assert_eq(as_string(Json::number(1.0)), None)
  assert_eq(as_array(Json::null()), None)
  assert_eq(as_object(Json::null()), None)
  assert_eq(field(Json::null(), "k"), None)
}

///|
test "anthropic edge cases" {
  // A block that is not a tool call is ignored.
  let s = ToolStream::new(Anthropic)
  assert_eq(
    s
    .push_event(
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    )
    .length(),
    0,
  )
  // A delta of the wrong kind is ignored.
  assert_eq(
    s
    .push_event(
      "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}",
    )
    .length(),
    0,
  )
  // A stop for an index that was never seen is ignored.
  assert_eq(
    s.push_event("{\"type\":\"content_block_stop\",\"index\":7}").length(),
    0,
  )
  // A start whose `input` is already populated feeds it as the first fragment.
  let v = s.push_event(
    "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t2\",\"name\":\"f\",\"input\":{\"a\":1}}}",
  )
  assert_eq(v.length(), 1)
  assert_eq(v[0].snapshot.value.unwrap().stringify(), "{\"a\":1}")
  // An event with no type at all is ignored.
  assert_eq(s.push_event("{}").length(), 0)
}

///|
test "openai edge cases" {
  let s = ToolStream::new(OpenAICompat)
  // A choice without a delta is ignored.
  assert_eq(s.push_event("{\"choices\":[{\"index\":0}]}").length(), 0)
  // `arguments: null` is ignored, the name is still recorded.
  let v = s.push_event(
    "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"f\",\"arguments\":null}}]}}]}",
  )
  assert_eq(v.length(), 1)
  assert_eq(v[0].name, "f")
  // A later name never overwrites the first one.
  ignore(
    s.push_event(
      "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"x\",\"function\":{\"name\":\"g\"}}]}}]}",
    ),
  )
  assert_eq(s.views()[0].name, "f")
  assert_eq(s.views()[0].id, "x")
}

///|
test "sse flush dispatches a final line without a terminator" {
  let b = SseBuffer::new()
  let out = b.push("data: tail")
  assert_eq(out.length(), 0)
  assert_eq(b.flush(), ["tail"])
  assert_eq(b.flush().length(), 0)
}

// P1-08: an index must be a whole `Int32`, and a text stream belongs to one
// choice. Both were source-confirmed: `0.5` was truncated to 0 by `to_int()`
// and merged a malformed call into a real one, and the last non-empty
// `choices[].delta.content` of a frame won, so the other texts were lost.

///|
test "a malformed index is E060, never a silent cast" {
  // The JSON helper tells "absent" (None) from "present but not an integer".
  assert_eq(as_int(Json::number(0.5)), None)
  assert_eq(as_int(Json::number(2147483648.0)), None)
  assert_eq(as_int(Json::number(-2147483649.0)), None)
  assert_eq(as_int(Json::number(1000.0)), Some(1000))
  assert_eq(as_int(Json::number(-3.0)), Some(-3))
  let absent = field_index(Json::null(), "index") catch { _ => Some(-1) }
  assert_eq(absent, None)
  // Anthropic: `0.5` and `"0"` are errors; a missing index keeps the
  // documented default of 0 and still routes the fragment.
  let a = ToolStream::new(Anthropic)
  for
    bad in [
      "{\"type\":\"content_block_delta\",\"index\":0.5,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":1}\"}}",
      "{\"type\":\"content_block_delta\",\"index\":\"0\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}",
      "{\"type\":\"content_block_stop\",\"index\":1.5}",
    ] {
    let msg = try {
      ignore(a.push_event(bad))
      ""
    } catch {
      e => e.to_string()
    }
    assert_true(msg.contains("E060"), msg=bad + " => " + msg)
  }
  let ok = a.push_event(
    "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":1}\"}}",
  )
  assert_eq(ok.length(), 1)
  assert_eq(ok[0].snapshot.value.unwrap().stringify(), "{\"a\":1}")
  // OpenAI: the choice index and the tool-call index are checked the same way.
  let o = ToolStream::new(OpenAICompat)
  for
    bad in [
      "{\"choices\":[{\"index\":1.5,\"delta\":{\"content\":\"x\"}}]}", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0.5,\"function\":{\"name\":\"f\"}}]}}]}",
    ] {
    let msg = try {
      ignore(o.push_event(bad))
      ""
    } catch {
      e => e.to_string()
    }
    assert_true(msg.contains("E060"), msg=bad + " => " + msg)
  }
}

///|
test "a text stream refuses a second choice instead of losing one" {
  // Switching choice between frames is refused.
  let s = TextStream::new(OpenAICompat)
  let first = s.push_event(
    "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"{\\\"a\\\":\"}}]}",
  )
  assert_true(first is Some(_))
  let switched = try {
    ignore(
      s.push_event(
        "{\"choices\":[{\"index\":1,\"delta\":{\"content\":\"1}\"}}]}",
      ),
    )
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(switched.contains("E060"), msg=switched)
  // Two choices carrying text in one frame are refused as well.
  let t = TextStream::new(OpenAICompat)
  let both = try {
    ignore(
      t.push_event(
        "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\"}},{\"index\":1,\"delta\":{\"content\":\"b\"}}]}",
      ),
    )
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(both.contains("E060"), msg=both)
  // A one-choice stream still parses across frames, and its second choice's
  // absence is not an error.
  let u = TextStream::new(OpenAICompat)
  ignore(
    u.push_event(
      "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"{\\\"a\\\":\"}}]}",
    ),
  )
  ignore(
    u.push_event("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"1}\"}}]}"),
  )
  ignore(
    u.push_event(
      "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}",
    ),
  )
  let r = u.finish().unwrap()
  assert_eq(r.value.stringify(), "{\"a\":1}")
  assert_eq(u.end() is Complete, true)
}

///|
test "text finish preserves strict and render errors without changing the provider end" {
  let base = @liwenjson.Options::for_llm()
  for
    (options, text, code) in [
      ({ ..base, mode: @liwenjson.Strict, }, "{\"a\":1", "E010"),
      ({ ..base, max_output_len: 4, }, "{\"a\":1}", "E023"),
    ] {
    let s = TextStream::new(OpenAICompat, options~)
    ignore(
      s.push_event(
        "{\"choices\":[{\"delta\":{\"content\":" +
        Json::string(text).stringify() +
        "},\"finish_reason\":\"stop\"}]}",
      ),
    )
    assert_true(s.finish() is None)
    assert_eq(s.finish_error().unwrap().code(), code)
    assert_true(s.error().contains(code))
    assert_true(s.end() is Complete)
    assert_eq(s.stop_reason(), "stop")
    // A retry must not replace the original error with E030 InvalidState.
    assert_true(s.finish() is None)
    assert_eq(s.finish_error().unwrap().code(), code)
  }
}

///|
test "text finish reports prose parse failure rather than a successful null" {
  let options = { ..@liwenjson.Options::for_llm(), skip_prose: true, }
  let s = TextStream::new(OpenAICompat, options~)
  ignore(
    s.push_event(
      "{\"choices\":[{\"delta\":{\"content\":\"No JSON here.\"},\"finish_reason\":\"stop\"}]}",
    ),
  )
  assert_true(s.finish() is None)
  assert_eq(s.finish_error().unwrap().code(), "E002")
  assert_true(s.error().contains("E002"))
  assert_true(s.end() is Complete)
}

///|
test "text finish distinguishes no text from a missing provider terminator" {
  for (reason, end) in [("", Interrupted), ("stop", Complete)] {
    let s = TextStream::new(OpenAICompat)
    ignore(
      s.push_event(
        "{\"choices\":[{\"delta\":{\"content\":\"\"},\"finish_reason\":" +
        Json::string(reason).stringify() +
        "}]}",
      ),
    )
    assert_true(s.finish() is None)
    assert_true(s.finish_error() is None)
    assert_eq(s.error(), "")
    assert_true(s.end() == end)
    assert_eq(s.stop_reason(), reason)
  }
}

///|
test "text finish accepts valid JSON including null and marks unterminated streams interrupted" {
  for
    (text, reason, end) in [
      ("{\"a\":1}", "stop", Complete),
      ("null", "stop", Complete),
      ("{\"a\":1}", "", Interrupted),
    ] {
    let s = TextStream::new(OpenAICompat)
    ignore(
      s.push_event(
        "{\"choices\":[{\"delta\":{\"content\":" +
        Json::string(text).stringify() +
        "},\"finish_reason\":" +
        Json::string(reason).stringify() +
        "}]}",
      ),
    )
    let r = s.finish().unwrap()
    assert_eq(r.value.stringify(), text)
    assert_true(r.exactness is @liwenjson.Exact)
    assert_true(s.finish_error() is None)
    assert_eq(s.error(), "")
    assert_true(s.end() == end)
  }
}

///|
test "anthropic direct input preserves exact numeric text" {
  for
    number in ["0.99999999999999999999", "1e-400", "1e400", "9007199254740993"] {
    let s = ToolStream::new(Anthropic)
    ignore(
      s.push_event(
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"n\",\"name\":\"f\",\"input\":{\"amount\":" +
        number +
        "}}}",
      ),
    )
    ignore(s.push_event("{\"type\":\"content_block_stop\",\"index\":0}"))
    let view = s.finish()[0]
    assert_true(view.is_executable())
    assert_eq(
      view.snapshot.value.unwrap().stringify(),
      "{\"amount\":" + number + "}",
    )
    assert_eq(s.arguments(0), "{\"amount\":" + number + "}")
  }
}
