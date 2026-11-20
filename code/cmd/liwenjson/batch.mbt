// `liwenjson --batch` — a machine readable driver for evaluation harnesses.
//
// One JSON object per input line on standard input:
//
//   {"id": "m-0001", "input": "<text to repair>"}
//
// and one JSON object per result line on standard output:
//
//   {"id": "m-0001", "rc": 0, "exactness": "lossy",
//    "codes": ["R009", "R010"], "value": {...}, "text": "..."}
//
// `value` is the parsed value, or `null` when the run failed. This exists so
// that a harness can measure thousands of cases without paying one process per
// case; it is the only reason the command line knows about JSON input.
//
// Three properties this driver owes its callers, all of them bugs once:
//
//  * one answer per line, *while the producer is still writing* — a batch can
//    be an interactive harness, so nothing may wait for end of input (audit
//    5.6). That means writing through `open_output`/`write_line_or_exit`, not
//    through `println`, whose buffer is only flushed at exit;
//  * the same verdict a single document would get, including `--schema`: a
//    declaration that is a gate on one path cannot be decoration on the other
//    (`E070`, exit code 5 per line, the run continues);
//  * a line that is not valid UTF-8 is a structured error (`E040`), not a
//    document with replacement characters silently substituted for bytes that
//    were never text.

///|
/// Read all of standard input as text.
///
/// The stream is decoded once, not chunk by chunk. Decoding each 64 KiB piece
/// on its own looks equivalent and is not: a multi-byte character that
/// straddles a chunk boundary is a malformed sequence in *both* pieces, so a
/// lossy decode turns it into two U+FFFD replacement characters. For Chinese
/// text and emoji that is a silent wrong result — the command reports success
/// and the document it read is not the document that was written. Reading the
/// bytes first and decoding once removes the boundary entirely.
fn read_all(stream : Int64) -> String {
  // `stream` is a stdio `FILE *`, the same handle the single document path
  // reads from.
  let all : Array[Byte] = []
  let mut piece = read_chunk(stream, 65536)
  while piece.length() > 0 {
    for i = 0; i < piece.length(); i = i + 1 {
      all.push(piece[i])
    }
    piece = read_chunk(stream, 65536)
  }
  @utf8.decode_lossy(Bytes::from_array(all[:])[:])
}

///|
/// Feed `input` as one piece, or in `chunk` byte pieces. Byte boundaries are
/// honoured literally, so a chunk may split a UTF-8 sequence or a surrogate
/// pair; that is the point of the streaming check.
fn feed_in_chunks(
  p : @lj.PartialParser,
  input : String,
  chunk : Int32,
) -> Unit raise @lj.LIWENJSONError {
  let bs = @utf8.encode(input)
  let n = bs.length()
  if chunk <= 0 {
    p.feed_bytes(bs)
    return
  }
  let mut i = 0
  while i < n {
    let to = if i + chunk > n { n } else { i + chunk }
    p.feed_bytes(Bytes::makei(to - i, j => bs[i + j]))
    i = to
  }
}

///|
/// Largest batch line accepted. A line above it is discarded up to the next LF
/// and answered with an error instead of being allowed to grow the process.
const BATCH_MAX_LINE : Int32 = 8388608

///|
/// One read of the batch reader.
enum BatchLineResult {
  /// End of input.
  BatchEof
  /// One complete line, without the LF.
  BatchText(String)
  /// The line was longer than `BATCH_MAX_LINE` and has been discarded.
  BatchOverflow
  /// The line's bytes are not valid UTF-8.
  BatchInvalidUtf8
}

///|
/// Line reader over standard input.
///
/// `fread` is asked for exactly one byte at a time: a larger read blocks until
/// the whole buffer is full on a pipe, which would make an interactive batch
/// wait for 64 KiB before answering. The stdio layer still buffers the
/// descriptor, so this is a function call per byte, not a syscall per byte.
///
/// The bytes of a line are decoded only once the line is complete
/// (`@utf8.decode`, which rejects malformed sequences) and never with
/// `decode_lossy`: the frame is protocol, and a frame that was not text must
/// not turn into a document with U+FFFD in it. A *legal* U+FFFD in the input
/// decodes exactly (it is a well-formed three-byte sequence), so it is not
/// rejected by this strictness.
struct BatchReader {
  stream : Int64
  one : Bytes
  mut acc : Array[Byte]
}

///|
/// A reader over `stream`.
fn BatchReader::new(stream : Int64) -> BatchReader {
  { stream, one: Bytes::make(1, b'\x00'), acc: [], }
}

///|
/// Decode the bytes of one line, reporting malformed UTF-8 instead of
/// substituting replacement characters.
fn decode_batch_line(bytes : Array[Byte]) -> BatchLineResult {
  let b = Bytes::from_array(bytes[:])
  let text = @utf8.decode(b[:]) catch { _ => return BatchInvalidUtf8 }
  BatchText(text)
}

