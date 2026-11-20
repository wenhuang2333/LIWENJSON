// `liwenjson llm` — drive the provider adapters from a recorded event stream.
//
//   liwenjson llm --provider anthropic < events.jsonl
//   liwenjson llm --provider openai --sse < response.txt
//   liwenjson llm --follow ...        # one line per update instead of per call
//
// This is the command line face of FR-23: it makes the adapters usable on a
// captured stream without writing any code, and it is what the demo page and
// the fixtures are checked against.

///|
/// The exact sentinel a Chat Completions stream ends with.
const SSE_DONE : String = "[DONE]"

///|
/// Split a recorded stream into event payloads, dropping the `[DONE]`
/// terminator.
///
/// `data: [DONE]` is not JSON and is not an event: it is the standard
/// end-of-stream marker. Feeding it to the JSON reader raised `E060` after a
/// perfectly good stream and, worse, discarded the calls already accumulated
/// (audit 5.1).
fn llm_payloads(text : String, sse : Bool) -> Array[String] {
  let out : Array[String] = []
  if sse {
    let b = @llm.SseBuffer::new()
    for e in b.push(text) {
      push_payload(out, e)
    }
    for e in b.flush() {
      push_payload(out, e)
    }
  } else {
    for line in text.split("\n") {
      push_payload(out, line.to_owned())
    }
  }
  out
}

///|
/// Append one payload unless it is the `[DONE]` sentinel or empty.
fn push_payload(out : Array[String], payload : String) -> Unit {
  let trimmed = payload.trim()
  if trimmed == "" || trimmed == SSE_DONE {
    return
  }
  out.push(payload)
}

///|
/// One result line, in the same shape as `--batch`.
fn llm_line(v : @llm.ToolCallView) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"choice\":")
  sb.write_string(v.choice.to_string())
  sb.write_string(",\"index\":")
  sb.write_string(v.index.to_string())
  sb.write_string(",\"id\":")
  sb.write_string(Json::string(v.id).stringify())
  sb.write_string(",\"name\":")
  sb.write_string(Json::string(v.name).stringify())
  sb.write_string(",\"done\":")
  sb.write_string(if v.done { "true" } else { "false" })
  sb.write_string(",\"exactness\":")
  sb.write_string(Json::string(v.exactness.name()).stringify())
  sb.write_string(",\"end\":")
  sb.write_string(Json::string(v.end.name()).stringify())
  sb.write_string(",\"stop_reason\":")
  sb.write_string(Json::string(v.stop_reason).stringify())
  // The one field a host must read before executing: a filtered or refused
  // response is not a normal end even when its arguments parse exactly.
  sb.write_string(",\"executable\":")
  sb.write_string(v.is_executable().to_string())
  sb.write_string(",\"value\":")
  match v.snapshot.value {
    Some(x) => sb.write_string(x.stringify())
    None => sb.write_string("null")
  }
  sb.write_string("}")
  sb.to_string()
}

///|
/// Provider named on the command line.
fn provider_of(name : String) -> @llm.Provider? {
  // `openai` keeps meaning Chat Completions: it is what every recorded fixture
  // and the demo use. The Responses API has its own name so that a stream can
  // never be read by the wrong reader -- that is exactly how a real Responses
  // stream produced zero calls and exit 0 (audit 3.5).
  if name == "openai" || name == "openai-chat" {
    Some(@llm.OpenAICompat)
  } else if name == "openai-responses" || name == "responses" {
    Some(@llm.OpenAIResponses)
  } else if name == "anthropic" {
    Some(@llm.Anthropic)
  } else {
    None
  }
}

