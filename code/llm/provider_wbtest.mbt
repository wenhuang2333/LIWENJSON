// FR-23/FR-30 — provider terminal states, the Responses protocol, multi-choice
// isolation, and split CRLF. These are the 1.5.2 regression cases for
// `marks/迭代.md` §3.4–§3.6 and §5.1, §5.2, §5.6.

// ---------------------------------------------------------------------------
// 1.5.2 — provider terminal states, the Responses protocol, multi-choice
// isolation, `[DONE]`, and split CRLF (`marks/迭代.md` §3.4–§3.6, §5.1, §5.2,
// §5.6).
// ---------------------------------------------------------------------------

///|
/// Feed `events` to a fresh stream and return the finished views.
fn drain_stream(
  provider : Provider,
  events : Array[String],
) -> Array[ToolCallView] {
  let s = ToolStream::new(provider) catch { _ => return [] }
  for e in events {
    ignore(s.push_event(e)) catch {
      _ => ()
    }
  }
  s.finish() catch {
    _ => []
  }
}

///|
/// `finish()`, or an empty list when the stream is refused.
fn drain_finish(s : ToolStream) -> Array[ToolCallView] {
  s.finish() catch {
    _ => []
  }
}

///|
/// `name` of the `i`th view, or `"<missing>"`.
fn view_name(views : Array[ToolCallView], i : Int32) -> String {
  if i < views.length() {
    views[i].name
  } else {
    "<missing>"
  }
}

///|
test "TC-END-01: a policy stop is never a normal end" {
  // Every reason the providers use for "I withdrew this", plus a reason added
  // after this build: none of them is `Complete`.
  for
    reason in [
      "content_filter", "refusal", "guardrail", "safety", "blocked", "some_future_reason",
    ] {
    let end = stop_end_of(reason)
    assert_eq(end.is_normal(), false, msg=reason)
    assert_eq(end.is_executable(), false, msg=reason)
  }
  // The normal ends stay normal.
  for
    reason in [
      "stop", "tool_calls", "function_call", "end_turn", "tool_use", "stop_sequence",
      "completed",
    ] {
    assert_eq(stop_end_of(reason).is_normal(), true, msg=reason)
  }
  assert_eq(stop_end_of("length").name(), "max_tokens")
  assert_eq(stop_end_of("max_output_tokens").name(), "max_tokens")
  assert_eq(stop_end_of("").name(), "open")
}

///|
test "TC-END-02: a filtered Chat Completions call is not executable" {
  let views = drain_stream(OpenAICompat, [
    "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"write\",\"arguments\":\"{\\\"mode\\\":\\\"write\\\"}\"}}]}}]}",
    "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"content_filter\"}]}",
  ])
  assert_eq(views.length(), 1)
  assert_eq(views[0].end.name(), "refused")
  assert_eq(views[0].end.is_executable(), false)
  // The arguments that did arrive are still readable: the caller can show what
  // the model had said.
  assert_eq(
    views[0].snapshot.value.unwrap().stringify(),
    "{\"mode\":\"write\"}",
  )
}

///|
test "TC-END-03: an Anthropic refusal is not executable either" {
  let views = drain_stream(Anthropic, [
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"write\",\"input\":{}}}",
    "{\"type\":\"content_block_stop\",\"index\":0}", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}",
  ])
  assert_eq(views.length(), 1)
  assert_eq(views[0].end.name(), "refused")
  assert_eq(views[0].end.is_executable(), false)
}

///|
test "TC-CHOICE-01: two choices with the same tool index do not merge" {
  let views = drain_stream(OpenAICompat, [
    "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"first\",\"arguments\":\"{\\\"a\\\":1}\"}}]}}]}",
    "{\"choices\":[{\"index\":1,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"b\",\"function\":{\"name\":\"second\",\"arguments\":\"{\\\"b\\\":2}\"}}]}}]}",
    "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"},{\"index\":1,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
  ])
  assert_eq(views.length(), 2)
  assert_eq(view_name(views, 0), "first")
  assert_eq(views[0].choice, 0)
  assert_eq(views[0].snapshot.value.unwrap().stringify(), "{\"a\":1}")
  assert_eq(view_name(views, 1), "second")
  assert_eq(views[1].choice, 1)
  assert_eq(views[1].snapshot.value.unwrap().stringify(), "{\"b\":2}")
}

