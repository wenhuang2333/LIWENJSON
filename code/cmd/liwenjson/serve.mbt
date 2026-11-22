// `liwenjson serve` — the long-lived, versioned protocol (PROTOCOL.md).
//
// `--stdio` is accepted as an explicit alias: stdio is the only transport,
// so the flag selects nothing. It exists so that the command line printed in
// the documentation works verbatim.
//
// One request per line on stdin, one response per line on stdout, UTF-8. The
// response echoes the client's `id`. stdout carries protocol bytes and nothing
// else; diagnostics go to stderr. The engine is the same one the one-shot CLI
// uses, so `serve` cannot disagree with `liwenjson repair`.
//
// The protocol is deliberately stateless for `repair`/`analyze`/`validate` and
// single-stream for `watch`/`llm`: one active stream per connection. That is
// enough for a tool-calling loop (one call at a time) and avoids an id map
// whose copy semantics would be the first thing to break. `hello` advertises
// `streams: 1` so a client can see the limit instead of discovering it.

///|
/// Protocol major version. A client that sees a different major version must
/// not assume the same fields.
const PROTOCOL_VERSION : Int32 = 1

///|
/// The engine version this build reports. It is the library's `VERSION`, not
/// a literal: the CLI, the MCP handshake and the library all have to name the
/// same release, and there is exactly one place that says which release this
/// is.
const ENGINE_VERSION : String = @lj.VERSION

///|
/// The mooncakes registry version that corresponds to `ENGINE_VERSION`. Also
/// the library's, for the same reason.
const REGISTRY_VERSION : String = @lj.REGISTRY_VERSION

///|
/// Largest request line accepted. A request larger than this is answered with
/// a structured error and discarded; it is not allowed to grow the process.
const MAX_LINE : Int32 = 8388608

///|
/// Line reader over a stdio stream. `fread` is asked for exactly one byte at a
/// time: a larger read blocks until the whole buffer is full on a pipe, which
/// would make the interactive protocol wait for 64 KiB before answering. The
/// stdio layer still buffers the underlying file descriptor, so this is a
/// function call per byte, not a syscall per byte.
struct LineReader {
  stream : Int64
  one : Bytes
  mut acc : Array[Byte]
  mut overflow : Bool
  /// Refuse malformed UTF-8 frames instead of replacement-decoding them.
  /// Opt-in: `batch` keeps the lossy reader it has always used.
  strict : Bool
  mut invalid_utf8 : Bool
  mut utf8_offset : Int32
}

///|
/// A reader over `stream`.
fn LineReader::new(stream : Int64) -> LineReader {
  {
    stream,
    one: Bytes::make(1, b'\x00'),
    acc: [],
    overflow: false,
    strict: false,
    invalid_utf8: false,
    utf8_offset: 0,
  }
}

///|
/// A reader over `stream` that refuses frames which are not valid UTF-8.
fn LineReader::new_strict(stream : Int64) -> LineReader {
  { ..LineReader::new(stream), strict: true, }
}

///|
/// Decode a frame. The strict reader answers `None` for malformed UTF-8 and
/// records the byte offset of the first bad byte; the caller turns that into a
/// controlled protocol error and keeps serving the connection.
fn LineReader::decode_frame(self : LineReader) -> String? {
  let raw = Bytes::from_array(self.acc[:])
  if !self.strict {
    return Some(@utf8.decode_lossy(raw))
  }
  let decoded : String? = Some(@utf8.decode(raw)) catch {
    @utf8.Malformed(suffix) => {
      self.invalid_utf8 = true
      self.utf8_offset = raw.length() - suffix.length()
      None
    }
  }
  decoded
}

///|
/// The next byte, or `-1` at end of input.
fn LineReader::next_byte(self : LineReader) -> Int32 {
  let n = ffi_fread(self.one, 1, 1, self.stream)
  if n <= 0L {
    -1
  } else {
    self.one[0].to_char().to_int()
  }
}

///|
/// The next line, without the LF, or `None` at end of input. A line longer
/// than `MAX_LINE` sets `overflow` and is discarded up to the next LF; the
/// caller answers with an error instead of trying to parse half a request.
fn LineReader::read_line(self : LineReader) -> String? {
  self.acc = []
  self.invalid_utf8 = false
  while true {
    let c = self.next_byte()
    if c < 0 {
      if self.acc.length() == 0 {
        return None
      }
      // `None` from the decoder means "malformed frame", not end of input:
      // the caller must answer with an error and keep reading, so it is
      // reported as an empty line with `invalid_utf8` set.
      match self.decode_frame() {
        Some(text) => return Some(text)
        None => return Some("")
      }
    }
    if c == 0x0A {
      match self.decode_frame() {
        Some(text) => return Some(text)
        None => return Some("")
      }
    }
    if self.acc.length() >= MAX_LINE {
      self.overflow = true
      while true {
        let d = self.next_byte()
        if d < 0 || d == 0x0A {
          break
        }
      } nobreak {
        ()
      }
      self.acc = []
      return Some("")
    }
    self.acc.push(c.to_byte())
  } nobreak {
    None
  }
}