///|
/// The next line, without the LF, or `BatchEof` at end of input.
fn BatchReader::read_line(self : BatchReader) -> BatchLineResult {
  self.acc = []
  while true {
    let c = read_byte(self.stream, self.one)
    if c < 0 {
      if self.acc.length() == 0 {
        return BatchEof
      }
      return decode_batch_line(self.acc)
    }
    if c == 0x0A {
      return decode_batch_line(self.acc)
    }
    if self.acc.length() >= BATCH_MAX_LINE {
      // Discard the rest of the line so the next read starts at a line
      // boundary; the caller answers with an error for this one.
      while true {
        let d = read_byte(self.stream, self.one)
        if d < 0 || d == 0x0A {
          break
        }
      } nobreak {
        ()
      }
      self.acc = []
      return BatchOverflow
    }
    self.acc.push(c.to_byte())
  } nobreak {
    BatchEof
  }
}

///|
/// Open the result object: `{"id":...,"rc":N`.
fn batch_open(sb : StringBuilder, id : String, rc : Int32) -> Unit {
  sb.write_string("{\"id\":")
  sb.write_string(Json::string(id).stringify())
  sb.write_string(",\"rc\":")
  sb.write_string(rc.to_string())
}

///|
/// The success half of a result line, after the `rc`.
fn batch_value_fields(sb : StringBuilder, r : @lj.FinalResult) -> Unit {
  sb.write_string(",\"exactness\":")
  sb.write_string(Json::string(r.exactness.name()).stringify())
  sb.write_string(",\"ambiguous\":")
  sb.write_string(if r.ambiguous { "true" } else { "false" })
  sb.write_string(",\"codes\":[")
  for i = 0; i < r.repairs.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(Json::string(r.repairs[i].code.code()).stringify())
  }
  sb.write_string("],\"value\":")
  sb.write_string(r.value.stringify())
  sb.write_string(",\"text\":")
  sb.write_string(Json::string(r.text).stringify())
}

///|
/// A failure line: no value, no text, the engine code and a short reason.
fn batch_failure_fields(
  sb : StringBuilder,
  code : String,
  reason : String,
) -> Unit {
  sb.write_string(
    ",\"exactness\":\"none\",\"ambiguous\":false,\"codes\":[],\"value\":null,\"text\":\"\",\"error_code\":" +
    Json::string(code).stringify() +
    ",\"error\":" +
    Json::string(reason).stringify(),
  )
}

///|
/// One line answered without a document at all (the frame itself is unusable).
fn batch_frame_error(
  id : String,
  rc : Int32,
  code : String,
  reason : String,
) -> String {
  let sb = StringBuilder()
  batch_open(sb, id, rc)
  batch_failure_fields(sb, code, reason)
  sb.write_string("}")
  sb.to_string()
}

///|
/// Outcome of one batch input, rendered as one JSON object.
///
/// The gate is the same one the single document path applies: a value that does
/// not satisfy the declaration is `E070` / exit code 5 per line, and the run
/// continues with the next line instead of stopping or, worse, reporting the
/// value as a success.
fn batch_line(
  id : String,
  input : String,
  opts : @lj.Options,
  schema : @lj.Schema?,
  chunk : Int32,
) -> String {
  let sb = StringBuilder()
  let rc = try {
    let p = @lj.PartialParser::new(options=opts)
    feed_in_chunks(p, input, chunk)
    let r = p.finish()
    let mut verdict_ok = true
    match schema {
      Some(s) => if !s.evaluate(r.value).ok { verdict_ok = false }
      None => ()
    }
    if verdict_ok {
      batch_open(sb, id, 0)
      batch_value_fields(sb, r)
      0
    } else {
      batch_open(sb, id, 5)
      batch_failure_fields(sb, "E070", "schema not satisfied")
      5
    }
  } catch {
    e => {
      batch_open(sb, id, error_exit_code(e))
      batch_failure_fields(sb, e.code(), "")
      error_exit_code(e)
    }
  }
  ignore(rc)
  sb.write_string("}")
  sb.to_string()
}

///|
/// Run the batch driver over standard input.
fn run_batch(opts : @lj.Options, schema : @lj.Schema?, chunk : Int32) -> Unit {
  let stream = open_input(None)
  if stream == 0L {
    eprintln("liwenjson: cannot read <stdin>")
    quit(3)
  }
  // The result stream is opened and checked before the first line is read: a
  // process whose stdout cannot be written must say so, not run a whole corpus
  // and leave the caller waiting for answers that cannot arrive.
  let out = open_output()
  if out == 0L {
    eprintln("liwenjson: cannot open stdout for writing")
    quit(IO_ERROR_EXIT)
  }
  // The input is read a line at a time, not with one `read_all`. A batch is a
  // harness driver: it is fed thousands of cases, and reading the whole of
  // standard input before answering the first one made the process hold the
  // entire corpus in memory and answer nothing until the input ended (audit
  // 5.6).
  let reader = BatchReader::new(stream)
  let mut n = 0
  while true {
    match reader.read_line() {
      BatchEof => break
      BatchOverflow => {
        write_line_or_exit(
          out,
          batch_frame_error(
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
          batch_frame_error(
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
              batch_frame_error(
                fallback, 2, "E060", "input line is not valid JSON",
              ),
            )
            continue
          }
        }
        let real_id = match v {
          Json::Object(m) =>
            match m.get("id") {
              Some(Json::String(s)) => s
              _ => fallback
            }
          _ => fallback
        }
        let input = match v {
          Json::Object(m) =>
            match m.get("input") {
              Some(Json::String(s)) => s
              _ => ""
            }
          _ => ""
        }
        write_line_or_exit(out, batch_line(real_id, input, opts, schema, chunk))
      }
    }
  }
  close_input(stream)
}