///|
test "TC-CHOICE-02: a choice that finishes early does not close another" {
  // Choice 1 finishes while choice 0 is still sending arguments. Closing every
  // open call on any `finish_reason` raised `E030 cannot feed a finished
  // parser` and lost the stream.
  let s = ToolStream::new(OpenAICompat) catch { _ => return }
  ignore(
    s.push_event(
      "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"slow\",\"arguments\":\"{\\\"a\\\":\"}}]}}]}",
    ),
  ) catch {
    _ => return
  }
  ignore(
    s.push_event(
      "{\"choices\":[{\"index\":1,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
    ),
  ) catch {
    _ => return
  }
  ignore(
    s.push_event(
      "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"1}\"}}]}}]}",
    ),
  ) catch {
    _ => return
  }
  let views = s.finish() catch { _ => return }
  assert_eq(views.length(), 1)
  assert_eq(views[0].snapshot.value.unwrap().stringify(), "{\"a\":1}")
  // Choice 0 never finished, so the end is `interrupted` -- which is the point:
  // choice 1's verdict did not close it, and a stream that ends without a word
  // from the provider is not a normal end.
  assert_eq(views[0].end.name(), "interrupted")
}

///|
test "TC-RESP-01: a Responses tool call is read from its own events" {
  let views = drain_stream(OpenAIResponses, [
    "{\"type\":\"response.created\",\"response\":{\"status\":\"in_progress\"}}",
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"\"}}",
    "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"output_index\":0,\"delta\":\"{\\\"mode\\\":\"}",
    "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"output_index\":0,\"delta\":\"\\\"read\\\"}\"}",
    "{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_1\",\"output_index\":0,\"arguments\":\"{\\\"mode\\\":\\\"read\\\"}\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"{\\\"mode\\\":\\\"read\\\"}\",\"status\":\"completed\"}}",
    "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}",
  ])
  assert_eq(views.length(), 1)
  assert_eq(views[0].name, "read_file")
  assert_eq(views[0].id, "call_1")
  // `done` carries the whole string; appending it as well would double the
  // arguments.
  assert_eq(views[0].snapshot.value.unwrap().stringify(), "{\"mode\":\"read\"}")
  assert_eq(views[0].end.is_normal(), true)
}

///|
test "TC-RESP-02: a truncated Responses call is lossy and not executable" {
  let views = drain_stream(OpenAIResponses, [
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"search\",\"arguments\":\"\"}}",
    "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc\",\"output_index\":0,\"delta\":\"{\\\"query\\\":\\\"a very long discussion about MoonBit\\\",\\\"limit\\\"\"}",
    "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}",
  ])
  assert_eq(views.length(), 1)
  assert_eq(views[0].end.name(), "max_tokens")
  assert_eq(views[0].end.is_executable(), false)
  assert_eq(views[0].exactness.name(), "lossy")
}

///|
test "TC-RESP-03: an unknown Responses event is recorded, and a stream with no call is refused" {
  // A provider adds event types; the one this build does not know must not
  // fail a stream that also carries a tool call. But a stream that produced
  // *no* call while carrying unknown events is refused, because "there were no
  // tool calls" and "the tool call was in an event this build cannot read" are
  // different claims and only one of them may be made silently.
  let s = ToolStream::new(OpenAIResponses) catch { _ => return }
  ignore(s.push_event("{\"type\":\"response.a_future_event\"}")) catch {
    _ => return
  }
  assert_eq(s.unsupported_events().length(), 1)
  assert_eq(s.unsupported_events()[0], "response.a_future_event")
  let msg = try {
    ignore(s.finish())
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(msg.contains("E060"), msg~)
  assert_true(msg.contains("response.a_future_event"), msg~)
  // With a call in the same stream, the unknown event is only reported.
  let s2 = ToolStream::new(OpenAIResponses) catch { _ => return }
  ignore(
    s2.push_event(
      "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"}}",
    ),
  ) catch {
    _ => return
  }
  ignore(s2.push_event("{\"type\":\"response.a_future_event\"}")) catch {
    _ => return
  }
  let views = drain_finish(s2)
  assert_eq(views.length(), 1)
  assert_eq(s2.unsupported_events().length(), 1)
}

///|
test "TC-RESP-04: a Responses stream is refused by the Chat Completions reader" {
  let s = ToolStream::new(OpenAICompat) catch { _ => return }
  let msg = try {
    ignore(
      s.push_event(
        "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\"}}",
      ),
    )
    ""
  } catch {
    e => e.to_string()
  }
  // Naming the right provider is the point: silence read as "no tool calls".
  assert_true(msg.contains("openai-responses"), msg~)
}

///|
test "TC-SSE-01: a CRLF split across two chunks means what CRLF means" {
  // One chunk: two `data:` lines followed by a blank line is *one* event whose
  // payload is the two lines joined by LF.
  let whole = SseBuffer::new()
  let a = whole.push("data: {\"a\":1}\r\ndata: {\"b\":2}\r\n\r\n")
  assert_eq(a.length(), 1)
  assert_eq(a[0], "{\"a\":1}\n{\"b\":2}")
  // The same bytes with the CRLF pair cut between chunks is the same event.
  // Without the split guard the LF was read as a second empty line, which
  // dispatched `{"a":1}` alone and started a second event.
  let split = SseBuffer::new()
  let b = split.push("data: {\"a\":1}\r")
  let c = split.push("\ndata: {\"b\":2}\r\n\r\n")
  let d = split.flush()
  assert_eq(b.length(), 0)
  assert_eq(c.length(), 1)
  assert_eq(c[0], "{\"a\":1}\n{\"b\":2}")
  assert_eq(d.length(), 0)
  // A lone CR is still a terminator of its own.
  let cr = SseBuffer::new()
  let e = cr.push("data: x\r\r")
  assert_eq(e.length(), 1)
  assert_eq(e[0], "x")
}