///|
/// Build a JSON object from pairs.
fn jobj(pairs : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for pair in pairs {
    m[pair.0] = pair.1
  }
  Json::object(m)
}

///|
/// A number from a code-unit count.
fn jnum(n : Int32) -> Json {
  Json::number(n.to_double())
}

///|
/// `Completeness` as the stable word the protocol uses.
fn completeness_name(c : @lj.Completeness) -> String {
  match c {
    @lj.Empty => "empty"
    @lj.Partial => "partial"
    @lj.Complete => "complete"
  }
}

///|
/// One repair record. The shape is defined once, in `plan.mbt`, because the
/// plan (`analyze`) and the protocol (`repair`/`validate`) both return it and
/// two hand-written shapes had already drifted apart (audit 3.7).
fn repair_json(r : @lj.Repair) -> Json {
  @lj.repair_record_json(r)
}

///|
/// One delta.
fn delta_json(d : @lj.Delta) -> Json {
  jobj([
    ("path", Json::string(d.pointer())),
    ("op", Json::string(d.op.name())),
    (
      "value",
      match d.value {
        Some(v) => v
        None => Json::null()
      },
    ),
    ("text", Json::string(d.text)),
    ("at", jnum(d.at)),
  ])
}

///|
/// A snapshot path as `a/0/b`.
fn snapshot_path(s : @lj.Snapshot) -> String {
  let sb = StringBuilder()
  for i = 0; i < s.open_path.length(); i = i + 1 {
    if i > 0 {
      sb.write_char('/')
    }
    match s.open_path[i] {
      @lj.Key(k) => sb.write_string(k)
      @lj.Index(x) => sb.write_string(x.to_string())
    }
  }
  sb.to_string()
}

///|
/// A finished parse.
fn final_json(f : @lj.FinalResult) -> Json {
  jobj([
    ("text", Json::string(f.text)),
    ("value", f.value),
    ("exactness", Json::string(f.exactness.name())),
    ("ambiguous", Json::boolean(f.ambiguous)),
    ("completeness", Json::string(completeness_name(f.completeness))),
    ("repairs", Json::array(f.repairs.map(repair_json))),
    ("repairs_truncated", Json::boolean(f.repairs_truncated)),
  ])
}

///|
/// A one-shot repair result (no `value`; `analyze` carries the value).
fn repair_out_json(r : @lj.RepairResult) -> Json {
  jobj([
    ("text", Json::string(r.text)),
    ("exactness", Json::string(r.exactness.name())),
    ("ambiguous", Json::boolean(r.ambiguous)),
    ("completeness", Json::string(completeness_name(r.completeness))),
    ("repairs", Json::array(r.repairs.map(repair_json))),
    ("repairs_truncated", Json::boolean(r.repairs_truncated)),
  ])
}

///|
/// One readiness event with the offset it fired at.
fn event_json(e : @lj.ReadinessEvent, at : Int32, fed : Int32) -> Json {
  let base = @json.parse(e.to_json()) catch { _ => Json::null() }
  match base {
    Json::Object(m) => {
      m["at"] = jnum(at)
      m["permille"] = jnum(
        if at < 0 || fed == 0 {
          -1
        } else {
          at * 1000 / fed
        },
      )
      Json::object(m)
    }
    _ => base
  }
}

///|
/// A schema verdict.
fn verdict_json(v : @lj.SchemaVerdict) -> Json {
  let mismatched : Array[Json] = []
  for m in v.mismatched {
    mismatched.push(
      jobj([
        ("path", Json::string(m.path)),
        ("expected", Json::string(m.expected)),
        ("got", Json::string(m.got)),
      ]),
    )
  }
  jobj([
    ("total", jnum(v.total)),
    ("satisfied", jnum(v.satisfied)),
    ("missing", Json::array(v.missing.map(Json::string))),
    ("mismatched", Json::array(mismatched)),
    ("ok", Json::boolean(v.ok)),
  ])
}

///|
/// One tool call as the provider stream sees it.
fn tool_call_json(v : @llm.ToolCallView) -> Json {
  jobj([
    ("choice", jnum(v.choice)),
    ("index", jnum(v.index)),
    ("id", Json::string(v.id)),
    ("name", Json::string(v.name)),
    ("done", Json::boolean(v.done)),
    ("exactness", Json::string(v.exactness.name())),
    ("end", Json::string(v.end.name())),
    ("stop_reason", Json::string(v.stop_reason)),
    ("executable", Json::boolean(v.is_executable())),
    (
      "value",
      match v.snapshot.value {
        Some(x) => x
        None => Json::null()
      },
    ),
    ("open_path", Json::string(snapshot_path(v.snapshot))),
  ])
}

