// A no-argument tool call is a legal call. Its arguments are the empty object,
// not `null`, and an empty fragment must not kill the stream.
//
// Real shapes this covers (2026-11-21):
//   * Anthropic: `content_block_start` with `input:{}`, no `input_json_delta`;
//   * Anthropic: one `input_json_delta` whose `partial_json` is "";
//   * OpenAI Chat: first chunk `function.arguments:""`, then `finish_reason`;
//   * OpenAI Responses: `arguments:""` on add/done, then `response.completed`.

///|
fn noarg_anthropic(extra_delta : Bool) -> Array[ToolCallView] raise {
  let s = ToolStream::new(Anthropic)
  ignore(
    s.push_event(
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"ping\",\"input\":{}}}",
    ),
  )
  if extra_delta {
    ignore(
      s.push_event(
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\"}}",
      ),
    )
  }
  ignore(s.push_event("{\"type\":\"content_block_stop\",\"index\":0}"))
  ignore(
    s.push_event(
      "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}",
    ),
  )
  s.finish()
}

///|
test "anthropic no-argument call is an empty object" {
  let v = noarg_anthropic(false)
  assert_eq(v.length(), 1)
  assert_eq(v[0].name, "ping")
  assert_eq(v[0].done, true)
  assert_eq(v[0].end.name(), "complete")
  assert_eq(v[0].exactness.name(), "exact")
  assert_eq(v[0].is_executable(), true)
  assert_eq(v[0].snapshot.value.unwrap().stringify(), "{}")
}

///|
test "an empty partial_json is ignored, not E001" {
  let v = noarg_anthropic(true)
  assert_eq(v.length(), 1)
  assert_eq(v[0].snapshot.value.unwrap().stringify(), "{}")
  assert_eq(v[0].is_executable(), true)
}

///|
test "openai chat empty arguments is an empty object" {
  let s = ToolStream::new(OpenAICompat)
  ignore(
    s.push_event(
      "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"t1\",\"type\":\"function\",\"function\":{\"name\":\"ping\",\"arguments\":\"\"}}]}}]}",
    ),
  )
  ignore(
    s.push_event(
      "{\"choices\":[{\"index\":0,\"finish_reason\":\"tool_calls\"}]}",
    ),
  )
  let v = s.finish()
  assert_eq(v.length(), 1)
  assert_eq(v[0].is_executable(), true)
  assert_eq(v[0].snapshot.value.unwrap().stringify(), "{}")
}

///|
test "openai responses empty arguments is an empty object" {
  let s = ToolStream::new(OpenAIResponses)
  ignore(
    s.push_event(
      "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc1\",\"call_id\":\"c1\",\"name\":\"ping\",\"arguments\":\"\"}}",
    ),
  )
  ignore(
    s.push_event(
      "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc1\",\"delta\":\"\"}",
    ),
  )
  ignore(
    s.push_event(
      "{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc1\",\"arguments\":\"\"}",
    ),
  )
  ignore(
    s.push_event(
      "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc1\",\"call_id\":\"c1\",\"name\":\"ping\",\"arguments\":\"\",\"status\":\"completed\"}}",
    ),
  )
  ignore(
    s.push_event(
      "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}",
    ),
  )
  let v = s.finish()
  assert_eq(v.length(), 1)
  assert_eq(v[0].is_executable(), true)
  assert_eq(v[0].snapshot.value.unwrap().stringify(), "{}")
}

///|
test "an interrupted no-argument call is not executable" {
  let s = ToolStream::new(Anthropic)
  ignore(
    s.push_event(
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"ping\",\"input\":{}}}",
    ),
  )
  let v = s.finish()
  assert_eq(v.length(), 1)
  assert_eq(v[0].end.name(), "interrupted")
  assert_eq(v[0].is_executable(), false)
  assert_eq(v[0].snapshot.value is None, true)
}
