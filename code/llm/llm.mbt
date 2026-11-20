// liwenjson/llm — adapt the tool-call fragment streams of large language model
// providers into `liwenjson` partial parses (FR-23).
//
// The package is pure: it never opens a socket and never owns an HTTP client.
// Its input is the text of one already-extracted event payload; how that text
// was obtained (an SSE `data:` line, a WebSocket frame, a log line) is the
// caller's business. `sse.mbt` offers a minimal reader for the common case.

///|
/// Wire format of the incoming events.
pub(all) enum Provider {
  /// `content_block_start` / `content_block_delta` / `content_block_stop`,
  /// with `delta.type == "input_json_delta"` carrying `partial_json`.
  Anthropic
  /// Chat Completions: `choices[].delta.tool_calls[]`, with
  /// `function.name` and `function.arguments` fragments.
  OpenAICompat
  /// The Responses API: `response.output_item.added` /
  /// `response.function_call_arguments.delta` /
  /// `response.function_call_arguments.done` /
  /// `response.output_item.done` / `response.completed` /
  /// `response.incomplete` / `response.failed`.
  ///
  /// It is a different protocol from Chat Completions with different event
  /// names, a different call identity (`item_id`, `output_index`) and a
  /// different completeness story (`delta` is incremental, `done` carries the
  /// whole argument string). One enum variant per protocol, so a caller cannot
  /// select the wrong reader by accident: naming it `openai` for both was how
  /// a real Responses stream was read as a Chat Completions stream and
  /// produced zero calls and exit 0 (audit 3.5).
  OpenAIResponses
}

///|
/// Explicit `Eq` implementation for `Provider`.
pub impl Eq for Provider with fn equal(self : Provider, other : Provider) -> Bool {
  (self is Anthropic && other is Anthropic) ||
  (self is OpenAICompat && other is OpenAICompat) ||
  (self is OpenAIResponses && other is OpenAIResponses)
}

///|
/// Explicit `Eq` extension for `Provider`.
pub extend Provider with Eq::{not_equal, equal}

///|
/// How a stream ended, which is not the same question as "is the value
/// complete" (FR-23 / FR-30).
///
/// `Open` means no end was signalled yet. The distinction between `Complete`,
/// `MaxTokens` and `Interrupted` is the one a caller needs: the first two are
/// the provider's own verdicts (`content_block_stop` / `finish_reason`, and
/// `stop_reason: max_tokens` / `finish_reason: length`), the third means the
/// stream stopped without one — a dropped connection, or a caller that gave up.
pub(all) enum CallEnd {
  Open
  Complete
  MaxTokens
  Interrupted
  ProviderError
  /// The provider stopped for a policy reason: `content_filter`, `refusal`, a
  /// safety or guardrail verdict. It is not a normal end, and the arguments
  /// that arrived are *not* what the model wanted to say (audit 3.4). A caller
  /// that only reads `done`/`exactness` used to treat the empty or partial
  /// arguments of a filtered response as a complete, exact call.
  Refused
  /// The provider ended with a reason this adapter does not recognise. The
  /// default end used to be `Complete`, which meant every future stop reason
  /// became "the model finished normally"; a whitelist makes an unknown
  /// verdict visible instead (audit 3.4).
  Unknown
}

///|
/// Explicit `Eq` implementation for `CallEnd`.
pub impl Eq for CallEnd with fn equal(self : CallEnd, other : CallEnd) -> Bool {
  self.name() == other.name()
}

///|
/// Explicit `Eq` extension for `CallEnd`.
pub extend CallEnd with Eq::{not_equal, equal}

///|
/// Stable lowercase name of a `CallEnd`.
pub fn CallEnd::name(self : CallEnd) -> String {
  match self {
    Open => "open"
    Complete => "complete"
    MaxTokens => "max_tokens"
    Interrupted => "interrupted"
    ProviderError => "provider_error"
    Refused => "refused"
    Unknown => "unknown"
  }
}