///|
/// A fatal error as a structured object, never as stderr text.
fn error_json(e : @lj.LIWENJSONError) -> Json {
  let m : Map[String, Json] = Map([])
  m["code"] = Json::string(e.code())
  m["message"] = Json::string(e.to_string())
  m["exit"] = Json::number(error_exit_code(e).to_double())
  match e.retry_hint() {
    Some(h) => m["retry_hint"] = Json::string(h.to_prompt())
    None => ()
  }
  match error_offset(e) {
    Some(off) => m["offset"] = jnum(off)
    None => ()
  }
  Json::object(m)
}

///|
/// `{"id":…,"ok":true,"result":…}`.
fn response_ok(id : Json, result : Json) -> String {
  jobj([("id", id), ("ok", Json::boolean(true)), ("result", result)]).stringify()
}

///|
/// `{"id":…,"ok":false,"error":…}`.
fn response_err(id : Json, e : @lj.LIWENJSONError) -> String {
  jobj([("id", id), ("ok", Json::boolean(false)), ("error", error_json(e))]).stringify()
}

///|
/// The `hello` result: what this process is, what it can do, and which two
/// version numbers it carries.
fn hello_json() -> Json {
  let caps : Array[Json] = [
    Json::string("repair"),
    Json::string("analyze"),
    Json::string("validate"),
    Json::string("readiness"),
    Json::string("watch"),
    Json::string("llm"),
  ]
  jobj([
    ("name", Json::string("liwenjson")),
    ("engine", Json::string(ENGINE_VERSION)),
    ("registry", Json::string(REGISTRY_VERSION)),
    ("protocol", Json::number(PROTOCOL_VERSION.to_double())),
    ("capabilities", Json::array(caps)),
    ("streams", Json::number(1)),
  ])
}

///|
/// Read `text` from the request.
fn text_param(params : Map[String, Json]) -> String raise @lj.LIWENJSONError {
  match params.get("text") {
    Some(Json::String(s)) => s
    Some(_) => raise @lj.InvalidOption("`text` must be a string")
    None => raise @lj.InvalidOption("missing `text`")
  }
}

///|
/// Read a boolean parameter, or `fallback` when absent. A string, number or
/// null is refused: the published `inputSchema` says `boolean`, so the server
/// must not accept what the declaration rejects.
fn bool_param(
  params : Map[String, Json],
  key : String,
  fallback : Bool,
) -> Bool raise @lj.LIWENJSONError {
  match params.get(key) {
    Some(Json::True) => true
    Some(Json::False) => false
    Some(_) => raise @lj.InvalidOption("`" + key + "` must be a boolean")
    None => fallback
  }
}

///|
/// Read the `step` parameter of `readiness`: a whole number of bytes in
/// `0..=MAX_LINE`. `0` (the default and the only meaning the engine gives it)
/// selects the automatic step. Fractions, negatives, oversized values and
/// wrong types are refused *before* the walk sees them — truncating `0.5` to
/// `0` and running anyway is how a declaration stops matching its server.
fn step_param(params : Map[String, Json]) -> Int32 raise @lj.LIWENJSONError {
  let message = "`step` must be an integer in 0.." +
    MAX_LINE.to_string() +
    " (0 selects the automatic step)"
  match params.get("step") {
    None => 0
    Some(Json::Number(d, ..)) => {
      let limit = MAX_LINE.to_double()
      if d < 0.0 || d > limit || d != d.to_int().to_double() {
        raise @lj.InvalidOption(message)
      }
      d.to_int()
    }
    Some(_) => raise @lj.InvalidOption(message)
  }
}

///|
/// Join names for an error message.
fn joined_names(names : Array[String]) -> String {
  let mut out = ""
  for i, name in names {
    if i > 0 {
      out = out + ", "
    }
    out = out + name
  }
  out
}

///|
/// Refuse request fields the method does not implement. The tools publish
/// `additionalProperties: false`, so the shared `serve` handlers must reject
/// the same fields instead of silently ignoring them.
fn check_params(
  meth : String,
  params : Map[String, Json],
  allowed : Array[String],
) -> Unit raise @lj.LIWENJSONError {
  for key in params.keys() {
    let mut known = false
    for name in allowed {
      if name == key {
        known = true
      }
    }
    if !known {
      raise @lj.InvalidOption(
        "unknown `" +
        key +
        "` for `" +
        meth +
        "`; accepted: " +
        joined_names(allowed),
      )
    }
  }
}

