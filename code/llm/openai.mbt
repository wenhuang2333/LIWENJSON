// OpenAI Chat Completions chunks.
//
// Field paths follow the published streaming shape:
//   choices[].index
//   choices[].delta.tool_calls[].index
//   choices[].delta.tool_calls[].id
//   choices[].delta.tool_calls[].function.name
//   choices[].delta.tool_calls[].function.arguments
//   choices[].finish_reason
// The name usually arrives in the first fragment of a call and the arguments
// are then split arbitrarily. `finish_reason` is the provider's verdict:
// `stop`, `tool_calls` or `function_call` mean a normal end, `length` means the
// response was cut off by the token limit, `content_filter` means a policy stop.
// A top level `error` object ends the stream. `choices[].delta.content` carries
// ordinary text, which `ToolStream` ignores and `TextStream` reads.
//
// A stream may carry more than one choice (`n > 1`). Each choice has its own
// `index`, its own tool calls and its own `finish_reason`, so the key of a call
// is the pair `(choice.index, tool_call.index)` and a `finish_reason` closes
// only the calls of the choice it belongs to. Keying on the tool index alone
// merged the arguments of two choices whose calls both used index 0 and closed
// them together, and a choice that finished early closed a call another choice
// was still writing to (audit 3.6).

///|
/// Handle one Chat Completions chunk, returning the calls it changed.
fn ToolStream::push_openai(
  self : ToolStream,
  v : Json,
) -> Array[ToolCall] raise @interjson.InterJSONError {
  let out : Array[ToolCall] = []
  // An error frame is `{"error": {"message", "type", "param", "code"}}`; the
  // official clients raise on it and stop reading, which is what happens here.
  match field(v, "error") {
    Some(e) => {
      let message = match field_string(e, "message") {
        Some(m) => m
        None => "provider error"
      }
      self.note_error(message)
      return out
    }
    None => ()
  }
  // A Responses-API event is recognised so that it is refused with a sentence
  // naming the right reader, instead of falling through the "no `choices`"
  // path as an event that carries nothing. That fall-through is what made a
  // real Responses stream exit 0 with no output at all (audit 3.5).
  match field_string(v, "type") {
    Some(t) =>
      if t.has_prefix("response.") || t == "error" {
        raise @interjson.InvalidEvent(
          "this is a Responses API event (`" +
          t +
          "`); read it with the `openai-responses` provider, not the Chat Completions one",
        )
      }
    None => ()
  }
  let choices = match field(v, "choices") {
    Some(c) => as_array(c)
    None => None
  }
  let list = match choices {
    Some(a) => a
    None =>
      // A chunk with neither `choices` nor a known envelope is not an event this
      // adapter can read. Returning silently turned a wrong-provider stream into
      // "no tool calls".
      if field(v, "object") is Some(_) ||
        field(v, "id") is Some(_) ||
        field(v, "model") is Some(_) {
        raise @interjson.InvalidEvent(
          "a Chat Completions chunk must carry `choices`",
        )
      } else {
        return out
      }
  }
  for choice in list {
    let choice_index = match field_int(choice, "index") {
      Some(i) => i
      None => 0
    }
    let delta = match field(choice, "delta") {
      Some(d) => d
      None => continue
    }
    match field(delta, "tool_calls") {
      Some(tc) =>
        match as_array(tc) {
          Some(calls) =>
            for call in calls {
              let index = match field_int(call, "index") {
                Some(i) => i
                None => 0
              }
              let c = self.call_at(choice_index, index)
              match field_string(call, "id") {
                Some(i) => if c.id == "" { c.id = i }
                None => ()
              }
              match field(call, "function") {
                Some(f) => {
                  // The name arrives with the first fragment of a call and is
                  // never repeated; a later fragment must not rename it.
                  match field_string(f, "name") {
                    Some(n) => if n != "" && c.name == "" { c.name = n }
                    None => ()
                  }
                  match field_string(f, "arguments") {
                    Some(a) => self.push_arguments(c, a)
                    None => ()
                  }
                }
                None => ()
              }
              out.push(c)
            }
          None => ()
        }
      None => ()
    }
    // `finish_reason` closes the calls of *this choice*: the provider will not
    // send more argument fragments for it. Calls of another choice are still
    // open and must not be closed here.
    match field_string(choice, "finish_reason") {
      Some(reason) =>
        if reason != "" {
          let end = stop_end_of(reason)
          for c in self.calls {
            if c.choice == choice_index && !c.done {
              self.close_call(c, end)
              c.stop_reason = reason
              out.push(c)
            }
          }
          // The verdict is per choice, so it is recorded only on this
          // choice's calls. `content_filter` on one of two choices does not
          // mean the other choice's arguments were filtered.
          if !(end is Complete) {
            for c in self.calls {
              if c.choice == choice_index {
                c.stop_reason = reason
              }
            }
          }
        }
      None => ()
    }
  }
  out
}