///|
/// Whether the call ended because the provider ran out of tokens.
pub fn CallEnd::is_truncated(self : CallEnd) -> Bool {
  self is MaxTokens
}

///|
/// Whether this is a *normal* end: the provider said the response finished and
/// meant it.
///
/// This is a whitelist, not a blacklist. `Complete` is the only normal end, and
/// the adapters map a stop reason to it only when the reason is one they know
/// to mean "finished" (`stop`, `tool_calls`, `function_call`, `end_turn`,
/// `tool_use`, `stop_sequence`). Everything else -- a token limit, a refusal, a
/// filter, a connection that just stopped, an error, or a reason added to a
/// provider after this build -- is not normal, which is the safe default for a
/// gate.
pub fn CallEnd::is_normal(self : CallEnd) -> Bool {
  self is Complete
}

///|
/// Whether arguments that arrived under this end may be executed.
///
/// A refusal and a filter are *cannot happen* rather than *did not finish*: the
/// provider withdrew the response, so the arguments are not a reading of
/// anything the model committed to. `MaxTokens` and `Interrupted` leave a
/// partial argument string whose exactness the parser reports; that is a
/// separate, narrower claim (the bytes that arrived were readable), and a
/// caller must still refuse to execute a truncated call.
pub fn CallEnd::is_executable(self : CallEnd) -> Bool {
  self is Complete
}

///|
/// One tool call as seen so far.
///
/// `snapshot` is the partial parse of the argument text received so far, so a
/// caller can render a form while the model is still writing. `exactness` is
/// the exactness of that snapshot: as long as the arguments are incomplete it
/// is normally `Lossy`, and it becomes `Exact` only when the model happened to
/// emit a complete, valid argument object.
pub(all) struct ToolCallView {
  /// Provider index of the choice the call belongs to. A stream may carry more
  /// than one (`choices[]` with `n > 1`), and two choices can both use tool
  /// index 0; keying only on the tool index merged their arguments and closed
  /// them together (audit 3.6). `0` for the single-choice providers.
  choice : Int32
  /// Provider index of the tool call *within its choice*, used to route the
  /// result back.
  index : Int32
  /// Provider id of the call, when the provider sent one.
  id : String
  /// Function name, when the provider sent one.
  name : String
  /// Partial parse of the arguments received so far.
  snapshot : @liwenjson.Snapshot
  /// Exactness of `snapshot`.
  exactness : @liwenjson.Exactness
  /// Whether the provider signalled the end of this call's arguments.
  done : Bool
  /// How the call ended (FR-30).
  end : CallEnd
  /// The provider's own word for why it ended, verbatim and unparsed:
  /// `"end_turn"`, `"max_tokens"`, `"tool_use"`, `"length"`, `"stop"`, …
  stop_reason : String
}

///|
/// Whether this call's arguments may be executed.
///
/// Two conditions, and the second is the one the provider cannot give: the
/// end must be a normal one, and the arguments must have been read *without*
/// being changed. A provider can report `completed` for a response whose
/// argument string was cut off -- the real backend does exactly that at a low
/// token limit -- and the engine then closes the truncated string, which is a
/// repair that invents the missing brace. The value parses, the provider is
/// happy, and the arguments are not what the model wrote. `exactness` is what
/// says so, and a host that reads only `end` would execute an invented value.
pub fn ToolCallView::is_executable(self : ToolCallView) -> Bool {
  self.end.is_executable() && !(self.exactness is @liwenjson.Lossy)
}

///|
/// One call being accumulated.
struct ToolCall {
  choice : Int32
  index : Int32
  /// The provider's identity for the *item* that carries the arguments. The
  /// Responses API repeats it (`item_id`) on every event, while `call_id` is the
  /// id the host routes the result back by. The two are different strings and
  /// used to share one field, which meant the first one seen won.
  mut item_id : String
  mut id : String
  mut name : String
  mut parser : @liwenjson.PartialParser?
  mut done : Bool
  mut end : CallEnd
  mut stop_reason : String
  /// Text of every fragment received, kept for the equivalence check and for
  /// callers that want the raw text.
  text : StringBuilder
}