///|
/// The fields `repair` implements. Kept next to the handler rather than in the
/// MCP layer so `serve` and MCP reject the same shapes.
fn repair_fields() -> Array[String] {
  ["text", "profile", "schema", "schema_json", "skip_prose", "max_loss"]
}

///|
/// The fields `analyze` implements: `repair` plus the opt-in rendered text.
fn analyze_fields() -> Array[String] {
  [
    "text", "profile", "schema", "schema_json", "skip_prose", "max_loss", "with_text",
  ]
}

///|
/// The caller's declaration: `schema_json` (JSON Schema subset) wins over
/// `schema` (the library's DSL).
fn schema_param(
  params : Map[String, Json],
) -> @lj.Schema? raise @lj.LIWENJSONError {
  match params.get("schema_json") {
    Some(v) => Some(@lj.Schema::of_json_schema(v))
    None =>
      match params.get("schema") {
        Some(Json::String(s)) => Some(@lj.Schema::parse(s))
        Some(_) => raise @lj.InvalidOption("`schema` must be a string")
        None => None
      }
  }
}

///|
/// Merge a request's `profile`/`skip_prose`/`max_loss` into the process
/// options. A profile replaces the safety fields and keeps the protocol fields
/// (`collect_deltas`, `want_text`, …), which is what `with_policy` exists for.
fn options_from_params(
  base : @lj.Options,
  params : Map[String, Json],
) -> @lj.Options raise @lj.LIWENJSONError {
  let mut opts = base
  match params.get("profile") {
    Some(Json::String(name)) =>
      match parse_policy_name(name) {
        // `with_profile`, not `with_policy`: a profile carries protocol as
        // well as safety, and `agent` implies prose skipping. See
        // `Options::with_profile`.
        Some(p) => opts = opts.with_profile(p)
        None =>
          raise @lj.InvalidOption(
            "unknown profile `" +
            name +
            "`; use permissive, interactive, execution, agent or strict",
          )
      }
    Some(_) => raise @lj.InvalidOption("`profile` must be a string")
    None => ()
  }
  match params.get("skip_prose") {
    Some(Json::True) => opts = { ..opts, skip_prose: true, }
    Some(Json::False) => opts = { ..opts, skip_prose: false, }
    Some(_) => raise @lj.InvalidOption("`skip_prose` must be a boolean")
    None => ()
  }
  match params.get("max_loss") {
    Some(Json::String(name)) =>
      match parse_max_loss(name) {
        Some(x) => opts = { ..opts, max_loss: x, }
        None =>
          raise @lj.InvalidOption(
            "unknown max_loss `" + name + "`; use exact, cosmetic or lossy",
          )
      }
    None => ()
    Some(_) => raise @lj.InvalidOption("`max_loss` must be a string")
  }
  opts
}

///|
/// One open stream per connection.
struct ServeState {
  mut watch_parser : @lj.PartialParser?
  mut watch_watcher : @lj.SemanticWatcher?
  mut llm_stream : @llm.ToolStream?
  /// Whether `initialize` has been answered. MCP is a session protocol: a
  /// request that arrives before the handshake is a bug in the client, and
  /// answering it anyway hides the bug behind a response the client cannot
  /// place. Only `initialize`, `ping` and notifications are answered before
  /// it; anything else gets `-32002`.
  /// The revision negotiated in `initialize`, which decides whether a JSON-RPC
  /// batch is accepted (audit 5.5).
  mut protocol_version : String
  mut initialized : Bool
}

///|
/// A fresh state.
fn ServeState::new() -> ServeState {
  {
    watch_parser: None,
    watch_watcher: None,
    llm_stream: None,
    initialized: false,
    protocol_version: "2025-06-18",
  }
}

///|
/// `repair`: one document in, one repaired document out.
///
/// The declaration is honoured, not merely accepted. In 1.5.1 and earlier this
/// method read `text` and the options and silently ignored `schema`/`schema_json`,
/// which meant an unsupported keyword (`$ref`, say) was accepted here while the
/// same declaration was refused with `E070` by every other method -- and a
/// caller that passed a declaration got back a document that violated it with
/// `ok: true`. The one-shot CLI already refuses a repaired value that does not
/// satisfy `--schema`, so the two entry points now agree: the declaration is
/// parsed (an unsupported keyword is `E070`) and a repaired value that violates
/// it is refused with the same sentence the gate uses.
fn handle_repair(
  params : Map[String, Json],
  base : @lj.Options,
) -> Json raise @lj.LIWENJSONError {
  check_params("repair", params, repair_fields())
  let text = text_param(params)
  let opts = options_from_params(base, params)
  let schema = schema_param(params)
  // The one-shot entry point, not a hand-rolled feed/finish: it also carries
  // the scalar-root retry that `skip_prose` needs, so `serve` cannot disagree
  // with `liwenjson repair`.
  let repaired = @lj.repair(text, options=opts)
  match schema {
    Some(s) => {
      // The repaired text is legal JSON by construction, so this parse cannot
      // raise for a reason the caller could act on.
      let value = @lj.parse(repaired.text).value
      let violation = @lj.schema_violation(s, value)
      if violation != "" {
        raise @lj.SchemaError(violation)
      }
    }
    None => ()
  }
  repair_out_json(repaired)
}