///|
/// One `{"id", "events"}` batch line: feed every event payload of `events` and
/// render the finished calls. Used by the evaluation harness to run the same
/// corpus through the adapter path.
fn llm_batch_line(
  id : String,
  events : Array[String],
  provider : @llm.Provider,
  options : @lj.Options,
) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"id\":")
  sb.write_string(Json::string(id).stringify())
  sb.write_string(",\"rc\":")
  let mut rc = 0
  let calls : Array[String] = []
  try {
    let s = @llm.ToolStream::new(provider, options~)
    for e in events {
      ignore(s.push_event(e))
    }
    for v in s.finish() {
      calls.push(llm_line(v))
    }
  } catch {
    e => {
      rc = error_exit_code(e)
      calls.push("{\"error\":" + Json::string(e.to_string()).stringify() + "}")
    }
  }
  sb.write_string(rc.to_string())
  sb.write_string(",\"calls\":[")
  for i = 0; i < calls.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(calls[i])
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
/// One error line for a batch frame that could not be decoded.
fn llm_frame_error(
  id : String,
  rc : Int32,
  code : String,
  reason : String,
) -> String {
  "{\"id\":" +
  Json::string(id).stringify() +
  ",\"rc\":" +
  rc.to_string() +
  ",\"calls\":[],\"error_code\":" +
  Json::string(code).stringify() +
  ",\"error\":" +
  Json::string(reason).stringify() +
  "}"
}

///|
/// Run the `llm` subcommand in `--batch` mode: one `{"id","events"}` object per
/// input line, one result line per input.
///
/// Lines are read and answered one at a time through the checked writers, for
/// the same reasons as `--batch`: a harness may feed this interactively, and a
/// line that is not valid UTF-8 is a structured error, not a document with
/// U+FFFD substituted for bytes that were never text.
fn run_llm_batch(provider : @llm.Provider, options : @lj.Options) -> Unit {
  let stream = open_input(None)
  if stream == 0L {
    eprintln("liwenjson: cannot read <stdin>")
    quit(3)
  }
  let out = open_output()
  if out == 0L {
    eprintln("liwenjson: cannot open stdout for writing")
    quit(IO_ERROR_EXIT)
  }
  let reader = BatchReader::new(stream)
  let mut n = 0
  while true {
    match reader.read_line() {
      BatchEof => break
      BatchOverflow => {
        write_line_or_exit(
          out,
          llm_frame_error(
            "line-" + n.to_string(),
            2,
            "E021",
            "input line exceeds MAX_LINE",
          ),
        )
        n = n + 1
      }
      BatchInvalidUtf8 => {
        write_line_or_exit(
          out,
          llm_frame_error(
            "line-" + n.to_string(),
            3,
            "E040",
            "input line is not valid UTF-8",
          ),
        )
        n = n + 1
      }
      BatchText(line) => {
        if line.length() == 0 {
          continue
        }
        let fallback = "line-" + n.to_string()
        n = n + 1
        let v = @json.parse(line) catch {
          _ => {
            write_line_or_exit(
              out,
              llm_frame_error(
                fallback, 2, "E060", "input line is not valid JSON",
              ),
            )
            continue
          }
        }
        let (id, events) = llm_batch_fields(v, fallback)
        write_line_or_exit(out, llm_batch_line(id, events, provider, options))
      }
    }
  }
  close_input(stream)
  quit(0)
}

///|
/// One line for the text path: the same shape as one tool call, so a harness
/// can read either with the same code.
fn text_line(
  snapshot : Json?,
  exactness : @lj.Exactness,
  end : @llm.CallEnd,
  stop_reason : String,
) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"index\":0,\"id\":\"\",\"name\":\"\",\"done\":")
  sb.write_string(if end is @llm.Open { "false" } else { "true" })
  sb.write_string(",\"exactness\":")
  sb.write_string(Json::string(exactness.name()).stringify())
  sb.write_string(",\"end\":")
  sb.write_string(Json::string(end.name()).stringify())
  sb.write_string(",\"stop_reason\":")
  sb.write_string(Json::string(stop_reason).stringify())
  sb.write_string(",\"executable\":")
  sb.write_string(
    (end is @llm.Complete && !(exactness is @lj.Lossy)).to_string(),
  )
  sb.write_string(",\"value\":")
  match snapshot {
    Some(x) => sb.write_string(x.stringify())
    None => sb.write_string("null")
  }
  sb.write_string("}")
  sb.to_string()
}