///|
/// Accumulates the tool calls of one model response.
pub struct ToolStream {
  provider : Provider
  options : @liwenjson.Options
  calls : Array[ToolCall]
  /// Explanation of the last `error` event, "" when none arrived.
  mut error_message : String
  /// Event payloads that were not understood: `ping`, `message_start`, future
  /// event types, text deltas in tool mode. The provider may add event types at
  /// any time, so they are counted and ignored rather than rejected.
  mut ignored : Int32
  /// The `response.*` event types this build does not know, in arrival order.
  ///
  /// A real provider adds them: the backend this was tested against sends
  /// `response.reasoning_summary_text.delta`, which carries no arguments and
  /// must not fail a stream that also carries a tool call. An unknown event is
  /// therefore recorded here rather than refused immediately -- and a stream
  /// that produced *no* call at all while carrying unknown events is refused at
  /// `finish`, because "the arguments were in an event this build does not
  /// read" is exactly the silent-success failure the audit found (3.5).
  unsupported : Array[String]
}

///|
/// Create a stream. `options` defaults to `Options::for_llm()`, the profile
/// that enables delta tracking and leaves the exactness gate open.
pub fn ToolStream::new(
  provider : Provider,
  options? : @liwenjson.Options,
) -> ToolStream raise @liwenjson.LIWENJSONError {
  let opts = match options {
    Some(o) => o
    None => @liwenjson.Options::for_llm()
  }
  opts.validate()
  {
    provider,
    options: opts,
    calls: [],
    error_message: "",
    ignored: 0,
    unsupported: [],
  }
}

///|
/// The call at `index`, created on first use.
fn ToolStream::call_at(
  self : ToolStream,
  choice : Int32,
  index : Int32,
) -> ToolCall {
  for c in self.calls {
    if c.choice == choice && c.index == index {
      return c
    }
  }
  let c : ToolCall = {
    choice,
    index,
    item_id: "",
    id: "",
    name: "",
    parser: None,
    done: false,
    end: Open,
    stop_reason: "",
    text: StringBuilder(),
  }
  self.calls.push(c)
  c
}

///|
/// The parser of a call, created on first use.
fn ToolStream::parser_of(
  self : ToolStream,
  c : ToolCall,
) -> @liwenjson.PartialParser raise @liwenjson.LIWENJSONError {
  match c.parser {
    Some(p) => p
    None => {
      let p = @liwenjson.PartialParser::new(options=self.options)
      c.parser = Some(p)
      p
    }
  }
}

///|
/// View of one call.
fn ToolStream::view(self : ToolStream, c : ToolCall) -> ToolCallView {
  ignore(self)
  let snap = match c.parser {
    Some(p) => p.snapshot()
    None =>
      {
        value: None,
        completeness: @liwenjson.Empty,
        open_path: [],
        exactness: @liwenjson.Exact,
        ambiguous: false,
      }
  }
  {
    choice: c.choice,
    index: c.index,
    id: c.id,
    name: c.name,
    snapshot: snap,
    exactness: snap.exactness,
    done: c.done,
    end: c.end,
    stop_reason: c.stop_reason,
  }
}

///|
/// Append one argument fragment to a call.
fn ToolStream::push_arguments(
  self : ToolStream,
  c : ToolCall,
  fragment : String,
) -> Unit raise @liwenjson.LIWENJSONError {
  // A finished parser cannot take another fragment (`E030`). A provider can
  // send one anyway: `response.function_call_arguments.done` closes the call
  // and `response.output_item.done` then repeats a *longer* argument string,
  // which is what one real stream did. The text that arrived is kept for the
  // record; feeding it to a finished parser is what used to raise, and it
  // killed a whole response.
  if c.done {
    c.text.write_string(fragment)
    return
  }
  // An empty fragment is not argument bytes. Creating a parser for it and
  // calling `finish` would raise E001, so one empty `partial_json` (or the
  // empty first `arguments` chunk OpenAI-compatible endpoints send) used to
  // kill a whole response. A call with no bytes is decided in `close_call`.
  if fragment.length() == 0 {
    return
  }
  c.text.write_string(fragment)
  let p = self.parser_of(c)
  p.feed(fragment)
}

