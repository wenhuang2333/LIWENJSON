// P1-07 (audit §4 / §9.8): a `skip_prose` retry adopts the value it recovered,
// so everything derived from the finished parser — the `FinalResult`, the
// snapshot taken after `finish`, the delta replay and the readiness channel —
// has to describe that same value. The audit could not reproduce a
// caller-visible contradiction; this test pins the contract so that a later
// retry change cannot reintroduce one. The repair-needing half of the corpus is
// what the retry exists for: a bare literal reaches `finish` through a valid
// scalar replay, `'ok'`/`+1`/a fenced `42` only through a value-preserving
// repair applied by the second engine. Documents the agent profile refuses are
// part of the corpus too: the retry has to refuse them with the same code
// rather than hide the refusal behind the original `E002`.

///|
/// The audited corpus: scalar roots recovered by `finish`'s replay.
fn rt_retry_docs() -> Array[String] {
  [
    "42", "true", "\"ok\"", "'ok'", "True", "False", "None", "+1", ".5", "1.", "007",
    "42 // done", "```json\n42\n```", "  42  ",
  ]
}

///|
/// Everything a caller can read off one `FinalResult`, flattened.
fn rt_meta(f : FinalResult) -> String {
  f.text +
  " | " +
  f.value.stringify() +
  " | " +
  recs_text(f.repairs) +
  " | " +
  f.exactness.name() +
  " | " +
  f.ambiguous.to_string()
}

///|
/// `repair`, with the refusal kept instead of raised.
fn rt_try_repair(doc : String, opts : Options) -> RepairResult? {
  Some(repair(doc, options=opts)) catch {
    _ => None
  }
}

///|
/// The refusal code of `repair`, or `accepted`.
fn rt_err(doc : String, opts : Options) -> String {
  try {
    ignore(repair(doc, options=opts))
    "accepted"
  } catch {
    e => err_text(e)
  }
}

///|
/// Feed `chunks`, finish, and return the final result with the snapshot taken
/// after `finish`.
fn rt_parse(
  doc : String,
  chunks : Array[String],
  opts : Options,
) -> (FinalResult, Snapshot) raise {
  let p = PartialParser::new(options=opts) catch {
    e => fail(doc + ": " + err_text(e))
  }
  for c in chunks {
    p.feed(c) catch {
      e => fail(doc + " feed: " + err_text(e))
    }
  }
  let fin = p.finish() catch { e => fail(doc + " finish: " + err_text(e)) }
  (fin, p.snapshot())
}

///|
test "P1-07: a retried root is one value for every channel" {
  let base = Options::for_agent()
  let strict = { ..base, skip_prose: false, }
  let any_schema = Schema::parse("any") catch { e => fail(err_text(e)) }
  for doc in rt_retry_docs() {
    match (rt_try_repair(doc, base), rt_try_repair(doc, strict)) {
      (None, None) =>
        // Both paths refuse, and for the same reason: a retry that fails must
        // re-raise the real refusal, not the `E002` of the run that could not
        // see the value.
        assert_eq(rt_err(doc, base), rt_err(doc, strict), msg=doc)
      (Some(skipped), Some(direct)) => {
        // 1. Reading the document with `skip_prose` is indistinguishable from
        // reading it without: same text, same repairs, same exactness/ambiguity.
        assert_eq(skipped.text, direct.text, msg=doc)
        assert_eq(
          recs_text(skipped.repairs),
          recs_text(direct.repairs),
          msg=doc,
        )
        assert_eq(skipped.exactness.name(), direct.exactness.name(), msg=doc)
        assert_eq(skipped.ambiguous, direct.ambiguous, msg=doc)
        assert_eq(direct.repairs.length(), skipped.repairs.length(), msg=doc)
        // 2. The whole input in one piece and one byte at a time produce the
        // same `FinalResult`, and it is the value the repair path accepted.
        let (whole, snap_whole) = rt_parse(doc, [doc], base)
        let units : Array[String] = []
        for i = 0; i < doc.length(); i = i + 1 {
          units.push(slice_units(doc, i, i + 1))
        }
        let (chunked, snap_chunked) = rt_parse(doc, units, base)
        assert_eq(rt_meta(chunked), rt_meta(whole), msg=doc)
        assert_eq(chunked.text, direct.text, msg=doc)
        assert_eq(chunked.value.stringify(), direct.text, msg=doc)
        assert_true(chunked.completeness == Complete, msg=doc)
        // 3. The snapshot taken after `finish` reports the same value and the
        // same verdict as the `FinalResult` — it is the channel a streaming
        // caller reads, so a lagging exactness/ambiguity here would be exactly
        // the contradiction the audit was looking for. Before the fix,
        // `'ok'` finished `cosmetic` while the snapshot said `exact`.
        assert_eq(
          snap_chunked.value.unwrap().stringify(),
          chunked.value.stringify(),
          msg=doc,
        )
        assert_true(snap_chunked.completeness == Complete, msg=doc)
        assert_eq(
          snap_chunked.exactness.name(),
          chunked.exactness.name(),
          msg=doc,
        )
        assert_eq(snap_chunked.ambiguous, chunked.ambiguous, msg=doc)
        assert_eq(
          snap_whole.exactness.name(),
          snap_chunked.exactness.name(),
          msg=doc,
        )
        assert_eq(
          snap_whole.completeness == snap_chunked.completeness,
          true,
          msg=doc,
        )
        // 4. Replaying the deltas reproduces the value, at every chunk boundary
        // and after `finish` (the retry's deltas have to be adopted, or the
        // stream describes a different document than the one `finish` accepted).
        dj_check(doc, base, tc_lcg(20261120L), "P1-07")
        // 5. The readiness channel reaches the same conclusion: a value the
        // parse just accepted must be announced, not refused (audit 5.3 in its
        // repaired form, now for repair-needing scalars too).
        let w = SemanticWatcher::new(any_schema, options=base) catch {
          e => fail(doc + ": " + err_text(e))
        }
        for c in units {
          w.feed(c) catch {
            e => fail(doc + " watcher feed: " + err_text(e))
          }
        }
        ignore_finish(w)
        let events = w.drain_events()
        assert_true(has_kind(events, "root_ready"), msg=doc)
        assert_eq(w.verdict().ok, true, msg=doc)
      }
      _ =>
        fail(
          doc +
          ": skip_prose and the direct read disagree about whether the document is acceptable",
        )
    }
  }
}