///|
/// The `id` and `events` of one `llm --batch` input line.
///
/// An event may be given either as an embedded JSON object or as a string that
/// holds one; both forms are accepted, because a caller who builds the line by
/// hand writes the first and a caller who pipes through `json.dumps` writes the
/// second.
fn llm_batch_fields(v : Json, fallback : String) -> (String, Array[String]) {
  match v {
    Json::Object(m) => {
      let id = match m.get("id") {
        Some(Json::String(s)) => s
        _ => fallback
      }
      let out : Array[String] = []
      match m.get("events") {
        Some(Json::Array(a)) =>
          for item in a {
            match item {
              Json::String(s) => out.push(s)
              other => out.push(other.stringify())
            }
          }
        _ => ()
      }
      (id, out)
    }
    _ => (fallback, [])
  }
}

///|
/// Run the text path over a batch of `{"id","events"}` lines.
fn run_llm_text_batch(provider : @llm.Provider, options : @lj.Options) -> Unit {
  let stream = open_input(None)
  if stream == 0L {
    eprintln("liwenjson: cannot read <stdin>")
    quit(3)
  }
  let out = open_output()
  if out == 0L {
    eprintln("liwenjson: cannot open stdout for writing")
    quit(IO_ERROR_EXIT)
  }
  let reader = BatchReader::new(stream)
  let mut n = 0
  while true {
    match reader.read_line() {
      BatchEof => break
      BatchOverflow => {
        write_line_or_exit(
          out,
          llm_frame_error(
            "line-" + n.to_string(),
            2,
            "E021",
            "input line exceeds MAX_LINE",
          ),
        )
        n = n + 1
      }
      BatchInvalidUtf8 => {
        write_line_or_exit(
          out,
          llm_frame_error(
            "line-" + n.to_string(),
            3,
            "E040",
            "input line is not valid UTF-8",
          ),
        )
        n = n + 1
      }
      BatchText(line) => {
        if line.length() == 0 {
          continue
        }
        let fallback = "line-" + n.to_string()
        n = n + 1
        let v = @json.parse(line) catch {
          _ => {
            write_line_or_exit(
              out,
              llm_frame_error(
                fallback, 2, "E060", "input line is not valid JSON",
              ),
            )
            continue
          }
        }
        let (id, events) = llm_batch_fields(v, fallback)
        let sb = StringBuilder()
        sb.write_string("{\"id\":")
        sb.write_string(Json::string(id).stringify())
        sb.write_string(",\"rc\":")
        let mut rc = 0
        let mut line_body = text_line(None, @lj.Exact, @llm.Interrupted, "")
        try {
          // The text path uses the command line as given. `--skip-prose` is what
          // makes it read a chat answer that introduces its JSON with a
          // sentence; it is not the default because a scalar root (`0`, `"x"`)
          // would then be mistaken for prose and skipped.
          let s = @llm.TextStream::new(provider, options~)
          for e in events {
            ignore(s.push_event(e))
          }
          let end = s.end()
          let reason = s.stop_reason()
          match s.finish() {
            Some(f) =>
              line_body = text_line(Some(f.value), f.exactness, end, reason)
            None => line_body = text_line(None, @lj.Exact, end, reason)
          }
        } catch {
          e => {
            rc = error_exit_code(e)
            line_body = "{\"error\":" +
              Json::string(e.to_string()).stringify() +
              "}"
          }
        }
        sb.write_string(rc.to_string())
        sb.write_string(",\"calls\":[")
        sb.write_string(line_body)
        sb.write_string("]}")
        write_line_or_exit(out, sb.to_string())
      }
    }
  }
  close_input(stream)
  quit(0)
}