///|
/// Mark a call's arguments as complete.
fn ToolStream::close_call(
  self : ToolStream,
  c : ToolCall,
  end : CallEnd,
) -> Unit raise @liwenjson.LIWENJSONError {
  match c.parser {
    Some(p) => if !c.done { ignore(p.finish()) }
    // A call whose name arrived but whose arguments never did has no parser:
    // there is nothing to finish and `finish` would raise `E001`. A normal end
    // is still a legal no-argument call, whose value is the empty object; only
    // an abnormal end leaves it unresolved.
    None =>
      if end is Complete && !c.done {
        let p = @liwenjson.PartialParser::new(options=self.options)
        c.parser = Some(p)
        p.feed("{}")
        ignore(p.finish())
      }
  }
  c.done = true
  // A verdict that is already known wins: `content_block_stop` says "this block
  // ended normally", it does not overrule a `max_tokens` or a provider error.
  if c.end is Open {
    c.end = end
  }
}

///|
/// Record the provider's own word for why the stream ended, on every call that
/// is not already in an error state.
fn ToolStream::note_stop(self : ToolStream, reason : String) -> Unit {
  let end = stop_end_of(reason)
  for c in self.calls {
    if c.end is ProviderError || c.end is Refused {
      continue
    }
    // The provider's word is recorded even when the block already closed
    // normally: `tool_use` and `end_turn` are both normal ends, and a caller
    // may still want to know which one it was.
    if reason != "" {
      c.stop_reason = reason
    }
    // A verdict that is not a normal completion replaces a normal one: a
    // `content_filter` that arrives after `end_turn` still means the provider
    // withdrew the response. Only a call that already ended abnormally keeps
    // its first, more specific verdict.
    let replace = c.end is Open ||
      (end is Refused || end is MaxTokens || end is Unknown) ||
      (end is Complete && c.end is Complete)
    if replace {
      c.end = end
    }
  }
}

///|
/// The `CallEnd` a provider stop word means.
///
/// The normal ends are enumerated; anything else is *not* normal. That is the
/// difference between this and the mapping it replaces, which defaulted to
/// `Complete` and therefore reported a `content_filter` or a `refusal` as a
/// finished response with exact, executable arguments (audit 3.4).
pub fn stop_end_of(reason : String) -> CallEnd {
  match reason {
    // Chat Completions, Responses API and Anthropic normal ends.
    "stop"
    | "tool_calls"
    | "function_call"
    | "end_turn"
    | "tool_use"
    | "stop_sequence"
    | "completed" => Complete
    "length"
    | "max_tokens"
    | "max_output_tokens"
    | "model_context_window_exceeded" => MaxTokens
    "content_filter" | "refusal" | "guardrail" | "safety" | "blocked" => Refused
    "" => Open
    _ => Unknown
  }
}

///|
/// Whether a Responses-API `response.status` / `incomplete_details.reason` is a
/// normal completion.
fn responses_status_end(status : String, incomplete_reason : String) -> CallEnd {
  if status == "completed" {
    Complete
  } else if status == "incomplete" {
    stop_end_of(incomplete_reason)
  } else if status == "failed" {
    ProviderError
  } else if status == "cancelled" {
    Interrupted
  } else {
    Unknown
  }
}

///|
/// Mark every call that has not ended as withdrawn by the provider (a refusal
/// or a filter). The arguments are still finalised, so a caller can see what the
/// model had said -- but the call is not executable, whatever its arguments
/// parse to (audit 3.4).
fn ToolStream::note_refusal(self : ToolStream, reason : String) -> Unit {
  self.error_message = reason
  for c in self.calls {
    if c.end is Open || c.end is Complete {
      c.end = Refused
      c.stop_reason = reason
    }
  }
}