///|
/// Handle one Responses API event, returning the calls it changed.
///
/// The call identity is `item_id` (falling back to `output_index`), not a
/// `tool_calls[].index`: the two protocols number their calls differently.
/// `response.function_call_arguments.delta` is incremental and
/// `...arguments.done` carries the whole string, so the two are *not* both
/// appended -- that would double the arguments (audit 3.5).
///
/// Unknown `response.*` event types are an explicit `E060`, not a silent
/// success: a reader that understands none of a stream must say so, or the host
/// reads "no tool calls" from a response that had one.
fn ToolStream::push_responses(
  self : ToolStream,
  v : Json,
) -> Array[ToolCall] raise @interjson.InterJSONError {
  let out : Array[ToolCall] = []
  let kind = match field_string(v, "type") {
    Some(t) => t
    None => {
      // An error envelope without a type is what some gateways send.
      match field(v, "error") {
        Some(e) => {
          let message = match field_string(e, "message") {
            Some(m) => m
            None => "provider error"
          }
          self.note_error(message)
          return out
        }
        None => ()
      }
      return out
    }
  }
  // The index a Responses event names: `output_index` for item-scoped events,
  // `item_id` as the stable identity when both are present.
  if kind == "response.output_item.added" {
    let item = match field(v, "item") {
      Some(i) => i
      None => return out
    }
    if field_string(item, "type") != Some("function_call") {
      return out
    }
    let c = self.responses_call(v, item)
    match field_string(item, "name") {
      Some(n) => if n != "" && c.name == "" { c.name = n }
      None => ()
    }
    // `call_id` is what the host routes the result back by; `id` is the item
    // the arguments belong to. Both are kept apart.
    match field_string(item, "call_id") {
      Some(i) => if i != "" { c.id = i }
      None => ()
    }
    match field_string(item, "id") {
      Some(i) => if c.item_id == "" { c.item_id = i }
      None => ()
    }
    // The item may already carry a complete (usually empty) `arguments` string.
    match field_string(item, "arguments") {
      Some(a) =>
        if a != "" && c.text.to_string() == "" {
          self.push_arguments(c, a)
        }
      None => ()
    }
    out.push(c)
    return out
  }
  if kind == "response.function_call_arguments.delta" {
    let delta = match field_string(v, "delta") {
      Some(d) => d
      None => return out
    }
    if delta == "" {
      return out
    }
    let c = self.responses_call(v, Json::null())
    self.push_arguments(c, delta)
    out.push(c)
    return out
  }
  if kind == "response.function_call_arguments.done" {
    let c = self.responses_call(v, Json::null())
    // `done` carries the whole argument string. Append only the part that has
    // not arrived as deltas; when the provider sent everything as deltas this
    // is the empty suffix, and when it sent none it is the whole string.
    match field_string(v, "arguments") {
      Some(full) => {
        let seen = c.text.to_string()
        if full.has_prefix(seen) {
          let rest = full[seen.length():].to_owned()
          if rest != "" {
            self.push_arguments(c, rest)
          }
        } else if seen == "" {
          self.push_arguments(c, full)
        } else {
          // The full string disagrees with the deltas. The full one is the
          // provider's own statement of the call, so it wins; the disagreement
          // is reported rather than hidden.
          self.note_error(
            "Responses arguments.done disagrees with the deltas it followed",
          )
          self.push_arguments(c, full)
        }
      }
      None => ()
    }
    self.close_call(c, Complete)
    out.push(c)
    return out
  }
  if kind == "response.output_item.done" {
    let item = match field(v, "item") {
      Some(i) => i
      None => return out
    }
    if field_string(item, "type") != Some("function_call") {
      return out
    }
    let c = self.responses_call(v, item)
    match field_string(item, "call_id") {
      Some(i) => if i != "" && c.id == "" { c.id = i }
      None => ()
    }
    // The item may repeat the whole argument string, and it may be longer than
    // what the deltas carried. The difference is recorded as the provider's
    // own statement of the call; it is *not* fed to the parser, because
    // `arguments.done` has often already closed it and a fragment fed to a
    // finished parser is `E030` -- which discarded a whole response.
    //
    // It is not fed even when the call is still open, because the value a
    // caller already received must not change under it: `arguments.done` is
    // the provider saying "this is the call", and a later item is a second
    // statement of the same thing.
    match field_string(item, "arguments") {
      Some(full) => {
        let seen = c.text.to_string()
        if full.has_prefix(seen) && full.length() > seen.length() {
          c.text.write_string(full[seen.length():].to_owned())
        }
      }
      None => ()
    }
    let status = match field_string(item, "status") {
      Some(s) => s
      None => "completed"
    }
    let end = match status {
      "incomplete" => MaxTokens
      "failed" => ProviderError
      _ => Complete
    }
    self.close_call(c, end)
    out.push(c)
    return out
  }
  if kind == "response.completed" ||
    kind == "response.incomplete" ||
    kind == "response.failed" {
    let response = match field(v, "response") {
      Some(r) => r
      None => v
    }
    let status = match field_string(response, "status") {
      Some(s) => s
      None =>
        if kind == "response.completed" {
          "completed"
        } else if kind == "response.incomplete" {
          "incomplete"
        } else {
          "failed"
        }
    }
    let incomplete = match field(response, "incomplete_details") {
      Some(d) =>
        match field_string(d, "reason") {
          Some(r) => r
          None => ""
        }
      None => ""
    }
    let end = responses_status_end(status, incomplete)
    if end is ProviderError {
      let message = match field(response, "error") {
        Some(e) =>
          match field_string(e, "message") {
            Some(m) => m
            None => "provider error"
          }
        None => "provider error"
      }
      self.note_error(message)
    }
    // `response.completed` is the end of the whole response: every call that
    // has not ended yet ends here.
    for c in self.calls {
      if !c.done {
        self.close_call(c, end)
        if incomplete != "" {
          c.stop_reason = incomplete
        }
        out.push(c)
      }
    }
    return out
  }
  if kind == "response.refusal.delta" || kind == "response.refusal.done" {
    self.note_refusal("refusal")
    return out
  }
  if kind == "error" {
    let message = match field(v, "error") {
      Some(e) =>
        match field_string(e, "message") {
          Some(m) => m
          None => "provider error"
        }
      None => "provider error"
    }
    self.note_error(message)
    return out
  }
  // Events this reader knows carry no argument fragments: text, reasoning and
  // the response envelope's own bookkeeping.
  if responses_known_ignorable(kind) {
    return out
  }
  // Anything else is a `response.*` event this build does not know. It is
  // recorded, not fatal: a real provider adds event types (the one this was
  // tested against sends `response.reasoning_summary_text.delta`), and failing
  // on one would make every future provider update break the reader. What must
  // never happen is the *silent* version -- no call, no error -- so `finish`
  // refuses a stream that produced no call while carrying unknown events.
  if kind.has_prefix("response.") {
    self.unsupported.push(kind)
  }
  out
}