///|
/// `analyze`: the never-raising decision call, as the full plan object.
fn handle_analyze(
  params : Map[String, Json],
  base : @lj.Options,
) -> Json raise @lj.LIWENJSONError {
  check_params("analyze", params, analyze_fields())
  let text = text_param(params)
  let opts = options_from_params(base, params)
  let schema = schema_param(params)
  let plan = match schema {
    Some(s) => @lj.analyze(text, options=opts, schema=s)
    None => @lj.analyze(text, options=opts)
  }
  // `value` and `text` are the same document twice. A gate response used to
  // carry both, so a 1 MB tool-call argument produced ~3 MB of
  // `structuredContent` -- the payload, the rendered text, and the text channel.
  // `text` is now opt-in (`with_text`), because a caller that has `value` can
  // render it and the MCP gate never reads `text`.
  let with_text = bool_param(params, "with_text", false)
  @json.parse(plan.to_json_with_text(with_text)) catch {
    _ => raise @lj.InvalidState("the plan could not be serialised")
  }
}

///|
/// `validate`: is this text legal JSON, and (optionally) does it satisfy the
/// declaration? A repairable document is still invalid: this method reports
/// what is there, it does not repair.
fn handle_validate(
  params : Map[String, Json],
  base : @lj.Options,
) -> Json raise @lj.LIWENJSONError {
  check_params("validate", params, [
    "text", "profile", "schema", "schema_json", "skip_prose", "max_loss",
  ])
  let text = text_param(params)
  let schema = schema_param(params)
  if @lj.is_valid_json(text) {
    let result : Map[String, Json] = Map([])
    result["valid"] = Json::boolean(true)
    match schema {
      Some(s) => {
        let parsed = @lj.parse(text)
        let verdict = s.evaluate(parsed.value)
        result["schema"] = verdict_json(verdict)
      }
      None => ()
    }
    return Json::object(result)
  }
  // Not legal JSON: name the first repair the strict profile would have to
  // make, and the repaired text the lenient profile produces.
  let out : Map[String, Json] = Map([])
  out["valid"] = Json::boolean(false)
  let strict = try {
    ignore(@lj.repair(text, options=@lj.Options::strict()))
    None
  } catch {
    e => Some(e)
  }
  match strict {
    Some(e) => out["error"] = error_json(e)
    None => ()
  }
  let repaired = Some(
    @lj.repair(text, options=options_from_params(base, params)),
  ) catch {
    _ => None
  }
  match repaired {
    Some(r) => {
      out["repaired"] = Json::string(r.text)
      out["exactness"] = Json::string(r.exactness.name())
      out["ambiguous"] = Json::boolean(r.ambiguous)
      out["repairs"] = Json::array(r.repairs.map(repair_json))
    }
    None => ()
  }
  Json::object(out)
}

///|
/// `readiness`: the two fractions and the verdict, without a stream.
fn handle_readiness(
  params : Map[String, Json],
  base : @lj.Options,
) -> Json raise @lj.LIWENJSONError {
  check_params("readiness", params, [
    "text", "profile", "schema", "schema_json", "skip_prose", "max_loss", "step",
  ])
  let text = text_param(params)
  let step = step_param(params)
  match schema_param(params) {
    Some(s) => {
      let opts = options_from_params(base, params)
      let r = @lj.semantic_readiness(text, s, step~, options=opts)
      // The three aggregate fractions say *when the document as a whole* was
      // ready. The tool's description promises "when each required field
      // becomes final", which is a different question, and until now the
      // answer was not in the response: a caller that wanted to stop a
      // generation as soon as the arguments were settled had to re-derive it.
      // `watch_readiness` already computes exactly that, so the events are
      // returned, each with the input fraction it fired at.
      let events = @lj.watch_readiness(text, s, options=opts)
      let fields : Array[Json] = []
      for e in events {
        fields.push(
          jobj([
            ("event", Json::string(e.event.kind())),
            ("path", Json::string(e.event.path())),
            ("permille", jnum(e.permille)),
          ]),
        )
      }
      jobj([
        ("syntax_permille", jnum(r.syntax_permille)),
        ("schema_permille", jnum(r.schema_permille)),
        ("settled_permille", jnum(r.settled_permille)),
        ("step", jnum(r.step)),
        ("verdict", verdict_json(r.verdict)),
        ("events", Json::array(fields)),
      ])
    }
    None => {
      let p = @lj.syntax_readiness_permille(text, step~)
      jobj([
        ("syntax_permille", jnum(p)),
        ("schema_permille", jnum(-1)),
        ("settled_permille", jnum(-1)),
        ("step", jnum(if step > 0 { step } else { 0 })),
        ("events", Json::array([])),
      ])
    }
  }
}

