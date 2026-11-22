// FR-30 — the text half of the adapter.
//
// Tool-call arguments are not the only place a model writes JSON. A structured
// output request is answered as ordinary text:
//
//   Anthropic  content_block_delta, delta.type == "text_delta", delta.text
//   OpenAI     choices[].delta.content
//
// The event shapes above are taken from the official type definitions of both
// SDKs (`text_delta.py`, `chat_completion_chunk.py`); `docs/LLM_EVENTS.md`
// records the exact sources. `TextStream` turns that text into the same partial
// parse the tool-call path produces, so a caller can render either kind of
// response with one renderer.
//
// The parser starts with `skip_prose`, because a text answer usually begins
// with "Here is the JSON:" before the value. Anything the parser cannot use as
// JSON yet is simply not in the snapshot; nothing is guessed.

///|
/// Reads the JSON a model writes as plain text (FR-30).
pub struct TextStream {
  provider : Provider
  parser : @liwenjson.PartialParser
  buf : StringBuilder
  mut end : CallEnd
  mut stop_reason : String
  mut error_message : String
  mut finish_error : @liwenjson.LIWENJSONError?
  mut ignored : Int32
  mut seen_text : Bool
  // The Chat Completions choice the single parser belongs to, -1 before the
  // first text. A stream with `n > 1` interleaves choices, and one parser
  // cannot hold two JSON documents, so a second choice is refused rather than
  // silently folded into the first (or losing the last one, as before).
  mut choice : Int32
}

///|
/// Create a text stream.
///
/// The default options are `Options::for_llm()`, the same as the tool-call
/// path, so the value read here is the value the rest of the library would
/// read. Pass `skip_prose: true` when the answer is a sentence that contains a
/// JSON document: that strip only starts a value at `{` or `[`, so it must not
/// be the default — a scalar root (`0`, `"x"`) would be skipped as prose.
pub fn TextStream::new(
  provider : Provider,
  options? : @liwenjson.Options,
) -> TextStream raise @liwenjson.LIWENJSONError {
  let opts = match options {
    Some(o) => o
    None => @liwenjson.Options::for_llm()
  }
  opts.validate()
  {
    provider,
    parser: @liwenjson.PartialParser::new(options=opts),
    buf: StringBuilder(),
    end: Open,
    stop_reason: "",
    error_message: "",
    finish_error: None,
    ignored: 0,
    seen_text: false,
    choice: -1,
  }
}

///|
/// The text deltas received so far, concatenated.
pub fn TextStream::text(self : TextStream) -> String {
  self.buf.to_string()
}

///|
/// How the stream ended (FR-30).
pub fn TextStream::end(self : TextStream) -> CallEnd {
  self.end
}

///|
/// The provider's own word for why it ended, "" when it did not say.
pub fn TextStream::stop_reason(self : TextStream) -> String {
  self.stop_reason
}

///|
/// The provider error message, or the final parse error when no provider error
/// arrived. "" means neither failed.
pub fn TextStream::error(self : TextStream) -> String {
  if self.error_message != "" {
    return self.error_message
  }
  match self.finish_error {
    Some(e) => e.to_string()
    None => ""
  }
}

///|
/// The original final parse error, so a caller can preserve its error code
/// without mistaking a failed parse for a stream that carried no text.
pub fn TextStream::finish_error(
  self : TextStream,
) -> @liwenjson.LIWENJSONError? {
  self.finish_error
}

///|
/// How many payloads carried no text and were ignored.
pub fn TextStream::ignored_events(self : TextStream) -> Int32 {
  self.ignored
}

///|
/// Feed one event payload; the snapshot of the JSON found in the text so far is
/// returned when the event carried text, and `None` otherwise.
pub fn TextStream::push_event(
  self : TextStream,
  event_json : String,
) -> @liwenjson.Snapshot? raise @liwenjson.LIWENJSONError {
  let v = @json.parse(event_json, preserve_number_repr=true) catch {
    _ => raise @liwenjson.InvalidEvent("event payload is not valid JSON")
  }
  let fragment = match self.provider {
    Anthropic => self.text_of_anthropic(v)
    OpenAICompat => self.text_of_openai(v)
    OpenAIResponses => self.text_of_responses(v)
  }
  match fragment {
    Some(s) => {
      if s == "" {
        self.ignored = self.ignored + 1
        return None
      }
      self.seen_text = true
      self.buf.write_string(s)
      self.parser.feed(s)
      Some(self.parser.snapshot())
    }
    None => {
      self.ignored = self.ignored + 1
      None
    }
  }
}