///|
/// Mark every call as ended by a provider error (FR-30).
fn ToolStream::note_error(self : ToolStream, message : String) -> Unit {
  self.error_message = message
  for c in self.calls {
    // The end is decided, but the arguments are left open so that `finish`
    // still finalises whatever fragment arrived: a caller wants the partial
    // value of a call that failed, not an empty one.
    c.end = ProviderError
  }
}

///|
/// Feed one event payload. Returns the views of the calls the event changed.
///
/// The payload must be a complete JSON document. Anything that cannot be read
/// as an event of the configured provider raises `E060 InvalidEvent`.
pub fn ToolStream::push_event(
  self : ToolStream,
  event_json : String,
) -> Array[ToolCallView] raise @liwenjson.LIWENJSONError {
  let v = @json.parse(event_json) catch {
    _ => raise @liwenjson.InvalidEvent("event payload is not valid JSON")
  }
  let touched = match self.provider {
    Anthropic => self.push_anthropic(v)
    OpenAICompat => self.push_openai(v)
    OpenAIResponses => self.push_responses(v)
  }
  if touched.length() == 0 {
    self.ignored = self.ignored + 1
  }
  let out : Array[ToolCallView] = []
  for c in touched {
    out.push(self.view(c))
  }
  out
}

///|
/// Whether the provider reported an error in the stream, and what it said.
pub fn ToolStream::error(self : ToolStream) -> String {
  self.error_message
}

///|
/// The `response.*` event types this build did not know, in arrival order. A
/// non-empty list is not an error by itself: a stream can carry a reasoning
/// summary *and* a tool call. It is the evidence a caller needs to tell "no
/// call was made" from "a call may have been missed".
pub fn ToolStream::unsupported_events(self : ToolStream) -> Array[String] {
  self.unsupported.copy()
}

///|
/// How many payloads were not understood and ignored.
pub fn ToolStream::ignored_events(self : ToolStream) -> Int32 {
  self.ignored
}

///|
/// Finish every call that the provider never closed, and return all views.
///
/// This is the case of a response cut short by `max_tokens`: the arguments are
/// truncated, so `liwenjson` closes the open containers and the view's
/// exactness is `Lossy`.
pub fn ToolStream::finish(
  self : ToolStream,
) -> Array[ToolCallView] raise @liwenjson.LIWENJSONError {
  if self.calls.length() == 0 && self.unsupported.length() > 0 {
    raise @liwenjson.InvalidEvent(
      "the stream carried events this build does not read (" +
      self.unsupported.join(", ") +
      ") and produced no tool call; the arguments cannot be claimed to be absent",
    )
  }
  let out : Array[ToolCallView] = []
  for c in self.calls {
    // A call the provider never closed was cut off: the stream stopped without
    // a verdict, which is not the same as a normal end (FR-30).
    let end = if c.end is Open { Interrupted } else { c.end }
    self.close_call(c, end)
    out.push(self.view(c))
  }
  out
}

///|
/// Every call seen so far, without finishing anything.
pub fn ToolStream::views(self : ToolStream) -> Array[ToolCallView] {
  let out : Array[ToolCallView] = []
  for c in self.calls {
    out.push(self.view(c))
  }
  out
}

///|
/// Raw argument text accumulated for tool call `index` of choice `choice`, or
/// the empty string.
pub fn ToolStream::arguments_at(
  self : ToolStream,
  choice : Int32,
  index : Int32,
) -> String {
  for c in self.calls {
    if c.choice == choice && c.index == index {
      return c.text.to_string()
    }
  }
  ""
}

///|
/// Raw argument text accumulated for the first call with tool index `index`,
/// whatever its choice, or the empty string.
///
/// Kept because most streams have one choice and a caller that routes by tool
/// index only is still reading one call. A caller that must not confuse two
/// choices uses `arguments_at`.
pub fn ToolStream::arguments(self : ToolStream, index : Int32) -> String {
  for c in self.calls {
    if c.index == index {
      return c.text.to_string()
    }
  }
  ""
}