///|
/// Run the `llm` subcommand.
fn run_llm(o : CliOpts) -> Unit {
  let provider = match provider_of(o.provider) {
    Some(p) => p
    None => {
      eprintln(
        "liwenjson: --provider 需要 anthropic、openai（Chat Completions）或 openai-responses（Responses API）",
      )
      return quit(2)
    }
  }
  // One options source for every path. The command line is parsed once by
  // `options_of` (which is also where `--policy` and `--strict` are applied),
  // and the adapter only adds what belongs to the adapter — delta tracking.
  // The old code rebuilt the options from `for_llm()` and copied three fields
  // by hand, so `--strict`, `--policy` and every resource limit were silently
  // dropped on this path: `llm --strict` on `{"a":1,}` answered
  // executable=true / exactness=cosmetic and exit 0 (audit P0-03).
  let options : @lj.Options = { ..options_of(o), collect_deltas: true, }
  if o.batch {
    if o.text {
      run_llm_text_batch(provider, options)
    }
    run_llm_batch(provider, options)
  }
  // The result stream is checked before the input is read: stdout that cannot
  // be written is reported, not discovered after a whole document was parsed.
  let out = open_output()
  if out == 0L {
    eprintln("liwenjson: cannot open stdout for writing")
    return quit(IO_ERROR_EXIT)
  }
  if o.text {
    // The single stream form: the whole input is one stream of text deltas.
    let stream = open_input(o.path)
    if stream == 0L {
      eprintln("liwenjson: 无法读取输入")
      return quit(3)
    }
    let body = read_all_or_exit(stream)
    close_input(stream)
    let payloads = llm_payloads(body, o.sse)
    try {
      // The text path uses the command line as given. `--skip-prose` is what
      // makes it read a chat answer that introduces its JSON with a sentence;
      // it is not the default because a scalar root (`0`, `"x"`) would then be
      // mistaken for prose and skipped.
      let s = @llm.TextStream::new(provider, options~)
      for p in payloads {
        ignore(s.push_event(p))
      }
      let end = s.end()
      let reason = s.stop_reason()
      match s.finish() {
        Some(f) =>
          write_line_or_exit(
            out,
            text_line(Some(f.value), f.exactness, end, reason),
          )
        None => write_line_or_exit(out, text_line(None, @lj.Exact, end, reason))
      }
      let provider_error = s.error()
      if provider_error != "" {
        eprintln("liwenjson: provider error: " + provider_error)
        quit(4)
      }
      quit(0)
    } catch {
      e => {
        // The documentation already gives each failure its own exit code
        // (strict violation 5, resource limit 4, ...); mapping every exception
        // to 3 hid the difference between "the input is invalid" and "the
        // caller asked for something that cannot be granted" (audit P0-03).
        eprintln("liwenjson: " + e.to_string())
        quit(error_exit_code(e))
      }
    }
  }
  let stream = open_input(o.path)
  if stream == 0L {
    eprintln("liwenjson: 无法读取输入")
    return quit(3)
  }
  let text = read_all_or_exit(stream)
  close_input(stream)
  let payloads = llm_payloads(text, o.sse)
  try {
    let s = @llm.ToolStream::new(provider, options~)
    // `--follow` prints updates as they arrive; without it only the final view
    // of each call is printed. Either way the *final* view is printed once, so
    // a call that ends during `finish()` -- a truncated stream, a stream with
    // no terminator -- is reported, and a provider error is a non-zero exit
    // (audit 5.2).
    for p in payloads {
      for v in s.push_event(p) {
        if o.follow {
          write_line_or_exit(out, llm_line(v))
        }
      }
    }
    let finals = s.finish()
    if o.follow {
      // The final view of every call, so a reader of the follow stream can see
      // the last word even though it was printed as an update earlier. The
      // lines are de-duplicated against what the updates already said by the
      // `done` flag: only calls that ended during `finish()` are re-printed.
      for v in finals {
        if v.end is @llm.Interrupted || v.end is @llm.MaxTokens {
          write_line_or_exit(out, llm_line(v))
        }
      }
    } else {
      for v in finals {
        write_line_or_exit(out, llm_line(v))
      }
    }
    let unknown = s.unsupported_events()
    if unknown.length() > 0 {
      // Visible, not silent: a reader that skipped an event it did not know
      // says which ones, so "no tool calls" is a statement rather than an
      // assumption.
      eprintln(
        "liwenjson: 跳过了本版本不认识的 " +
        unknown.length().to_string() +
        " 个事件: " +
        unknown.join(", "),
      )
    }
    let provider_error = s.error()
    if provider_error != "" {
      eprintln("liwenjson: provider error: " + provider_error)
      quit(4)
    }
    quit(0)
  } catch {
    e => {
      eprintln("liwenjson: " + e.to_string())
      quit(error_exit_code(e))
    }
  }
}