///|
/// Whether a Responses event is known to carry no tool-call arguments.
fn responses_known_ignorable(kind : String) -> Bool {
  kind == "response.created" ||
  kind == "response.in_progress" ||
  kind == "response.output_item.added" ||
  kind == "response.content_part.added" ||
  kind == "response.content_part.done" ||
  kind == "response.output_text.delta" ||
  kind == "response.output_text.done" ||
  kind == "response.refusal.done" ||
  kind == "response.reasoning.delta" ||
  kind == "response.reasoning.done" ||
  kind == "response.reasoning_text.delta" ||
  kind == "response.reasoning_text.done" ||
  kind == "response.reasoning_summary.delta" ||
  kind == "response.reasoning_summary.done" ||
  kind == "response.reasoning_summary_text.delta" ||
  kind == "response.reasoning_summary_text.done" ||
  kind == "response.reasoning_summary_part.added" ||
  kind == "response.reasoning_summary_part.done" ||
  kind == "response.queued" ||
  kind == "response.web_search_call.searching" ||
  kind == "response.web_search_call.completed" ||
  kind == "response.file_search_call.searching" ||
  kind == "response.file_search_call.completed" ||
  kind == "response.code_interpreter_call.code" ||
  kind == "response.code_interpreter_call.completed" ||
  kind == "response.code_interpreter_call.interpreting" ||
  kind == "response.mcp_call.in_progress" ||
  kind == "response.mcp_call.completed" ||
  kind == "response.mcp_call.failed"
}

///|
/// The call an item-scoped Responses event talks about.
///
/// The identity is the item's own id when present (`item.id` or `item_id`),
/// because that is what every event of the call repeats. `output_index` is the
/// fallback, and it is also the *tool* index a host routes the result by.
fn ToolStream::responses_call(
  self : ToolStream,
  event : Json,
  item : Json,
) -> ToolCall {
  let mut index = match field_int(event, "output_index") {
    Some(i) => i
    None => 0
  }
  match field_int(item, "output_index") {
    Some(i) => index = i
    None => ()
  }
  let id = match field_string(item, "id") {
    Some(s) =>
      if s != "" {
        s
      } else {
        match field_string(event, "item_id") {
          Some(t) => t
          None => ""
        }
      }
    None =>
      match field_string(event, "item_id") {
        Some(t) => t
        None => ""
      }
  }
  // A call is identified by its item id when the provider gave one, and by its
  // output index otherwise.
  if id != "" {
    for c in self.calls {
      if c.item_id == id {
        return c
      }
    }
    let c = self.call_at(0, index)
    c.item_id = id
    return c
  }
  self.call_at(0, index)
}