///|
/// `watch.start`: open the single stream.
fn handle_watch_start(
  state : ServeState,
  params : Map[String, Json],
  base : @lj.Options,
) -> Json raise @lj.LIWENJSONError {
  if state.watch_parser is Some(_) {
    raise @lj.InvalidState(
      "a watch stream is already open; call `watch.finish` first",
    )
  }
  let schema = match schema_param(params) {
    Some(s) => s
    None => @lj.Schema::Any
  }
  let opts : @lj.Options = {
    ..options_from_params(base, params),
    collect_deltas: true,
  }
  state.watch_parser = Some(@lj.PartialParser::new(options=opts))
  state.watch_watcher = Some(@lj.SemanticWatcher::new(schema, options=opts))
  jobj([
    ("ok", Json::boolean(true)),
    ("schema", Json::string(schema.stringify())),
  ])
}

///|
/// `watch.feed`: one chunk in, deltas and readiness events out.
fn handle_watch_feed(
  state : ServeState,
  params : Map[String, Json],
) -> Json raise @lj.LIWENJSONError {
  let chunk = match params.get("chunk") {
    Some(Json::String(s)) => s
    Some(_) => raise @lj.InvalidOption("`chunk` must be a string")
    None => raise @lj.InvalidOption("missing `chunk`")
  }
  match (state.watch_parser, state.watch_watcher) {
    (Some(parser), Some(watcher)) => {
      parser.feed(chunk)
      watcher.feed(chunk)
      let deltas = parser.drain_deltas().map(delta_json)
      let events : Array[Json] = []
      for pair in watcher.drain_events_at() {
        events.push(event_json(pair.0, pair.1, watcher.bytes()))
      }
      jobj([
        ("deltas", Json::array(deltas)),
        ("events", Json::array(events)),
        ("bytes", jnum(watcher.bytes())),
      ])
    }
    _ => raise @lj.InvalidState("no active watch stream")
  }
}

///|
/// `watch.finish`: close the stream and return the final parse.
fn handle_watch_finish(state : ServeState) -> Json raise @lj.LIWENJSONError {
  match (state.watch_parser, state.watch_watcher) {
    (Some(parser), Some(watcher)) => {
      // Finish both halves before answering: a failing parser must not leave
      // the watcher un-run, and a failing watcher must not vanish. The first
      // error is re-raised as the original error object, so an empty stream
      // still reports `E001` rather than `E030 InvalidState: E001 ...`; and the
      // state is cleared either way, so the next `watch.start` works.
      let mut failure : @lj.LIWENJSONError? = None
      let fin = Some(parser.finish()) catch {
        e => {
          failure = Some(e)
          None
        }
      }
      let wfin = Some(watcher.finish()) catch {
        e => {
          if failure is None {
            failure = Some(e)
          }
          None
        }
      }
      let events : Array[Json] = []
      let fed = watcher.bytes()
      for pair in watcher.drain_events_at() {
        events.push(event_json(pair.0, pair.1, fed))
      }
      // The stream's own account of what it published: the verdict of the
      // finished value, whether a duplicate key re-opened a decided member
      // (`conflict`), and whether a published `RootReady` still stands. A host
      // that stops the model on `root_ready` needs the last one to know the
      // promise survived the rest of the stream; without `conflict` it cannot
      // tell a genuine rejection from a provisional one.
      let verdict = verdict_json(watcher.verdict())
      let conflict = watcher.conflict()
      let ready_standing = watcher.ready_standing()
      state.watch_parser = None
      state.watch_watcher = None
      match failure {
        Some(e) => raise e
        None => ()
      }
      match fin {
        Some(f) =>
          jobj([
            ("final", final_json(f)),
            ("events", Json::array(events)),
            (
              "watcher_final",
              match wfin {
                Some(w) => final_json(w)
                None => Json::null()
              },
            ),
            ("verdict", verdict),
            ("conflict", Json::boolean(conflict)),
            ("ready_standing", Json::boolean(ready_standing)),
          ])
        // Both finishes ran, so `fin` is `None` only when one of them failed,
        // and that error was re-raised above.
        None =>
          raise @lj.InvalidState("the watch stream produced no final parse")
      }
    }
    _ => raise @lj.InvalidState("no active watch stream")
  }
}