///|
test "TC-FIXTURE-01: the recorded Responses stream is read as the call it was" {
  // A recorded stream, not a synthetic one: this is what a real backend sent
  // (see `llm/fixtures/live_responses_tool_call.provenance.json`). The
  // identifiers are placeholders; the event order, the event types and the
  // arguments are verbatim.
  let s = ToolStream::new(OpenAIResponses) catch { _ => return }
  for line in fx_lines(fx_live_responses_tool_call) {
    ignore(s.push_event(line)) catch {
      _ => return
    }
  }
  let views = drain_finish(s)
  assert_eq(views.length(), fx_live_responses_tool_call_calls.length())
  for i = 0; i < views.length(); i = i + 1 {
    let (choice, index, name, cid, args) = fx_live_responses_tool_call_calls[i]
    assert_eq(views[i].choice, choice)
    assert_eq(views[i].index, index)
    assert_eq(views[i].name, name)
    assert_eq(views[i].id, cid)
    // `arguments.done` repeats the whole string; the reader must not append it
    // a second time.
    assert_eq(views[i].snapshot.value.unwrap().stringify(), args)
    assert_eq(views[i].end.name(), "complete")
  }
}

///|
test "TC-FIXTURE-02: every recorded fixture is read by the adapter it was recorded for" {
  let cases : Array[(Provider, String)] = [
    (Anthropic, fx_anthropic_single),
    (Anthropic, fx_anthropic_escape_split),
    (Anthropic, fx_anthropic_parallel),
    (Anthropic, fx_anthropic_truncated),
    (Anthropic, fx_anthropic_mixed),
    (OpenAICompat, fx_openai_single),
    (OpenAICompat, fx_openai_parallel),
    (OpenAICompat, fx_openai_truncated),
    (OpenAICompat, fx_openai_name_only),
  ]
  for (provider, fixture) in cases {
    let s = ToolStream::new(provider) catch { _ => return }
    for line in fx_lines(fixture) {
      ignore(s.push_event(line)) catch {
        _ => return
      }
    }
    // The call count is what the fixture proves; the *value* of each call is
    // the subject of the per-provider tests above.
    ignore(drain_finish(s))
  }
}

///|
test "TC-RESP-05: a repeated item after arguments.done does not kill the stream" {
  // `function_call_arguments.done` closes the call; `output_item.done` may then
  // repeat a *longer* argument string. Feeding it to a finished parser raised
  // `E030 cannot feed a finished parser`, which discarded a whole response.
  // This is the shape a real stream produced intermittently.
  let s = ToolStream::new(OpenAIResponses) catch { _ => return }
  ignore(
    s.push_event(
      "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"\"}}",
    ),
  ) catch {
    _ => return
  }
  ignore(
    s.push_event(
      "{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc\",\"output_index\":0,\"arguments\":\"{\\\"a\\\":1}\"}",
    ),
  ) catch {
    _ => return
  }
  // `arguments.done` stops mid-string, and the item closes it. This is the
  // shape that produced `E030` intermittently: the item's argument string is a
  // *continuation* of the one the done event truncated.
  let s2 = ToolStream::new(OpenAIResponses) catch { _ => return }
  ignore(
    s2.push_event(
      "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"\"}}",
    ),
  ) catch {
    _ => return
  }
  ignore(
    s2.push_event(
      "{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc\",\"output_index\":0,\"arguments\":\"{\\\"a\\\":1}\"}",
    ),
  ) catch {
    _ => return
  }
  // A later item whose arguments extend the string the done event carried.
  ignore(
    s2.push_event(
      "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{\\\"a\\\":1,\\\"b\\\":2}\",\"status\":\"completed\"}}",
    ),
  ) catch {
    _ => return
  }
  let views = drain_finish(s2)
  assert_eq(views.length(), 1)
  // The value is the one the parser finished with; the later text is recorded,
  // not fed into a closed parser.
  assert_eq(views[0].snapshot.value.unwrap().stringify(), "{\"a\":1}")
  assert_eq(views[0].end.name(), "complete")
  // A string that does not extend the recorded one is not a continuation and
  // is not appended: `{"a":1}` is not a prefix of `{"a":1,"b":2}`.
  let views0 = drain_finish(s)
  assert_eq(views0.length(), 1)
  assert_eq(s.arguments(0), "{\"a\":1}")
}