///|
/// The text fragment of one Anthropic event, if it carries one.
fn TextStream::text_of_anthropic(self : TextStream, v : Json) -> String? {
  let kind = match field_string(v, "type") {
    Some(t) => t
    None => return None
  }
  if kind == "content_block_delta" {
    return match field(v, "delta") {
      Some(d) =>
        if field_string(d, "type") == Some("text_delta") {
          field_string(d, "text")
        } else {
          None
        }
      None => None
    }
  }
  if kind == "message_delta" {
    match field(v, "delta") {
      Some(d) =>
        match field_string(d, "stop_reason") {
          Some(r) => self.stop_reason = r
          None => ()
        }
      None => ()
    }
    self.end = stop_end(self.stop_reason)
    return None
  }
  if kind == "message_stop" {
    if self.end is Open {
      self.end = Complete
    }
    return None
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
    self.error_message = message
    self.end = ProviderError
    return None
  }
  None
}

///|
/// The text fragment of one OpenAI compatible chunk, if it carries one.
///
/// A chunk may carry several choices (`n > 1`). The text of each choice is a
/// separate JSON document, and `TextStream` has one parser, so a stream that
/// switches choices is refused with `E060` instead of merging the texts (which
/// used to keep only the last non-empty one in a frame and silently lose the
/// others). A single-choice stream is read exactly as before.
fn TextStream::text_of_openai(
  self : TextStream,
  v : Json,
) -> String? raise @liwenjson.LIWENJSONError {
  match field(v, "error") {
    Some(e) => {
      self.error_message = match field_string(e, "message") {
        Some(m) => m
        None => "provider error"
      }
      self.end = ProviderError
      return None
    }
    None => ()
  }
  let choices = match field(v, "choices") {
    Some(c) => as_array(c)
    None => None
  }
  let list = match choices {
    Some(a) => a
    None => return None
  }
  let text = StringBuilder()
  for choice in list {
    let choice_index = match field_index(choice, "index") {
      Some(i) => i
      None => 0
    }
    match field(choice, "delta") {
      Some(delta) =>
        match field_string(delta, "content") {
          Some(s) =>
            if s != "" {
              if self.choice >= 0 && self.choice != choice_index {
                raise @liwenjson.InvalidEvent(
                  "text arrived for more than one choice; a single text stream cannot represent that",
                )
              }
              if self.choice < 0 {
                self.choice = choice_index
              }
              text.write_string(s)
            }
          None => ()
        }
      None => ()
    }
    match field_string(choice, "finish_reason") {
      Some(reason) =>
        if reason != "" {
          self.stop_reason = reason
          self.end = stop_end(reason)
        }
      None => ()
    }
  }
  let out = text.to_string()
  if out == "" {
    None
  } else {
    Some(out)
  }
}

///|
/// The text fragment of one Responses API event, if it carries one.
///
/// Text arrives as `response.output_text.delta`, and the end of the response is
/// `response.completed` / `response.incomplete` / `response.failed`, whose
/// `status` and `incomplete_details.reason` say how it ended. A refusal
/// (`response.refusal.done`) is a `Refused` end, not an empty answer.
fn TextStream::text_of_responses(self : TextStream, v : Json) -> String? {
  let kind = match field_string(v, "type") {
    Some(t) => t
    None => return None
  }
  if kind == "response.output_text.delta" {
    return match field_string(v, "delta") {
      Some(s) => if s == "" { None } else { Some(s) }
      None => None
    }
  }
  if kind == "response.refusal.done" {
    self.end = Refused
    self.stop_reason = "refusal"
    return None
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
      None => "completed"
    }
    let incomplete = match field(response, "incomplete_details") {
      Some(d) =>
        match field_string(d, "reason") {
          Some(r) => r
          None => ""
        }
      None => ""
    }
    self.end = responses_status_end(status, incomplete)
    if self.end is ProviderError {
      self.error_message = match field(response, "error") {
        Some(e) =>
          match field_string(e, "message") {
            Some(m) => m
            None => "provider error"
          }
        None => "provider error"
      }
    }
    if incomplete != "" {
      self.stop_reason = incomplete
    }
    return None
  }
  None
}

///|
/// Map a provider stop word to a `CallEnd`. The whitelist lives in `llm.mbt`,
/// beside the tool-call path, so the two readers cannot disagree about what a
/// `content_filter` means.
pub fn stop_end(reason : String) -> CallEnd {
  stop_end_of(reason)
}

///|
/// The final parse of the text received so far.
///
/// Returns `None` when no text ever arrived or the final parse failed. In the
/// latter case `finish_error()` holds the original error and `error()` reports
/// it: `None` alone is never evidence of a successful parse. A stream that was
/// still open is reported as `Interrupted`; parsing does not change a verdict
/// the provider already gave.
pub fn TextStream::finish(self : TextStream) -> @liwenjson.FinalResult? {
  if self.end is Open {
    self.end = Interrupted
  }
  if !self.seen_text || self.finish_error is Some(_) {
    return None
  }
  let r = self.parser.finish() catch {
    e => {
      self.finish_error = Some(e)
      return None
    }
  }
  Some(r)
}