///|
/// The provider named by a request.
fn provider_param(
  params : Map[String, Json],
) -> @llm.Provider raise @lj.LIWENJSONError {
  match params.get("provider") {
    Some(Json::String(s)) =>
      if s == "anthropic" {
        @llm.Anthropic
      } else if s == "openai" || s == "openai_compat" {
        @llm.OpenAICompat
      } else {
        raise @lj.InvalidOption(
          "unknown provider `" + s + "`; use anthropic or openai",
        )
      }
    None => @llm.Anthropic
    Some(_) => raise @lj.InvalidOption("`provider` must be a string")
  }
}

///|
/// `llm.open`: open the single provider stream.
fn handle_llm_open(
  state : ServeState,
  params : Map[String, Json],
  base : @lj.Options,
) -> Json raise @lj.LIWENJSONError {
  if state.llm_stream is Some(_) {
    raise @lj.InvalidState(
      "a provider stream is already open; call `llm.close` first",
    )
  }
  let provider = provider_param(params)
  let opts = options_from_params(base, params)
  state.llm_stream = Some(@llm.ToolStream::new(provider, options=opts))
  jobj([
    ("ok", Json::boolean(true)),
    (
      "provider",
      Json::string(
        if provider is @llm.Anthropic {
          "anthropic"
        } else {
          "openai"
        },
      ),
    ),
  ])
}

///|
/// `llm.feed`: one event payload in, the calls it touched out.
fn handle_llm_feed(
  state : ServeState,
  params : Map[String, Json],
) -> Json raise @lj.LIWENJSONError {
  let event = match params.get("event") {
    Some(Json::String(s)) => s
    Some(_) => raise @lj.InvalidOption("`event` must be a string")
    None => raise @lj.InvalidOption("missing `event`")
  }
  match state.llm_stream {
    Some(stream) => {
      let views = stream.push_event(event)
      // The stream is a struct with mutable arrays; writing it back keeps the
      // state field authoritative even if the compiler copied it.
      state.llm_stream = Some(stream)
      jobj([("calls", Json::array(views.map(tool_call_json)))])
    }
    None => raise @lj.InvalidState("no active provider stream")
  }
}

///|
/// `llm.close`: finish every call and report the provider's verdict.
fn handle_llm_close(state : ServeState) -> Json raise @lj.LIWENJSONError {
  match state.llm_stream {
    Some(stream) => {
      let views = stream.finish()
      let err = stream.error()
      let ignored = stream.ignored_events()
      state.llm_stream = None
      jobj([
        ("calls", Json::array(views.map(tool_call_json))),
        ("error", Json::string(err)),
        ("ignored_events", jnum(ignored)),
        // Tool-call ids the framing repeated: the calls under them are
        // `executable: false`, and naming the ids is what lets a client tell a
        // rewritten stream from a model that made three calls.
        ("duplicate_ids", Json::array(stream.duplicate_ids().map(Json::string))),
      ])
    }
    None => raise @lj.InvalidState("no active provider stream")
  }
}

///|
/// `llm.run`: the stateless form, for a client that already has the whole
/// event list.
fn handle_llm_run(
  params : Map[String, Json],
  base : @lj.Options,
) -> Json raise @lj.LIWENJSONError {
  let provider = provider_param(params)
  let stream = @llm.ToolStream::new(
    provider,
    options=options_from_params(base, params),
  )
  match params.get("events") {
    Some(Json::Array(events)) =>
      for event in events {
        match event {
          Json::String(s) => {
            let _ = stream.push_event(s)
          }
          _ => raise @lj.InvalidOption("`events` must be an array of strings")
        }
      }
    Some(_) => raise @lj.InvalidOption("`events` must be an array of strings")
    None => ()
  }
  let views = stream.finish()
  jobj([
    ("calls", Json::array(views.map(tool_call_json))),
    ("error", Json::string(stream.error())),
    ("ignored_events", jnum(stream.ignored_events())),
    ("duplicate_ids", Json::array(stream.duplicate_ids().map(Json::string))),
  ])
}

///|
/// Dispatch one method.
fn handle_request(
  state : ServeState,
  base : @lj.Options,
  meth : String,
  params : Map[String, Json],
) -> Json raise @lj.LIWENJSONError {
  if meth == "hello" {
    hello_json()
  } else if meth == "repair" {
    handle_repair(params, base)
  } else if meth == "analyze" {
    handle_analyze(params, base)
  } else if meth == "validate" {
    handle_validate(params, base)
  } else if meth == "readiness" {
    handle_readiness(params, base)
  } else if meth == "watch.start" {
    handle_watch_start(state, params, base)
  } else if meth == "watch.feed" {
    handle_watch_feed(state, params)
  } else if meth == "watch.finish" {
    handle_watch_finish(state)
  } else if meth == "llm.open" {
    handle_llm_open(state, params, base)
  } else if meth == "llm.feed" {
    handle_llm_feed(state, params)
  } else if meth == "llm.close" {
    handle_llm_close(state)
  } else if meth == "llm.run" {
    handle_llm_run(params, base)
  } else {
    raise @lj.InvalidOption("unknown method `" + meth + "`")
  }
}

///|
/// The request's `id`, or `null` when it has none.
fn request_id(v : Json) -> Json {
  match v {
    Json::Object(m) =>
      match m.get("id") {
        Some(id) => id
        None => Json::null()
      }
    _ => Json::null()
  }
}

///|
/// The request's `method`, or `""`.
fn request_method(v : Json) -> String {
  match v {
    Json::Object(m) =>
      match m.get("method") {
        Some(Json::String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// The request's `params`, or an empty object.
fn request_params(v : Json) -> Map[String, Json] {
  match v {
    Json::Object(m) =>
      match m.get("params") {
        Some(Json::Object(p)) => p
        _ => Map([])
      }
    _ => Map([])
  }
}

///|
/// Why the request's `params` cannot be read, or `None`. A present-but-not-an-
/// object `params` used to be read as "no arguments" and surfaced as a
/// complaint about a missing `text`; it is a malformed request instead.
fn request_params_problem(v : Json) -> String? {
  match v {
    Json::Object(m) =>
      match m.get("params") {
        Some(Json::Object(_)) | Some(Json::Null) | None => None
        Some(_) => Some("`params` must be an object")
      }
    _ => None
  }
}

///|
/// Run the stdio protocol until EOF or `shutdown`.
fn run_serve(o : CliOpts) -> Unit {
  // `serve` is a long-lived protocol: one-shot options are usage errors here,
  // not flags to ignore. `--check` used to be accepted and silently did
  // nothing (`want_text` was the only thing it changed).
  if o.check {
    eprintln(
      "liwenjson: serve is a long-lived protocol and does not accept --check; run `liwenjson --check` for the one-shot check",
    )
    return quit(2)
  }
  match o.path {
    Some(_) => {
      eprintln(
        "liwenjson: serve reads standard input and does not accept a file path",
      )
      return quit(2)
    }
    None => ()
  }
  let stream = open_input(None)
  if stream == 0L {
    eprintln("liwenjson: 无法读取 <stdin>")
    return quit(3)
  }
  // Strict: a request frame that is not valid UTF-8 is refused as `E040`
  // before it can reach the JSON parser, and the connection keeps serving.
  let reader = LineReader::new_strict(stream)
  let base = options_of(o)
  let state = ServeState::new()
  let proto = open_output()
  let mut running = true
  while running {
    match reader.read_line() {
      None => running = false
      Some(line) => {
        if reader.invalid_utf8 {
          reader.invalid_utf8 = false
          write_line(
            proto,
            response_err(Json::null(), @lj.InvalidUtf8(reader.utf8_offset)),
          )
          continue
        }
        if reader.overflow {
          reader.overflow = false
          write_line(
            proto,
            jobj([
              ("id", Json::null()),
              ("ok", Json::boolean(false)),
              (
                "error",
                jobj([
                  ("code", Json::string("E050")),
                  (
                    "message",
                    Json::string(
                      "request line exceeds MAX_LINE (" +
                      MAX_LINE.to_string() +
                      " bytes)",
                    ),
                  ),
                  ("exit", Json::number(2)),
                ]),
              ),
            ]).stringify(),
          )
          continue
        }
        let trimmed = line.trim()
        if trimmed.length() == 0 {
          continue
        }
        let request = @json.parse(trimmed) catch {
          _ => {
            write_line(
              proto,
              jobj([
                ("id", Json::null()),
                ("ok", Json::boolean(false)),
                (
                  "error",
                  jobj([
                    ("code", Json::string("E060")),
                    ("message", Json::string("request is not valid JSON")),
                    ("exit", Json::number(3)),
                  ]),
                ),
              ]).stringify(),
            )
            continue
          }
        }
        let id = request_id(request)
        let meth = request_method(request)
        match request_params_problem(request) {
          Some(why) => {
            write_line(proto, response_err(id, @lj.InvalidOption(why)))
            continue
          }
          None => ()
        }
        let params = request_params(request)
        if meth == "shutdown" {
          write_line(
            proto,
            response_ok(
              id,
              jobj([("ok", Json::boolean(true)), ("bye", Json::boolean(true))]),
            ),
          )
          running = false
        } else if meth == "" {
          write_line(
            proto,
            response_err(id, @lj.InvalidOption("missing `method`")),
          )
        } else {
          let out = response_ok(id, handle_request(state, base, meth, params)) catch {
            e => response_err(id, e)
          }
          write_line(proto, out)
        }
      }
    }
  }
  close_input(stream)
  quit(0)
}
