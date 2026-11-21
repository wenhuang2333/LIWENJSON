// FR-36 — Schema-aware readiness: not "is this valid JSON", but "how much of
// what the caller needs do I already have".
//
// The library has never been and is still not a JSON Schema validator. There is
// no `$ref`, no `oneOf`, no `format`, no `pattern`, and no plan to add them:
// validating a finished document is a solved problem with mature
// implementations, and LIWENJSON's contribution is the streaming half.
//
// What a streaming consumer actually knows that the document does not is *what
// it is waiting for*. A tool call declares its arguments; a UI declares the
// three fields it renders. Given that declaration, "readiness" stops being
// "the JSON is complete" and becomes "the arguments I promised to use are
// final", which is available long before the end of the stream — and, more
// importantly, is available *together with* the decision that says whether
// acting on it is safe (FR-34).
//
// The subset is deliberately tiny:
//
//   any | null | boolean | number | integer | string
//   { member* }        member := ("!" key | "?" key) ":" schema (";" | ",")?
//   [ schema ]
//   (kind | { ... } | [ ... ]) ( constraints )?
//                              constraints := constraint ("," | ";")*
//
// A member is required by default: `!` is written for the reader, not for the
// parser. `Schema::stringify` always writes the marker back, so the text form
// has one canonical spelling and a round trip is exact.
//
// The text form exists so that a demo, a test and a CLI flag can all use the
// same declaration without a JSON Schema implementation to parse it. It is a
// skeleton, not a contract, and it is still not a JSON Schema implementation.
//
// Since 0.7.0 a kind may carry *value* constraints, because a streaming caller
// that refuses `{"limit":-1}` the moment `-1` is final saves the rest of the
// stream and the shape check alone could not do that:
//
//   integer(minimum:1)                     number(exclusiveMaximum:1.5)
//   string(maxLength:64,minLength:1)       any(enum:["low","high"])
//   [string(pattern:[a-zA-Z0-9_])]
//
// The names are JSON Schema's (`minimum`, `exclusiveMinimum`, `maximum`,
// `exclusiveMaximum`, `minLength`, `maxLength`, `enum`), the spelling is the
// declaration language's own (`key:value`, separated by `,` or `;`), and the
// set of constraints each kind accepts is enforced at parse time: `maxLength`
// on an `integer` is an `E070`, not a rule that silently never fires. `enum`
// takes a JSON literal array and is allowed on any kind. The one deliberate
// restriction is `pattern`: it is a *character-class subset*, not a regular
// expression. `pattern:[...]` accepts a value whose every character is in the
// class, and any other regular-expression syntax (`*`, `+`, `?`, `|`, `.`,
// anchors, groups, alternation) is an `E070` rather than a silently different
// meaning. There is no regex engine behind this file and there is no plan to
// add one.
//
// Since the Schema-gate audit (1.5.2), a *container* may carry a constraint
// list too -- `{...}(enum:[...])`, `[...](const:...)` -- because the JSON Schema
// bridge can build exactly that from `const`/`enum` on an object or an array.
// Such a constraint is a claim about the container's whole value and is
// **conjunctive** with the shape inside it: `{!a:integer}(enum:[{"a":1}])`
// requires both a valid object and one of the listed values. Every traversal
// (`evaluate`, `required_paths`, `at_path`, `member_keys`, `field`,
// `required_paths`, the streaming watcher) goes through `Schema::structure`
// for that reason, and `stringify` writes the constraint back so the text form
// stays lossless.
//
// Backward compatibility: a declaration that parsed before 0.7.0 parses to the
// same schema and `stringify()` still writes it the same way. A constraint is
// only visible when one was written. `evaluate` differs from 1.5.1 and earlier
// in one documented way: the root declaration is checked like any other node,
// so a bare `string` root refuses `42` (SPEC SR-34).

///|
/// The kinds a skeleton declaration can name (FR-36), plus a scalar kind with
/// value constraints written after it (0.7.0).
///
/// `parse` never builds `Constrained` with an empty constraint list, so a
/// declaration without constraints is the plain kind and matches exactly the
/// schema 0.6.x produced.
pub(all) enum Schema {
  Any
  Null
  Bool
  Num
  Int
  Str
  Arr(Schema)
  Obj(Array[SchemaMember])
  Constrained(Schema, Constraints)
}

///|
/// One declared object member (FR-36).
pub(all) struct SchemaMember {
  key : String
  /// A member that is not required does not hold up readiness.
  required : Bool
  schema : Schema
}

///|
/// Value constraints attached to a declared kind (0.7.0).
///
/// Every field is optional and `None` means "declared nothing", so an empty
/// `Constraints` is exactly the absence of constraints. The type is public so
/// that a caller can build a declaration in MoonBit as well as in text; the
/// text form and this struct carry the same information.
pub(all) struct Constraints {
  /// The numeric bounds are exact decimals, not `Double`s: a gate that folds
  /// `9007199254740993` onto `9007199254740992` allows a value it should
  /// refuse (see `decimal.mbt`).
  mut minimum : Dec?
  mut exclusive_minimum : Dec?
  mut maximum : Dec?
  mut exclusive_maximum : Dec?
  mut min_length : Int32?
  mut max_length : Int32?
  /// The exact values `enum` admits, in declaration order.
  mut enum_values : Array[Json]?
  /// The character class of `pattern`, exactly as written between the brackets
  /// (`a-z0-9_`), including a leading `^` for a negated class.
  mut pattern : String?
  /// `additionalProperties: false`: the object admits no member the declaration
  /// does not name (1.5.2). `false` is the default because the skeleton has
  /// always been a description of what a value must contain, not a gate on what
  /// it may not; a declaration has to ask for closure explicitly.
  mut additional_properties_closed : Bool
}

///|
/// A constraint list with nothing declared.
pub fn Constraints::none() -> Constraints {
  {
    minimum: None,
    exclusive_minimum: None,
    maximum: None,
    exclusive_maximum: None,
    min_length: None,
    max_length: None,
    enum_values: None,
    pattern: None,
    additional_properties_closed: false,
  }
}

///|
/// Whether nothing is constrained.
fn Constraints::is_empty(self : Constraints) -> Bool {
  match self {
    {
      minimum: None,
      exclusive_minimum: None,
      maximum: None,
      exclusive_maximum: None,
      min_length: None,
      max_length: None,
      enum_values: None,
      pattern: None,
      additional_properties_closed: false,
    } => true
    _ => false
  }
}

///|
/// The first pair of bounds that cannot be satisfied together, as a message
/// without a source prefix.
///
/// Both declaration surfaces build a `Constraints` and then ask this one
/// function, so the text form and the JSON Schema bridge cannot drift apart on
/// which combinations are refusable. A contradiction here is a declaration
/// error (`E070`): the alternative is a gate that refuses every value at
/// runtime, which looks like a rule but is really a typo.
///
/// The check is on the raw bounds, so keyword order cannot change the answer.
fn Constraints::bound_problem(self : Constraints) -> String? {
  match (self.min_length, self.max_length) {
    (Some(lo), Some(hi)) =>
      if lo > hi {
        return Some(
          "`minLength` exceeds `maxLength`; the declaration can never be satisfied",
        )
      }
    _ => ()
  }
  match (self.minimum, self.maximum) {
    (Some(lo), Some(hi)) =>
      if lo.compare(hi) > 0 {
        return Some(
          "`minimum` exceeds `maximum`; the declaration can never be satisfied",
        )
      }
    _ => ()
  }
  match (self.minimum, self.exclusive_maximum) {
    (Some(lo), Some(hi)) =>
      if lo.compare(hi) >= 0 {
        return Some(
          "`minimum` is not below `exclusiveMaximum`; the declaration can never be satisfied",
        )
      }
    _ => ()
  }
  match (self.exclusive_minimum, self.maximum) {
    (Some(lo), Some(hi)) =>
      if lo.compare(hi) >= 0 {
        return Some(
          "`exclusiveMinimum` is not below `maximum`; the declaration can never be satisfied",
        )
      }
    _ => ()
  }
  match (self.exclusive_minimum, self.exclusive_maximum) {
    (Some(lo), Some(hi)) =>
      if lo.compare(hi) >= 0 {
        return Some(
          "`exclusiveMinimum` is not below `exclusiveMaximum`; the declaration can never be satisfied",
        )
      }
    _ => ()
  }
  None
}

///|
/// Canonical text of a constraint number, so that `minimum:0` round trips as
/// `minimum:0` rather than `minimum:0.0`.
fn constraint_number_text(d : Dec) -> String {
  d.text()
}

///|
/// Canonical text of the constraint list, in a fixed order, as it is written
/// between the parentheses. `Constraints::none().text() == ""`.
fn Constraints::text(self : Constraints) -> String {
  let parts : Array[String] = []
  match self.minimum {
    Some(d) => parts.push("minimum:" + constraint_number_text(d))
    None => ()
  }
  match self.exclusive_minimum {
    Some(d) => parts.push("exclusiveMinimum:" + constraint_number_text(d))
    None => ()
  }
  match self.maximum {
    Some(d) => parts.push("maximum:" + constraint_number_text(d))
    None => ()
  }
  match self.exclusive_maximum {
    Some(d) => parts.push("exclusiveMaximum:" + constraint_number_text(d))
    None => ()
  }
  match self.min_length {
    Some(n) => parts.push("minLength:" + n.to_string())
    None => ()
  }
  match self.max_length {
    Some(n) => parts.push("maxLength:" + n.to_string())
    None => ()
  }
  match self.enum_values {
    Some(vs) => parts.push("enum:" + enum_literals_text(vs))
    None => ()
  }
  match self.pattern {
    Some(cls) => parts.push("pattern:[" + cls + "]")
    None => ()
  }
  // Written last so the order of the text form is fixed, and only when it says
  // something: an open object is the default and writing it back would change
  // the spelling of every declaration that never asked for closure.
  if self.additional_properties_closed {
    parts.push("additionalProperties:false")
  }
  parts.join(",")
}

///|
/// Canonical text of an `enum` list.
fn enum_literals_text(vs : Array[Json]) -> String {
  let parts : Array[String] = []
  for v in vs {
    parts.push(v.stringify())
  }
  "[" + parts.join(",") + "]"
}

///|
/// Whether code unit `u` belongs to the character class `inner`.
///
/// The class language is intentionally not a regular expression: a set of
/// literals and ranges, a leading `^` to negate it, and the six common
/// shorthands. Every code unit of the *value* is tested against the set; there
/// is nothing to concatenate and nothing to quantify.
fn class_unit_in(inner : String, u : Int32) -> Bool {
  let n = inner.length()
  let mut i = 0
  let mut negated = false
  if n > 0 && inner.at(0).to_int() == 0x5E {
    negated = true
    i = 1
  }
  let mut hit = false
  while i < n {
    let c = inner.at(i).to_int()
    if c == 0x5C && i + 1 < n {
      let e = inner.at(i + 1).to_int()
      match e {
        0x64 => if u >= 0x30 && u <= 0x39 { hit = true } // \d
        0x77 =>
          if (u >= 0x30 && u <= 0x39) ||
            (u >= 0x41 && u <= 0x5A) ||
            (u >= 0x61 && u <= 0x7A) ||
            u == 0x5F {
            hit = true
          } // \w
        0x73 =>
          if u == 0x20 ||
            u == 0x09 ||
            u == 0x0A ||
            u == 0x0D ||
            u == 0x0B ||
            u == 0x0C {
            hit = true
          } // \s
        0x6E => if u == 0x0A { hit = true } // \n
        0x74 => if u == 0x09 { hit = true } // \t
        0x72 => if u == 0x0D { hit = true } // \r
        0x5C | 0x5D | 0x2D | 0x5E => if u == e { hit = true } // \\ \] \- \^
        _ => ()
      }
      i = i + 2
      continue
    }
    // `a-z`: a `-` that has a character on both sides is a range, and the
    // character before it was already allowed to match on its own, so only the
    // upper end is new.
    if c == 0x2D && i > 0 && i + 1 < n {
      let lo = inner.at(i - 1).to_int()
      let hi = inner.at(i + 1).to_int()
      if u >= lo && u <= hi {
        hit = true
      }
      i = i + 2
      continue
    }
    if u == c {
      hit = true
    }
    i = i + 1
  }
  if negated {
    !hit
  } else {
    hit
  }
}

///|
/// Whether every code unit of `s` is in the class `inner`. The empty string is
/// in every class by vacuity; use `minLength` for "at least one".
fn class_accepts(inner : String, s : String) -> Bool {
  for k = 0; k < s.length(); k = k + 1 {
    if !class_unit_in(inner, s.at(k).to_int()) {
      return false
    }
  }
  true
}

///|
/// The first member of `map` that `members` does not name, or `None`.
///
/// Only a closed object (`additionalProperties: false`) has anything to say
/// here; an open one admits any member, which is JSON Schema's default and the
/// skeleton's own default. The map is taken rather than the value because the
/// caller has already checked the kind: `kind_accepts` ran before closure, so
/// an `Obj` declaration is only asked about an object. That keeps this function
/// free of an arm that can never run.
fn undeclared_member(
  members : Array[SchemaMember],
  map : Map[String, Json],
) -> String? {
  for k, _ in map {
    let mut declared = false
    for m in members {
      if m.key == k {
        declared = true
        break
      }
    }
    if !declared {
      return Some(k)
    }
  }
  None
}

///|
/// The declared member names of a closed object, spelled `{a, b}`.
fn declared_names(members : Array[SchemaMember]) -> String {
  let sb = StringBuilder()
  sb.write_char('{')
  for i = 0; i < members.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(members[i].key)
  }
  sb.write_char('}')
  sb.to_string()
}

///|
/// The closure violation of `v` under `inner` when `c` closes the object, or
/// `None`.
///
/// Two arms can be reached that the streaming and batch paths never take: a
/// hand-built `Constrained` can carry the flag on a non-object kind (the text
/// form and the JSON Schema bridge both refuse that at modelling time, but the
/// public struct does not), and the value can be of another kind, which the
/// kind check refuses before closure is asked. Both answer `None`: closure has
/// nothing to add to a refusal that already happened.
fn closure_problem(inner : Schema, c : Constraints, v : Json) -> String? {
  if !c.additional_properties_closed {
    return None
  }
  match (inner.structure(), v) {
    (Obj(members), Json::Object(map)) =>
      match undeclared_member(members, map) {
        Some(k) =>
          Some(
            "object with no member outside " +
            declared_names(members) +
            " (got `" +
            k +
            "`)",
          )
        None => None
      }
    _ => None
  }
}

///|
/// The first declared constraint `v` violates, as the phrase `evaluate` and the
/// watcher report it, or `None` when `v` satisfies all of them.
///
/// `base` is the kind the constraint is attached to (`integer`, `string`, …)
/// so that the phrase reads the way a caller would write it. Only the value
/// matters: whether the kind matches is the caller's check.
fn Constraints::violation(
  self : Constraints,
  base : String,
  v : Json,
) -> String? {
  // A bound is compared on the exact decimal value. A value whose text this
  // library cannot normalise (`1e9999999999`) cannot be proven to satisfy a
  // bound, so it is refused rather than guessed: fail closed.
  let has_bound = self.minimum is Some(_) ||
    self.exclusive_minimum is Some(_) ||
    self.maximum is Some(_) ||
    self.exclusive_maximum is Some(_)
  match v {
    Json::Number(_, ..) =>
      match number_dec(v) {
        Some(x) => {
          match self.minimum {
            Some(m) =>
              if x.compare(m) < 0 {
                return Some(base + " >= " + constraint_number_text(m))
              }
            None => ()
          }
          match self.exclusive_minimum {
            Some(m) =>
              if x.compare(m) <= 0 {
                return Some(base + " > " + constraint_number_text(m))
              }
            None => ()
          }
          match self.maximum {
            Some(m) =>
              if x.compare(m) > 0 {
                return Some(base + " <= " + constraint_number_text(m))
              }
            None => ()
          }
          match self.exclusive_maximum {
            Some(m) =>
              if x.compare(m) >= 0 {
                return Some(base + " < " + constraint_number_text(m))
              }
            None => ()
          }
        }
        None =>
          if has_bound {
            return Some(base + " with an exactly comparable decimal value")
          }
      }
    _ => ()
  }
  match v {
    Json::String(s) => {
      // JSON Schema counts Unicode code points, not UTF-16 code units. `"😀"`
      // is one character for `minLength`/`maxLength`; `String::length` counts
      // two, so a `minLength:2` used to pass it and a `maxLength:1` used to
      // refuse it. Combining marks still count one each: the standard counts
      // code points, not user-perceived graphemes.
      let len = code_points(s)
      match self.min_length {
        Some(n) =>
          if len < n {
            return Some("string with length >= " + n.to_string())
          }
        None => ()
      }
      match self.max_length {
        Some(n) =>
          if len > n {
            return Some("string with length <= " + n.to_string())
          }
        None => ()
      }
      match self.pattern {
        Some(cls) =>
          if !class_accepts(cls, s) {
            return Some("string of characters in [" + cls + "]")
          }
        None => ()
      }
    }
    _ => ()
  }
  match self.enum_values {
    Some(vs) => {
      let mut hit = false
      for e in vs {
        if json_equal(e, v) {
          hit = true
          break
        }
      }
      if !hit {
        return Some("one of " + enum_literals_text(vs))
      }
    }
    None => ()
  }
  None
}

///|
/// Explicit `Eq` implementation for `SchemaMember` (structural, for tests).
pub impl Eq for SchemaMember with fn equal(
  self : SchemaMember,
  other : SchemaMember,
) -> Bool {
  if self.key != other.key || self.required != other.required {
    return false
  }
  // `stringify` refuses a cyclic (or over-budget) hand-built declaration with
  // `E070` instead of crashing, and `Eq` cannot raise. An empty text form is
  // impossible for a successful call, so it is the unambiguous "the walk gave
  // up" marker; falling back to physical identity is conservative -- it can
  // report two *equal but unprintable* members as different, never the reverse.
  let a = self.schema.stringify() catch { _ => "" }
  let b = other.schema.stringify() catch { _ => "" }
  if a == "" || b == "" {
    physical_equal(self.schema, other.schema)
  } else {
    a == b
  }
}

///|
/// Explicit `Eq` extension for `SchemaMember`.
pub extend SchemaMember with Eq::{not_equal, equal}

///|
/// Stable name of a kind, as it is written in the text form. Constraints are
/// not part of the kind, so a constrained `integer` is still named `integer`;
/// see `Schema::expectation` for the declaration as it was written.
pub fn Schema::name(self : Schema) -> String {
  match self {
    Any => "any"
    Null => "null"
    Bool => "boolean"
    Num => "number"
    Int => "integer"
    Str => "string"
    Arr(_) => "array"
    Obj(_) => "object"
    Constrained(inner, _) => inner.name()
  }
}

///|
/// The declaration with its value constraints peeled off.
///
/// A `Constrained` node is two claims about the same value: the constraints
/// (`enum`, range, length, …) and the shape inside them (`Obj` members,
/// `Arr` items). They are conjunctive, so every traversal that looks for
/// members or items must see through the wrapper instead of treating it as a
/// leaf. This one accessor exists so `evaluate`, `required_paths`, `at_path`,
/// `member_keys`, `field`, `required_paths` and the streaming watcher all
/// agree on what "inside" means.
fn Schema::structure(self : Schema) -> Schema {
  let mut cur = self
  let mut done = false
  while !done {
    match cur {
      Constrained(inner, _) => cur = inner
      _ => done = true
    }
  }
  cur
}

///|
/// Whether any node of the declaration carries a value constraint on a
/// *container* (`{...}(enum:[...])`, `[...](const:...)`).
///
/// Such a constraint is a claim about the whole container, so it can only be
/// judged once the container is final. The streaming watcher uses this to know
/// that a verdict on the members alone is premature: it must wait for the
/// enclosing value to close. A declaration that only constrains leaves is
/// unaffected and keeps the early verdict it always had.
///
/// Iterative, because a declaration may be built by hand as deep as
/// `MAX_VALUE_DEPTH` and a recursive scan would put that on the native stack.
fn Schema::has_container_constraint(self : Schema) -> Bool {
  let work : Array[Schema] = [self]
  while work.length() > 0 {
    let s = work.remove(work.length() - 1)
    match s {
      Constrained(inner, c) =>
        match inner.structure() {
          Obj(_) | Arr(_) => if !c.is_empty() { return true }
          _ => ()
        }
      Obj(members) =>
        for m in members {
          work.push(m.schema)
        }
      Arr(inner) => work.push(inner)
      _ => ()
    }
  }
  false
}

///|
/// The declaration as a caller would have written it: the kind alone when
/// nothing is constrained, `integer(minimum:0)` when something is.
pub fn Schema::expectation(self : Schema) -> String {
  match self {
    Constrained(inner, c) =>
      if c.is_empty() {
        inner.name()
      } else {
        inner.name() + "(" + c.text() + ")"
      }
    _ => self.name()
  }
}

///|
/// One step of `Schema::stringify`'s work list.
priv enum StringifyStep {
  /// Write the text form of one declaration node, at the given nesting depth.
  StringifyNode(Schema, Int32)
  /// Write a literal that needs no traversal (`]`, a member prefix, a suffix).
  StringifyText(String)
  /// Close the object opened by the matching `StringifyNode`.
  StringifyCloseObj
}

///|
/// The text of one member prefix, in the order a parser would read it: the
/// required marker, the (possibly quoted) name, and the `:`.
///
/// A name containing `:`, whitespace or a quote cannot be written bare: the
/// parser would stop at the first delimiter and read a different skeleton back.
/// Quoting it is what makes `parse(stringify(s))` mean the same as `s` (Q-23)
/// for names like `{"name with space":string}`.
fn stringify_prefix(m : SchemaMember) -> String {
  let marker = if m.required { "!" } else { "?" }
  if name_needs_quotes(m.key) {
    marker + "\"" + m.key + "\":"
  } else {
    marker + m.key + ":"
  }
}

///|
/// The text form of a schema, the inverse of `Schema::parse`.
///
/// Iterative, for the same reason `copy_json` and `walk_schema` are: a
/// declaration may be built by hand, and a recursive form would make the
/// deepest writable declaration a property of the native stack. The depth and
/// node budgets, plus the ancestor-chain cycle check, turn a hand-built
/// self-reference into `E070` instead of a crash (`Array` is mutable, so a
/// cycle is constructible).
///
/// The optional budgets exist so a test can exercise the in-budget/over-budget
/// boundary with a small declaration; the defaults are `MAX_SCHEMA_WALK_DEPTH`
/// and `MAX_SCHEMA_WALK_NODES`.
pub fn Schema::stringify(
  self : Schema,
  depth_budget? : Int32,
  node_budget? : Int32,
) -> String raise LIWENJSONError {
  let max_depth = match depth_budget {
    Some(v) => v
    None => MAX_SCHEMA_WALK_DEPTH
  }
  let max_nodes = match node_budget {
    Some(v) => v
    None => MAX_SCHEMA_WALK_NODES
  }
  let sb = StringBuilder()
  let work : Array[StringifyStep] = [StringifyNode(self, 0)]
  // The identity of every `Obj` member array on the current path. A cycle needs
  // a mutable `Array`, so comparing identities catches exactly the cycles that
  // can exist; the chain is popped on the way out, which is why a declaration
  // that legally references the same sub-declaration twice is not a cycle.
  let ancestors : Array[Array[SchemaMember]] = []
  let mut nodes = 0
  while work.length() > 0 {
    match work.remove(work.length() - 1) {
      StringifyCloseObj => {
        let _ = ancestors.remove(ancestors.length() - 1)
        sb.write_char('}')
      }
      StringifyText(t) => sb.write_string(t)
      StringifyNode(schema, depth) => {
        if depth > max_depth {
          raise SchemaError(
            "the schema is nested more deeply than a traversal may walk",
          )
        }
        nodes = nodes + 1
        if nodes > max_nodes {
          raise SchemaError("the schema is larger than a traversal may walk")
        }
        match schema {
          Arr(inner) => {
            sb.write_char('[')
            work.push(StringifyText("]"))
            work.push(StringifyNode(inner, depth + 1))
          }
          Obj(members) => {
            for anc in ancestors {
              if physical_equal(anc, members) {
                raise SchemaError("the schema contains a cycle")
              }
            }
            ancestors.push(members)
            sb.write_char('{')
            // Members are separated by `,`. The whole body is built in reading
            // order and pushed in reverse, so the pops reproduce it.
            let body : Array[StringifyStep] = []
            for j = 0; j < members.length(); j = j + 1 {
              let m = members[j]
              if j > 0 {
                body.push(StringifyText(","))
              }
              body.push(StringifyText(stringify_prefix(m)))
              body.push(StringifyNode(m.schema, depth + 1))
            }
            body.push(StringifyCloseObj)
            let mut k = body.length()
            while k > 0 {
              k = k - 1
              work.push(body[k])
            }
          }
          // A container carries constraints the text form can express since the
          // schema audit fix (1.5.1 and earlier dropped them): `{...}(enum:[...])`
          // and `[...](enum:[...])` parse, so writing them back is lossless.
          // Before that the constraint list was silently dropped, which made
          // `parse(stringify(s))` a weaker gate than `s` -- the one thing the
          // text form exists to prevent.
          Constrained(inner, c) =>
            if c.is_empty() {
              work.push(StringifyNode(inner, depth + 1))
            } else {
              work.push(StringifyText("(" + c.text() + ")"))
              work.push(StringifyNode(inner, depth + 1))
            }
          _ => sb.write_string(schema.name())
        }
      }
    }
  }
  sb.to_string()
}

///|
/// Whether a member name cannot be written as a bare identifier.
///
/// The bare form ends at `:`, space, tab, newline or carriage return, so a name
/// containing any of those has to be quoted. A name containing `"` cannot be
/// represented at all — the parser has no escape — but such a name can only
/// come from a hand-built `Obj`, because parsing stops at the first quote.
fn name_needs_quotes(key : String) -> Bool {
  if key == "" {
    return true
  }
  for i = 0; i < key.length(); i = i + 1 {
    let c = key.at(i).to_int()
    if c == 0x3A ||
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      c == 0x22 {
      return true
    }
  }
  false
}

///|
/// Member names declared under `parent`, in declaration order.
///
/// The members of `{...}(enum:[...])` are the members of the object inside the
/// constraint list: a constraint is an extra claim about the same value, not a
/// replacement for its shape.
pub fn Schema::member_keys(self : Schema) -> Array[String] {
  let out : Array[String] = []
  match self.structure() {
    Obj(members) =>
      for m in members {
        out.push(m.key)
      }
    _ => ()
  }
  out
}

///|
/// The declared schema of member `key`, or `None`.
pub fn Schema::field(self : Schema, key : String) -> SchemaMember? {
  match self.structure() {
    Obj(members) => {
      for m in members {
        if m.key == key {
          return Some(m)
        }
      }
      None
    }
    _ => None
  }
}

// ---------------------------------------------------------------------------
// Paths.
// ---------------------------------------------------------------------------

///|
/// Whether a path step can be written as a bare step in the dotted form: any
/// non-empty name that does not contain the separator.
fn path_plain_step(step : String) -> Bool {
  if step.length() == 0 {
    return false
  }
  for i = 0; i < step.length(); i = i + 1 {
    let c = step.at(i).to_int()
    // `.` separates steps; `/` and `~` are the pointer form's escape
    // characters, so a name containing any of them is written as a pointer
    // step (and decoded with the escapes reversed).
    if c == 0x2E || c == 0x2F || c == 0x7E {
      return false
    }
  }
  true
}

///|
/// The array index a path step names, or `-1` when it does not name one.
///
/// RFC 6901 array indices are decimal without a leading zero (`0` is fine,
/// `01` is not), so a member name such as `01` stays a member name and is never
/// silently navigated as slot 1.
fn path_index_step(step : String) -> Int32 {
  if step.length() == 0 {
    return -1
  }
  if step.length() > 1 && step.at(0).to_int() == 0x30 {
    return -1
  }
  let mut n : Int64 = 0L
  for i = 0; i < step.length(); i = i + 1 {
    let c = step.at(i).to_int()
    if c < 0x30 || c > 0x39 {
      return -1
    }
    n = n * 10L + (c - 0x30).to_int64()
    if n > 2_147_483_647L {
      return -1
    }
  }
  n.to_int()
}

///|
/// Whether a path is written in the RFC 6901 pointer form.
fn path_is_pointer(path : String) -> Bool {
  path.length() > 0 && path.at(0).to_int() == 0x2F
}

///|
/// Escape one step for the pointer form (RFC 6901).
fn path_escape_step(step : String) -> String {
  step.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
}

///|
/// Unescape one pointer step (RFC 6901). An escape the writer did not produce is
/// left alone: the form only has to round-trip what the writer produces.
fn path_unescape_step(step : String) -> String {
  step.replace_all(old="~1", new="/").replace_all(old="~0", new="~")
}

///|
/// Decode the steps of a pointer, whose first character is `/`.
fn path_pointer_steps(path : String) -> Array[String] {
  let out : Array[String] = []
  let mut first = true
  // A literal `/` can only appear as a step boundary; the writer escapes one
  // inside a name to `~1`, so splitting on the raw separator is exact.
  for part in path.split("/") {
    if first {
      first = false
    } else {
      out.push(path_unescape_step(part.to_owned()))
    }
  }
  out
}

///|
/// Decode a path into its steps. `""` is the root (`[]`); a path that starts
/// with `/` is a pointer, anything else is the dotted form.
///
/// The canonical writer below picks one of the two forms, but both readers
/// accept both, so a caller that spells a path the other way still finds the
/// same declaration.
fn path_texts(path : String) -> Array[String] {
  if path == "" {
    return []
  }
  if path_is_pointer(path) {
    return path_pointer_steps(path)
  }
  let out : Array[String] = []
  for part in path.split(".") {
    out.push(part.to_owned())
  }
  out
}

///|
/// Append one member name to a canonical path.
///
/// Root and a member named `""` must be different paths: root is `""` and the
/// empty name is `/`, which is why the dotted form is used only when every step
/// is a plain name. A name containing the separator switches the whole path to
/// the pointer form (the dotted form cannot represent it), which keeps the
/// writer and the decoder inverse to each other.
fn path_append(base : String, step : String) -> String {
  if base == "" {
    if path_plain_step(step) && step.at(0).to_int() != 0x2F {
      step
    } else {
      "/" + path_escape_step(step)
    }
  } else if path_is_pointer(base) {
    base + "/" + path_escape_step(step)
  } else if path_plain_step(step) {
    base + "." + step
  } else {
    let segs : Array[PathSegment] = []
    for part in base.split(".") {
      segs.push(Key(part.to_owned()))
    }
    segs.push(Key(step))
    pointer_of_path(segs)
  }
}

///|
/// Append a whole canonical path `rest` below `base`.
fn path_extend(base : String, rest : String) -> String {
  if rest == "" {
    return base
  }
  let mut out = base
  for step in path_texts(rest) {
    out = path_append(out, step)
  }
  out
}

///|
/// The steps of a canonical path as `PathSegment` values. A declaration path
/// never names an array slot (`required_paths` does not descend arrays), so
/// every step is a `Key`.
fn path_key_segments(path : String) -> Array[PathSegment] {
  let out : Array[PathSegment] = []
  for step in path_texts(path) {
    out.push(Key(step))
  }
  out
}

///|
/// The declaration a path points at, or `None` (FR-36, FR-39).
///
/// A path is spelled the way `Schema::required_paths` produces it: root is
/// `""`, steps are joined with `.` when every step is a plain name, and the RFC
/// 6901 pointer form (`/` for the empty name, `/a.b` for a name containing the
/// separator) is used otherwise. Both forms are accepted. A numeric step inside
/// an array selects an element of the declared items schema.
pub fn Schema::at_path(self : Schema, path : String) -> Schema? {
  let mut cur = self
  for step in path_texts(path) {
    cur = match cur.structure() {
      Obj(members) => {
        let mut next : Schema? = None
        for m in members {
          if m.key == step {
            next = Some(m.schema)
          }
        }
        match next {
          Some(s) => s
          None => return None
        }
      }
      Arr(inner) => {
        if path_index_step(step) < 0 {
          return None
        }
        inner
      }
      _ => return None
    }
  }
  Some(cur)
}

// ---------------------------------------------------------------------------
// The text form.
// ---------------------------------------------------------------------------

///|
/// Cursor over a schema declaration.
priv struct SchemaParser {
  text : String
  mut i : Int32
  /// Nesting depth of the declaration being read. A declaration is external
  /// input, so it must not be able to exhaust the stack; see `MAX_VALUE_DEPTH`.
  mut depth : Int32
}

///|
/// Skip spaces, tabs and line breaks.
fn sp_skip_ws(p : SchemaParser) -> Unit {
  while p.i < p.text.length() {
    let c = p.text.at(p.i).to_int()
    if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      p.i = p.i + 1
    } else {
      break
    }
  }
}

///|
/// Case-insensitive comparison against an ASCII literal at `p.i`.
fn sp_at(p : SchemaParser, word : String) -> Bool {
  let n = word.length()
  if p.i + n > p.text.length() {
    return false
  }
  for k = 0; k < n; k = k + 1 {
    let a = p.text.at(p.i + k).to_int()
    let b = word.at(k).to_int()
    // The keywords are ASCII, so a plain `| 0x20` is a correct fold.
    let fold = if a >= 0x41 && a <= 0x5A { a | 0x20 } else { a }
    if fold != b && a != b {
      return false
    }
  }
  true
}

///|
/// Parse a schema at `p.i`, leaving the cursor after it.
fn sp_schema(p : SchemaParser) -> Schema raise LIWENJSONError {
  if p.depth > MAX_SCHEMA_DEPTH {
    raise SchemaError(
      "schema: declaration nests deeper than " +
      MAX_SCHEMA_DEPTH.to_string() +
      " levels",
    )
  }
  p.depth = p.depth + 1
  let s = sp_schema_body(p)
  p.depth = p.depth - 1
  s
}

///|
/// The body of `sp_schema`, with the depth already accounted for.
fn sp_schema_body(p : SchemaParser) -> Schema raise LIWENJSONError {
  sp_skip_ws(p)
  let n = p.text.length()
  if p.i >= n {
    raise SchemaError(" unexpected end of declaration")
  }
  let c = p.text.at(p.i).to_int()
  if c == 0x7B {
    // {
    p.i = p.i + 1
    let members : Array[SchemaMember] = []
    while true {
      sp_skip_ws(p)
      if p.i >= n {
        raise SchemaError(" `{` is never closed")
      }
      if p.text.at(p.i).to_int() == 0x7D {
        // }
        p.i = p.i + 1
        break
      }
      let mut required = true
      if p.text.at(p.i).to_int() == 0x21 {
        // !
        p.i = p.i + 1
      } else if p.text.at(p.i).to_int() == 0x3F {
        // ?
        required = false
        p.i = p.i + 1
      }
      sp_skip_ws(p)
      let key = sp_key(p)
      sp_skip_ws(p)
      if p.i >= n || p.text.at(p.i).to_int() != 0x3A {
        raise SchemaError(" member `" + key + "` has no `:`")
      }
      p.i = p.i + 1
      let inner = sp_schema(p)
      members.push({ key, required, schema: inner, })
      sp_skip_ws(p)
      if p.i < n {
        let d = p.text.at(p.i).to_int()
        if d == 0x2C || d == 0x3B {
          p.i = p.i + 1
        }
      }
    }
    guard_no_dup(members)
    // A container may carry a constraint list too: `{...}(enum:[...])`. The
    // constraint is an extra claim about the same value, and dropping it on
    // the way back out would make `parse(stringify(s))` a weaker gate than
    // `s`.
    sp_wrap_constraints(p, Obj(members))
  } else if c == 0x5B {
    // [
    p.i = p.i + 1
    let inner = sp_schema(p)
    sp_skip_ws(p)
    if p.i >= n || p.text.at(p.i).to_int() != 0x5D {
      raise SchemaError(" `[` is never closed")
    }
    p.i = p.i + 1
    sp_wrap_constraints(p, Arr(inner))
  } else if c == 0x22 {
    // A quoted key is not a type here; only members have names.
    raise SchemaError(" expected a type or `{`, found a quoted string")
  } else if sp_at(p, "any") {
    p.i = p.i + 3
    sp_wrap_constraints(p, Any)
  } else if sp_at(p, "null") {
    p.i = p.i + 4
    sp_wrap_constraints(p, Null)
  } else if sp_at(p, "boolean") {
    p.i = p.i + 7
    sp_wrap_constraints(p, Bool)
  } else if sp_at(p, "bool") {
    p.i = p.i + 4
    sp_wrap_constraints(p, Bool)
  } else if sp_at(p, "integer") {
    p.i = p.i + 7
    sp_wrap_constraints(p, Int)
  } else if sp_at(p, "int") {
    p.i = p.i + 3
    sp_wrap_constraints(p, Int)
  } else if sp_at(p, "number") {
    p.i = p.i + 6
    sp_wrap_constraints(p, Num)
  } else if sp_at(p, "string") {
    p.i = p.i + 6
    sp_wrap_constraints(p, Str)
  } else {
    raise SchemaError(
      "schema: unknown type at offset " +
      p.i.to_string() +
      ": " +
      p.text[p.i:].to_owned(),
    )
  }
}

// ---------------------------------------------------------------------------
// The constraint list (0.7.0).
//
// It is written immediately after a scalar kind — `integer(minimum:0)` — and
// not after a space, because a space is already how the language separates a
// schema from the next member (`{a:integer b:string}` has two members). Only
// the `(` is treated as attached, so every declaration that parsed before this
// existed still parses the same way.
// ---------------------------------------------------------------------------

///|
/// The constraint list of a kind, or the kind itself when there is none.
fn sp_wrap_constraints(
  p : SchemaParser,
  base : Schema,
) -> Schema raise LIWENJSONError {
  if p.i >= p.text.length() || p.text.at(p.i).to_int() != 0x28 {
    return base
  }
  let c = sp_constraints(p, base)
  if c.is_empty() {
    base
  } else {
    Constrained(base, c)
  }
}

///|
/// Parse `(name:value, ...)`. `p.i` is at the `(`.
fn sp_constraints(
  p : SchemaParser,
  base : Schema,
) -> Constraints raise LIWENJSONError {
  let n = p.text.length()
  p.i = p.i + 1
  let out = Constraints::none()
  // A repeated keyword used to overwrite the earlier one: the last `enum`,
  // `minimum` or `minLength` in the list won, so reordering the list could
  // widen what the gate allows. Constraints are conjunctive, but a duplicate
  // is a declaration bug rather than a second claim: refuse it at modelling
  // time instead of silently intersecting or overwriting.
  let seen : Array[String] = []
  while true {
    sp_skip_ws(p)
    if p.i >= n {
      raise SchemaError(" `(` of the constraint list is never closed")
    }
    if p.text.at(p.i).to_int() == 0x29 {
      p.i = p.i + 1
      break
    }
    let name_at = p.i
    let name = sp_constraint_name(p)
    for previous in seen {
      if name_eq_ci(previous, name) {
        raise SchemaError(
          " schema: duplicate constraint `" +
          name +
          "` at offset " +
          name_at.to_string() +
          "; write each constraint once",
        )
      }
    }
    seen.push(name)
    sp_skip_ws(p)
    if p.i >= n || p.text.at(p.i).to_int() != 0x3A {
      raise SchemaError(
        " schema: constraint `" +
        name +
        "` has no `:` at offset " +
        name_at.to_string(),
      )
    }
    p.i = p.i + 1
    sp_skip_ws(p)
    sp_constraint_value(p, name, base, name_at, out)
    sp_skip_ws(p)
    if p.i >= n {
      raise SchemaError(" `(` of the constraint list is never closed")
    }
    let d = p.text.at(p.i).to_int()
    if d == 0x2C || d == 0x3B {
      p.i = p.i + 1
    } else if d == 0x29 {
      p.i = p.i + 1
      break
    } else {
      raise SchemaError(
        " schema: unexpected `" +
        sp_char_text(p.text.at(p.i)) +
        "` in a constraint list at offset " +
        p.i.to_string() +
        "; expected `,`, `;` or `)`",
      )
    }
  }
  // Same refusal as the JSON Schema bridge (`json_schema.mbt`): a pair of
  // bounds with an empty intersection can never accept a value, so it is a
  // declaration error rather than a rule that fires only at runtime.
  match out.bound_problem() {
    Some(message) => raise SchemaError(" schema: " + message)
    None => ()
  }
  out
}

///|
/// One constraint name: ASCII letters, matched case-insensitively against the
/// eight names the language has.
fn sp_constraint_name(p : SchemaParser) -> String raise LIWENJSONError {
  let n = p.text.length()
  let sb = StringBuilder()
  while p.i < n {
    let c = p.text.at(p.i).to_int()
    if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
      sb.write_char(Int32::unsafe_to_char(c))
      p.i = p.i + 1
    } else {
      break
    }
  }
  let name = sb.to_string()
  if name == "" {
    raise SchemaError(
      " schema: expected a constraint name at offset " + p.i.to_string(),
    )
  }
  name
}

///|
/// One character of input as it appears in a diagnostic.
fn sp_char_text(u : UInt16) -> String {
  match u.to_int() {
    0x0A => "\\n"
    0x09 => "\\t"
    0x0D => "\\r"
    _ => Int32::unsafe_to_char(u.to_int()).to_string()
  }
}

///|
/// Whether two ASCII names are equal ignoring case.
fn name_eq_ci(a : String, b : String) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    let x = a.at(i).to_int()
    let y = b.at(i).to_int()
    let fx = if x >= 0x41 && x <= 0x5A { x | 0x20 } else { x }
    let fy = if y >= 0x41 && y <= 0x5A { y | 0x20 } else { y }
    if fx != fy {
      return false
    }
  }
  true
}

///|
/// Parse and check the value of one constraint, writing it into `out`.
fn sp_constraint_value(
  p : SchemaParser,
  name : String,
  base : Schema,
  name_at : Int32,
  out : Constraints,
) -> Unit raise LIWENJSONError {
  let kind = base.name()
  if name_eq_ci(name, "minimum") ||
    name_eq_ci(name, "exclusiveMinimum") ||
    name_eq_ci(name, "maximum") ||
    name_eq_ci(name, "exclusiveMaximum") {
    if kind != "number" && kind != "integer" {
      raise SchemaError(
        " schema: `" +
        name +
        "` applies to `number` and `integer`, not to `" +
        kind +
        "`, at offset " +
        name_at.to_string(),
      )
    }
    let d = sp_constraint_number(p, name)
    if name_eq_ci(name, "minimum") {
      out.minimum = Some(d)
    } else if name_eq_ci(name, "exclusiveMinimum") {
      out.exclusive_minimum = Some(d)
    } else if name_eq_ci(name, "maximum") {
      out.maximum = Some(d)
    } else {
      out.exclusive_maximum = Some(d)
    }
    return
  }
  if name_eq_ci(name, "minLength") || name_eq_ci(name, "maxLength") {
    if kind != "string" {
      raise SchemaError(
        " schema: `" +
        name +
        "` applies to `string`, not to `" +
        kind +
        "`, at offset " +
        name_at.to_string(),
      )
    }
    let len = sp_constraint_length(p, name)
    if name_eq_ci(name, "minLength") {
      out.min_length = Some(len)
    } else {
      out.max_length = Some(len)
    }
    return
  }
  if name_eq_ci(name, "additionalProperties") {
    if kind != "object" {
      raise SchemaError(
        " schema: `additionalProperties` applies to `object`, not to `" +
        kind +
        "`, at offset " +
        name_at.to_string(),
      )
    }
    let value = sp_constraint_bare_word(p)
    if name_eq_ci(value, "false") {
      out.additional_properties_closed = true
    } else if name_eq_ci(value, "true") {
      // The default; accepting it keeps `parse(stringify(s))` lossless for a
      // declaration a host wrote with the explicit spelling.
      out.additional_properties_closed = false
    } else {
      raise SchemaError(
        " schema: `additionalProperties` expects `true` or `false` at offset " +
        name_at.to_string() +
        ", got `" +
        value +
        "`",
      )
    }
    return
  }
  if name_eq_ci(name, "enum") {
    out.enum_values = Some(sp_constraint_enum(p, base))
    return
  }
  if name_eq_ci(name, "pattern") {
    if kind != "string" {
      raise SchemaError(
        " schema: `pattern` applies to `string`, not to `" +
        kind +
        "`, at offset " +
        name_at.to_string(),
      )
    }
    out.pattern = Some(sp_constraint_class(p))
    return
  }
  raise SchemaError(
    " schema: unknown constraint `" +
    name +
    "` at offset " +
    name_at.to_string() +
    "; the language has minimum, exclusiveMinimum, maximum, exclusiveMaximum, minLength, maxLength, enum, pattern and additionalProperties",
  )
}

///|
/// The token of a numeric constraint, kept as an exact decimal.
///
/// The grammar is JSON's, and it is JSON's own reader that decides it: the
/// constraint reader hands over a run of number characters, and `@json.parse`
/// says whether that run is a number literal. Re-walking the grammar here would
/// be a second copy of it to keep in agreement with the first; the first one is
/// the one the rest of the library trusts.
///
/// The *value* comes from the text, not from the `Double` the JSON reader
/// produced. A bound of `9007199254740993` in a declaration is a different
/// bound from `9007199254740992`, and treating them as the same one is a gate
/// that allows what it should refuse. A bound whose exponent cannot be
/// normalised is an `E070`, because a declaration the library cannot compare
/// exactly is one it must not pretend to enforce.
fn sp_constraint_number(
  p : SchemaParser,
  name : String,
) -> Dec raise LIWENJSONError {
  let at = p.i
  let tok = sp_constraint_token(p)
  if tok == "" || !is_json_number_text(tok) {
    raise SchemaError(
      " schema: `" +
      name +
      "` expects a number at offset " +
      at.to_string() +
      (if tok == "" { "" } else { ": `" + tok + "`" }),
    )
  }
  match Dec::parse(tok) {
    Some(d) => d
    None =>
      raise SchemaError(
        " schema: `" +
        name +
        "` expects a number at offset " +
        at.to_string() +
        ": `" +
        tok +
        "`",
      )
  }
}

///|
/// Whether `text` is a JSON number literal, decided by the JSON reader.
fn is_json_number_text(text : String) -> Bool {
  let parsed = @json.parse(text) catch { _ => return false }
  parsed is Json::Number(_, ..)
}

///|
/// A bare ASCII word, used by the boolean-valued constraints.
fn sp_constraint_bare_word(p : SchemaParser) -> String {
  let n = p.text.length()
  let sb = StringBuilder()
  while p.i < n {
    let c = p.text.at(p.i).to_int()
    if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
      sb.write_char(Int32::unsafe_to_char(c))
      p.i = p.i + 1
    } else {
      break
    }
  }
  sb.to_string()
}

///|
/// A run of characters that can appear in a number.
fn sp_constraint_token(p : SchemaParser) -> String {
  let n = p.text.length()
  let sb = StringBuilder()
  while p.i < n {
    let c = p.text.at(p.i).to_int()
    if (c >= 0x30 && c <= 0x39) ||
      c == 0x2D ||
      c == 0x2B ||
      c == 0x2E ||
      c == 0x65 ||
      c == 0x45 {
      sb.write_char(Int32::unsafe_to_char(c))
      p.i = p.i + 1
    } else {
      break
    }
  }
  sb.to_string()
}

///|
/// A length constraint: a non-negative integer, so that `minLength:-1` and
/// `maxLength:1.5` are `E070` rather than a rule that never fires.
fn sp_constraint_length(
  p : SchemaParser,
  name : String,
) -> Int32 raise LIWENJSONError {
  let at = p.i
  let d = sp_constraint_number(p, name)
  match d.length_value() {
    Some(n) => n
    None =>
      raise SchemaError(
        " schema: `" +
        name +
        "` expects a non-negative integer at offset " +
        at.to_string() +
        ": `" +
        constraint_number_text(d) +
        "`",
      )
  }
}

///|
/// An `enum` value: a JSON array of scalars, so that the spelling, the escapes
/// and the number forms are JSON's and not a new dialect.
fn sp_constraint_enum(
  p : SchemaParser,
  base : Schema,
) -> Array[Json] raise LIWENJSONError {
  let n = p.text.length()
  if p.i >= n || p.text.at(p.i).to_int() != 0x5B {
    raise SchemaError(
      " schema: `enum` expects a JSON array of literals at offset " +
      p.i.to_string(),
    )
  }
  let open = p.i
  let close = sp_scan_brackets(p, open)
  let slice = p.text[open:close].to_owned()
  let parsed = @json.parse(slice) catch {
    _ =>
      raise SchemaError(
        " schema: `enum` is not a valid JSON array at offset " +
        open.to_string(),
      )
  }
  let items = match parsed {
    Json::Array(a) => a
    _ =>
      raise SchemaError(
        " schema: `enum` expects a JSON array at offset " + open.to_string(),
      )
  }
  if items.length() == 0 {
    raise SchemaError(
      " schema: `enum` needs at least one value at offset " + open.to_string(),
    )
  }
  for v in items {
    // A literal the declared kind can never hold would be a rule that silently
    // never fires, which is the failure mode this parser exists to prevent.
    // A container kind admits object/array literals -- the JSON Schema bridge
    // builds exactly that from `const`, and `stringify` has to be able to
    // write it back.
    let is_scalar = match base.structure() {
      Obj(_) | Arr(_) | Any => false
      _ => true
    }
    match v {
      Json::Null
      | Json::True
      | Json::False
      | Json::Number(_, ..)
      | Json::String(_) => ()
      _ =>
        if is_scalar {
          raise SchemaError(
            " schema: `enum` admits only scalar literals at offset " +
            open.to_string(),
          )
        }
    }
    if !kind_accepts(base, v) {
      raise SchemaError(
        " schema: `enum` value " +
        v.stringify() +
        " is not a " +
        base.name() +
        ", at offset " +
        open.to_string(),
      )
    }
  }
  p.i = close
  items
}

///|
/// Index just after the bracket run that starts at `start`: a JSON array (or
/// any bracketed text) balanced across strings and escapes.
fn sp_scan_brackets(
  p : SchemaParser,
  start : Int32,
) -> Int32 raise LIWENJSONError {
  let n = p.text.length()
  let mut i = start
  let mut depth = 0
  while i < n {
    let c = p.text.at(i).to_int()
    if c == 0x22 {
      i = i + 1
      while i < n {
        let q = p.text.at(i).to_int()
        if q == 0x5C {
          i = i + 2
          continue
        }
        if q == 0x22 {
          i = i + 1
          break
        }
        i = i + 1
      }
      continue
    }
    if c == 0x5B || c == 0x7B {
      depth = depth + 1
    } else if c == 0x5D || c == 0x7D {
      depth = depth - 1
      if depth <= 0 {
        return i + 1
      }
    }
    i = i + 1
  }
  raise SchemaError(
    " schema: the array of `enum` is never closed at offset " +
    start.to_string(),
  )
}

///|
/// A `pattern` value: one character class, `[...]`, and nothing else.
fn sp_constraint_class(p : SchemaParser) -> String raise LIWENJSONError {
  let n = p.text.length()
  if p.i >= n || p.text.at(p.i).to_int() != 0x5B {
    raise SchemaError(
      " schema: `pattern` accepts a character class `[...]` and nothing else, at offset " +
      p.i.to_string(),
    )
  }
  let open = p.i
  p.i = p.i + 1
  let sb = StringBuilder()
  while p.i < n && p.text.at(p.i).to_int() != 0x5D {
    let c = p.text.at(p.i).to_int()
    if c == 0x5C && p.i + 1 < n {
      sb.write_char(Int32::unsafe_to_char(c))
      sb.write_char(Int32::unsafe_to_char(p.text.at(p.i + 1).to_int()))
      p.i = p.i + 2
      continue
    }
    sb.write_char(Int32::unsafe_to_char(c))
    p.i = p.i + 1
  }
  if p.i >= n {
    raise SchemaError(
      " schema: the character class of `pattern` is never closed at offset " +
      open.to_string(),
    )
  }
  p.i = p.i + 1
  let inner = sb.to_string()
  guard_class(inner, open)
  inner
}

///|
/// Reject anything a character class cannot mean, at parse time and with the
/// offset of the class: an empty class, an escape that is not one of the eight,
/// a range that starts or ends at an escape, and an inverted range. Everything
/// else (including `.`, `*` and `+` inside the brackets) is a literal character,
/// which is the whole point of "a character class, not a regular expression".
fn guard_class(inner : String, open : Int32) -> Unit raise LIWENJSONError {
  let n = inner.length()
  let mut i = 0
  let mut prev_escape = false
  if n == 0 {
    raise SchemaError(
      " schema: an empty character class matches nothing, at offset " +
      open.to_string(),
    )
  }
  if inner.at(0).to_int() == 0x5E {
    i = 1
    if i >= n {
      raise SchemaError(
        " schema: `[^]` negates an empty character class, at offset " +
        open.to_string(),
      )
    }
  }
  while i < n {
    let c = inner.at(i).to_int()
    if c == 0x5C {
      if i + 1 >= n {
        raise SchemaError(
          " schema: `\\` ends the character class of `pattern` at offset " +
          open.to_string(),
        )
      }
      let e = inner.at(i + 1).to_int()
      if !(e == 0x5C ||
        e == 0x5D ||
        e == 0x2D ||
        e == 0x5E ||
        e == 0x6E ||
        e == 0x74 ||
        e == 0x72 ||
        e == 0x64 ||
        e == 0x77 ||
        e == 0x73) {
        raise SchemaError(
          " schema: `\\" +
          Int32::unsafe_to_char(e).to_string() +
          "` is not a character class escape at offset " +
          open.to_string() +
          "; the language has \\\\ \\] \\- \\^ \\n \\t \\r \\d \\w \\s",
        )
      }
      prev_escape = true
      i = i + 2
      continue
    }
    if c == 0x2D && i > 0 && i + 1 < n {
      if prev_escape {
        raise SchemaError(
          " schema: a character class range cannot start at an escape, at offset " +
          open.to_string(),
        )
      }
      let hi = inner.at(i + 1).to_int()
      if hi == 0x5C {
        raise SchemaError(
          " schema: a character class range cannot end at an escape, at offset " +
          open.to_string(),
        )
      }
      if inner.at(i - 1).to_int() > hi {
        raise SchemaError(
          " schema: the character class range at offset " +
          open.to_string() +
          " is inverted",
        )
      }
      prev_escape = false
      i = i + 2
      continue
    }
    prev_escape = false
    i = i + 1
  }
}

///|
/// A member name: a bare identifier, or a double quoted string.
fn sp_key(p : SchemaParser) -> String raise LIWENJSONError {
  let n = p.text.length()
  if p.i < n && p.text.at(p.i).to_int() == 0x22 {
    p.i = p.i + 1
    let sb = StringBuilder()
    while p.i < n && p.text.at(p.i).to_int() != 0x22 {
      sb.write_char(Int32::unsafe_to_char(p.text.at(p.i).to_int()))
      p.i = p.i + 1
    }
    if p.i >= n {
      raise SchemaError(" quoted member name is never closed")
    }
    p.i = p.i + 1
    return sb.to_string()
  }
  let sb = StringBuilder()
  while p.i < n {
    let c = p.text.at(p.i).to_int()
    if c == 0x3A || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      break
    }
    sb.write_char(Int32::unsafe_to_char(p.text.at(p.i).to_int()))
    p.i = p.i + 1
  }
  if sb.to_string() == "" {
    raise SchemaError(" a member name cannot be empty")
  }
  sb.to_string()
}

///|
/// Reject a declaration that names the same member twice: the order of the two
/// would decide which one wins, which is exactly the kind of silent choice this
/// library refuses to make elsewhere.
fn guard_no_dup(members : Array[SchemaMember]) -> Unit raise LIWENJSONError {
  for i = 0; i < members.length(); i = i + 1 {
    for j = i + 1; j < members.length(); j = j + 1 {
      if members[i].key == members[j].key {
        raise SchemaError(
          "schema: member `" + members[i].key + "` is declared twice",
        )
      }
    }
  }
}

///|
/// Parse the text form of a skeleton (FR-36). Raises `E070` with the offset of
/// the problem; the text is never partially accepted.
pub fn Schema::parse(text : String) -> Schema raise LIWENJSONError {
  let p : SchemaParser = { text, i: 0, depth: 0, }
  let s = sp_schema(p)
  sp_skip_ws(p)
  if p.i < text.length() {
    raise SchemaError(
      "schema: unexpected text after the declaration at offset " +
      p.i.to_string(),
    )
  }
  s
}

// ---------------------------------------------------------------------------
// Evaluation.
// ---------------------------------------------------------------------------

///|
/// One declared member whose value does not satisfy its declaration (FR-36).
///
/// `expected` is the violated constraint when there is exactly one to name
/// (`integer >= 0`, `string with length <= 64`, `one of ["low","high"]`,
/// `string of characters in [a-z]`) and the whole declaration otherwise
/// (`integer(minimum:0)`).
pub(all) struct SchemaMismatch {
  path : String
  expected : String
  got : String
}

///|
/// The verdict of one value against a skeleton (FR-36).
pub(all) struct SchemaVerdict {
  /// Declared members, counting nesting, that a value is expected to provide.
  /// A member of an `any` or `array` node is not walked: the skeleton says
  /// nothing about it.
  total : Int32
  /// Required members that are present and satisfy the declared kind and the
  /// declared constraints.
  satisfied : Int32
  /// Required members that are absent, as dotted paths.
  missing : Array[String]
  /// Present members that hold a value of the wrong kind or violate a declared
  /// constraint.
  mismatched : Array[SchemaMismatch]
  /// Whether every required member is satisfied. Optional members are checked
  /// for kind when present and never counted as missing.
  ok : Bool
}

///|
/// Whether `v` is a whole number.
fn is_integer(v : Json) -> Bool {
  match v {
    // `Int32` round trip made `2147483648` a non-integer, because the
    // conversion saturates. The exact decimal decides: `1.0`, `1e3` and
    // `2147483648` are whole numbers, `1.5` is not.
    Json::Number(d, ..) =>
      match number_dec(v) {
        Some(dec) => dec.is_integer()
        // No exact decimal (a text with an unrepresentable exponent): the
        // double decides, and an infinity is not a whole number.
        None => !d.is_nan() && !d.is_inf() && d == d.floor()
      }
    _ => false
  }
}

///|
/// Whether `v` has the declared kind (FR-36), ignoring constraints.
fn kind_accepts(schema : Schema, v : Json) -> Bool {
  match (schema, v) {
    (Constrained(inner, _), _) => kind_accepts(inner, v)
    (Any, _) => true
    (Null, Json::Null) => true
    (Bool, Json::True) | (Bool, Json::False) => true
    (Num, Json::Number(_, ..)) => true
    (Int, Json::Number(_, ..)) => is_integer(v)
    (Str, Json::String(_)) => true
    (Arr(_), Json::Array(_)) => true
    (Obj(_), Json::Object(_)) => true
    _ => false
  }
}

///|
/// Whether `v` has the declared kind **and** satisfies the declared value
/// constraints (FR-36, 0.7.0). A declaration with no constraints accepts
/// exactly what it accepted in 0.6.x.
///
/// The layers of a hand-built `Constrained(Constrained(…))` are conjunctive,
/// exactly like two keywords on one JSON Schema node: every layer applies, and
/// an inner constraint is not erased by an outer one.
pub fn Schema::accepts(self : Schema, v : Json) -> Bool {
  match self {
    Constrained(inner, c) =>
      if !inner.accepts(v) {
        false
      } else {
        match c.violation(inner.name(), v) {
          Some(_) => false
          None =>
            match closure_problem(inner, c, v) {
              Some(_) => false
              None => true
            }
        }
      }
    _ => kind_accepts(self, v)
  }
}

///|
/// The constraint `v` violates, when the kind is right. `None` means either
/// "no constraint was violated" or "the kind itself is wrong"; the caller
/// reports the whole declaration in the second case.
fn Schema::constraint_problem(self : Schema, v : Json) -> String? {
  match self {
    Constrained(inner, c) =>
      if !kind_accepts(inner, v) {
        None
      } else {
        match c.violation(inner.name(), v) {
          Some(e) => Some(e)
          None =>
            match closure_problem(inner, c, v) {
              Some(e) => Some(e)
              None => inner.constraint_problem(v)
            }
        }
      }
    _ => None
  }
}

///|
/// The `expected` string of a mismatch: the violated constraint when there is
/// exactly one to name, the whole declaration otherwise.
fn mismatch_expected(schema : Schema, v : Json) -> String {
  match schema.constraint_problem(v) {
    Some(e) => e
    None => schema.expectation()
  }
}

///|
/// Walk `value` against `schema` (FR-36). `path` is the canonical path of the
/// node, empty at the root.
///
/// `evaluate` walks *declared members*: a root that declares no members has
/// none to walk, which is why a bare kind at the root (`integer`, `string`) is
/// only answered by `accepts` and not by a mismatch. A constrained kind is the
/// exception, and deliberately so: a constraint is an explicit claim about the
/// value, and a claim that is silently dropped is worse than no claim, so a
/// constrained scalar at the root is checked here (`integer(minimum:0)` against
/// `-1` reports `integer >= 0` as `expected`).
pub fn Schema::evaluate(self : Schema, value : Json) -> SchemaVerdict {
  let total : Array[Int32] = [0]
  let satisfied : Array[Int32] = [0]
  let missing : Array[String] = []
  let mismatched : Array[SchemaMismatch] = []
  walk_schema(self, value, "", total, satisfied, missing, mismatched)
  let ok = missing.length() == 0 && mismatched.length() == 0
  { total: total[0], satisfied: satisfied[0], missing, mismatched, ok, }
}

///|
/// The walk behind `Schema::evaluate`.
///
/// It is **iterative**, for the same reason `copy_json` and `json_equal` are:
/// a recursive walk made the deepest checkable value a property of the native
/// stack (the wasm backend gives up somewhere between 896 and 1024 frames),
/// which is what forced `Options::max_depth` to carry a ceiling it should not
/// have needed. With an explicit work list the depth is bounded by the heap.
///
/// The traversal order is the recursive order -- depth first, members in
/// declaration order -- because `missing` and `mismatched` are reported to the
/// caller in that order and the tests pin it. Children are therefore pushed in
/// reverse, so they pop in order.
fn walk_schema(
  schema : Schema,
  value : Json,
  path : String,
  total : Array[Int32],
  satisfied : Array[Int32],
  missing : Array[String],
  mismatched : Array[SchemaMismatch],
) -> Unit {
  let work : Array[(Schema, Json, String)] = [(schema, value, path)]
  while work.length() > 0 {
    let (s, v, p) = work.remove(work.length() - 1)
    walk_schema_step(s, v, p, total, satisfied, missing, mismatched, work)
  }
}

///|
/// One node of the walk. Children that need walking are pushed onto `work`.
fn walk_schema_step(
  schema : Schema,
  value : Json,
  path : String,
  total : Array[Int32],
  satisfied : Array[Int32],
  missing : Array[String],
  mismatched : Array[SchemaMismatch],
  work : Array[(Schema, Json, String)],
) -> Unit {
  match schema {
    Obj(members) =>
      match value {
        Json::Object(map) => {
          let pending : Array[(Schema, Json, String)] = []
          for m in members {
            let here = path_append(path, m.key)
            let child = match map.get(m.key) {
              Some(v) => v
              None => {
                if m.required {
                  missing.push(here)
                }
                total[0] = total[0] + 1
                continue
              }
            }
            total[0] = total[0] + 1
            if m.schema.accepts(child) {
              satisfied[0] = satisfied[0] + 1
              // A container is walked: the skeleton can constrain deeper. The
              // test is on the *structure* so a container that carries value
              // constraints (`{...}(enum:[...])`, `[...](const:...)`) is still
              // walked instead of being treated as a leaf.
              match m.schema.structure() {
                Obj(_) | Arr(_) => pending.push((m.schema, child, here))
                _ => ()
              }
            } else {
              mismatched.push({
                path: here,
                expected: mismatch_expected(m.schema, child),
                got: kind_of(child),
              })
            }
          }
          push_reversed(pending, work)
        }
        _ =>
          mismatched.push({
            path: if path == "" {
              "<root>"
            } else {
              path
            },
            expected: "object",
            got: kind_of(value),
          })
      }
    Arr(inner) =>
      match value {
        Json::Array(items) => {
          let pending : Array[(Schema, Json, String)] = []
          for i = 0; i < items.length(); i = i + 1 {
            let here = path_append(path, i.to_string())
            if inner.accepts(items[i]) {
              pending.push((inner, items[i], here))
            } else {
              mismatched.push({
                path: here,
                expected: mismatch_expected(inner, items[i]),
                got: kind_of(items[i]),
              })
            }
          }
          push_reversed(pending, work)
        }
        _ =>
          mismatched.push({
            path: if path == "" {
              "<root>"
            } else {
              path
            },
            expected: "array",
            got: kind_of(value),
          })
      }
    Constrained(_, _) =>
      // A constrained node is two claims about the same value: the constraint
      // on the value and the shape inside it. Both are checked, never one
      // instead of the other.
      //
      // The root is the only node nobody has checked yet -- a node pushed by
      // its parent was already accepted there -- so the value-level check runs
      // only at `path == ""` and the walk then descends into the shape. Before
      // the audit fix the descent did not happen at all, which is why an object
      // or an array carrying `const`/`enum` had its `required` members and
      // `items` silently ignored.
      if path == "" && !schema.accepts(value) {
        mismatched.push({
          path: "<root>",
          expected: mismatch_expected(schema, value),
          got: kind_of(value),
        })
      } else {
        // Push the *structure*, not the wrapper: the constraint was checked
        // above (or by the parent), and re-pushing the wrapper would walk it
        // again.
        let shape = schema.structure()
        match shape {
          Obj(_) | Arr(_) => work.push((shape, value, path))
          _ => ()
        }
      }
    // A bare scalar kind at the root declares no members, but the declaration
    // is still a claim about the value: `{"type":"string"}` must reject `42`.
    // Below the root the parent has already checked the member's kind and
    // constraints, so the claim is not repeated (and would double-count).
    _ =>
      if path == "" && !schema.accepts(value) {
        mismatched.push({
          path: "<root>",
          expected: schema.expectation(),
          got: kind_of(value),
        })
      }
  }
}

///|
/// Push `items` onto `work` in reverse, so that they pop in their original
/// order: the walk has to visit a node's children in the order a recursive
/// walk would, because that is the order the caller is told about them.
fn push_reversed(
  items : Array[(Schema, Json, String)],
  work : Array[(Schema, Json, String)],
) -> Unit {
  let mut i = items.length()
  while i > 0 {
    i = i - 1
    work.push(items[i])
  }
}

///|
/// The JSON kind of a value, for a mismatch message.
pub fn kind_of(v : Json) -> String {
  match v {
    Json::Null => "null"
    Json::True | Json::False => "boolean"
    Json::Number(_, ..) => "number"
    Json::String(_) => "string"
    Json::Array(_) => "array"
    Json::Object(_) => "object"
  }
}

///|
/// One step of `Schema::required_paths`'s work list: enter a declaration node,
/// or leave the `Obj` member array being walked.
///
/// The leave step is what keeps the cycle check to the *current* ancestor chain.
/// A global "seen" set would call a legal shared sub-declaration a cycle; an
/// ancestor chain cannot, because the entry is gone by the time a sibling
/// references the same array.
priv enum RequiredStep {
  /// Enter one declaration node at its canonical path. The flag says whether
  /// the node is a required member whose path must be recorded (the root is
  /// not) -- recording it on entry, rather than when the parent looks at it,
  /// is what keeps the order depth-first and matches the recursive form.
  RequiredNode(Schema, String, Int32, Bool)
  RequiredLeave
}

///|
/// The canonical paths of the required members of a skeleton, in declaration
/// order (FR-36).
///
/// A required object contributes its own path and, recursively, the required
/// members inside it. An optional member contributes nothing: a member that may
/// be absent cannot hold up readiness. An array is one path, because the number
/// of elements a model will emit is not declared.
///
/// Iterative, and guarded: a hand-built declaration may be tens of thousands of
/// levels deep, and its `Array` members are mutable, so a self-reference is
/// constructible. The depth and node budgets stop a walk that would never
/// finish and the ancestor-chain check reports a cycle as `E070`, never as a
/// crash. Neither redeems a walk of a legal shared sub-declaration twice.
pub fn Schema::required_paths(
  self : Schema,
  depth_budget? : Int32,
  node_budget? : Int32,
) -> Array[String] raise LIWENJSONError {
  let max_depth = match depth_budget {
    Some(v) => v
    None => MAX_SCHEMA_WALK_DEPTH
  }
  let max_nodes = match node_budget {
    Some(v) => v
    None => MAX_SCHEMA_WALK_NODES
  }
  let out : Array[String] = []
  let work : Array[RequiredStep] = [RequiredNode(self, "", 0, false)]
  let ancestors : Array[Array[SchemaMember]] = []
  let mut nodes = 0
  while work.length() > 0 {
    match work.remove(work.length() - 1) {
      RequiredLeave => {
        let _ = ancestors.remove(ancestors.length() - 1)
      }
      RequiredNode(schema, base, depth, emit) => {
        if depth > max_depth {
          raise SchemaError(
            "the schema is nested more deeply than a traversal may walk",
          )
        }
        nodes = nodes + 1
        if nodes > max_nodes {
          raise SchemaError("the schema is larger than a traversal may walk")
        }
        if emit {
          out.push(base)
        }
        // The structure is what is walked, not the wrapper: a required member
        // inside `{...}(enum:[...])` is still required, and the watcher has to
        // follow it.
        match schema.structure() {
          Obj(members) => {
            for anc in ancestors {
              if physical_equal(anc, members) {
                raise SchemaError("the schema contains a cycle")
              }
            }
            ancestors.push(members)
            work.push(RequiredLeave)
            let pending : Array[RequiredStep] = []
            for m in members {
              if m.required {
                pending.push(
                  RequiredNode(
                    m.schema,
                    path_append(base, m.key),
                    depth + 1,
                    true,
                  ),
                )
              }
            }
            // Children are pushed in reverse so that they pop in declaration
            // order, which is the order `out` has to be in.
            let mut i = pending.length()
            while i > 0 {
              i = i - 1
              work.push(pending[i])
            }
          }
          _ => ()
        }
      }
    }
  }
  out
}

///|
/// Look up a canonical path in a value, where a numeric step inside an array is
/// an index (FR-36). `""` is the value itself and `/` is the member named `""`.
pub fn lookup_path(v : Json, path : String) -> Json? {
  let mut cur = v
  for step in path_texts(path) {
    cur = match cur {
      Json::Object(map) =>
        match map.get(step) {
          Some(inner) => inner
          None => return None
        }
      Json::Array(items) => {
        let idx = path_index_step(step)
        if idx < 0 || idx >= items.length() {
          return None
        }
        items[idx]
      }
      _ => return None
    }
  }
  Some(cur)
}

// ---------------------------------------------------------------------------
// Semantic readiness: syntax + schema.
// ---------------------------------------------------------------------------

///|
/// How much of a skeleton was already final, and when (FR-36).
pub(all) struct SemanticReadiness {
  /// First input fraction, in per mille, at which the document needed no more
  /// closing, or `1000` when that never happened before the end.
  syntax_permille : Int32
  /// First input fraction, in per mille, at which every required member of the
  /// skeleton was already present and final *and* the document satisfied the
  /// skeleton, or `1000` when that never happened before the end. A document
  /// that is decidable and invalid never fires here: see `settled_permille`.
  schema_permille : Int32
  /// First input fraction, in per mille, at which every required member of the
  /// skeleton was already present and final, whether or not it had the declared
  /// kind (FR-39). This is the moment a *runtime* can decide: `schema_permille`
  /// answers "may I execute", this answers "do I know yet".
  settled_permille : Int32
  /// Sampling step actually used.
  step : Int32
  /// Verdict of the finished document.
  verdict : SchemaVerdict
}

///|
/// Per mille of `whole` that `part` is, without dividing by zero.
///
/// The multiplication is done in `Int64`: `part * 1000` overflows `Int32` once
/// `part` passes 2,147,483, which is a little over 2 MiB — smaller than the
/// default `max_input_len`, so any large-but-legal document could overflow it
/// and report a negative per-mille. Promoting before multiplying makes the
/// result exact for every `Int32` pair; when `0 <= part <= whole` it is in
/// 0..1000 by construction, so nothing needs to be clamped afterwards.
fn permille(part : Int32, whole : Int32) -> Int32 {
  if whole <= 0 {
    1000
  } else {
    (part.to_int64() * 1000L / whole.to_int64()).to_int()
  }
}

///|
/// Sampling step: `step` when positive, otherwise one that samples a document
/// about a thousand times.
pub fn auto_step(n : Int32, step : Int32) -> Int32 {
  if step > 0 {
    step
  } else {
    let auto = n / 1000
    if auto < 1 {
      1
    } else {
      auto
    }
  }
}

///|
/// The first input fraction at which the document was already the value it ends
/// up as (FR-29, FR-36). `-1` when the input cannot be parsed at all.
///
/// This is the "JSON syntax ready" number of the readiness report: it is 1000%
/// semantics but per mille of the input, i.e. 1000 means "not before the end".
pub fn syntax_readiness_permille(input : String, step? : Int32) -> Int32 {
  let n = input.length()
  if n == 0 {
    return -1
  }
  let fin = parse(input) catch { _ => return -1 }
  let st = auto_step(
    n,
    match step {
      Some(v) => v
      None => 0
    },
  )
  let parser = PartialParser::new() catch { _ => return -1 }
  let mut i = 0
  while i < n {
    let next = if i + st > n { n } else { i + st }
    parser.feed(input[i:next].to_owned()) catch {
      _ => return -1
    }
    i = next
    match parser.snapshot().value {
      Some(v) => if json_equal(v, fin.value) { return permille(i, n) }
      None => ()
    }
  }
  1000
}

///|
/// Syntax readiness and schema readiness of one document against one skeleton
/// (FR-36, FR-39).
///
/// Since 0.6.0 this is a thin report over `SemanticWatcher`: the document is fed
/// in `step`-sized pieces and the numbers are read off the events, so the cost
/// is one pass plus one delta drain per piece instead of one partial parse *and
/// one snapshot* per piece. The result is the same kind of measurement — a
/// fraction of the input — but it no longer rebuilds the value tree a thousand
/// times, and `settled_permille` is new: the moment the answer became final
/// even when the answer is no.
///
/// ## `duplicate_keys KeepFirst` (Q-36)
///
/// There is one implementation, not two. Before 0.7.0 this function had a second
/// one — the 0.5.0 sampling loop — reachable only through `KeepFirst`, because
/// the watcher's delta stream cannot carry a value that `KeepFirst` dropped. The
/// second implementation measured the same quantity by a different mechanism, so
/// its numbers were the *same kind* of number and not the same number, and it
/// was the last caller of the sampling loop.
///
/// It is gone. What happens now is a **composition**, and the split is stated
/// here because the two halves are answered from different places:
///
///   * the three permille numbers come from the watcher, which measures under
///     `duplicate_keys: KeepLast` (see `SemanticWatcher`): when the value at
///     each followed path stopped changing, and when the skeleton was
///     satisfied. On a document with a repeated name whose two values differ,
///     `settled_permille` is the first time every followed path was final — the
///     *first* value's offset, the same number the sampling loop reported — and
///     `syntax_permille` is measured on a tree the second value also touched, so
///     it can be *later* than before; never earlier, and only on documents with
///     duplicate names. `schema_permille` follows `settled` and the verdict;
///   * the `verdict` comes from `parse(input, options=opts)`, i.e. from the
///     caller's own duplicate-key policy. Under `KeepFirst` the first value is
///     the real one, so `verdict` is the `KeepFirst` truth even though the
///     watcher observed the last value. This is what keeps the two from
///     disagreeing silently: the numbers are a property of the *input*, the
///     verdict is a property of the *policy*.
///
/// `RepairPlan` and the analysis path are unaffected: they take their verdict
/// from `parse` under the requested options, as they always did.
pub fn semantic_readiness(
  input : String,
  schema : Schema,
  step? : Int32,
  options? : Options,
) -> SemanticReadiness raise LIWENJSONError {
  let opts = match options {
    Some(o) => o
    None => Options::default()
  }
  let n = input.length()
  let st = auto_step(
    n,
    match step {
      Some(v) => v
      None => 0
    },
  )
  // The caller's granularity, reported as `SemanticReadiness::step` and printed
  // by the CLI. It no longer decides the resolution of the three numbers (they
  // are exact now), so it is kept as the caller's declared sampling step.
  let w = SemanticWatcher::new(schema, options?)
  // One feed, not one feed per sample: since 0.7.0 every number below comes from
  // the `at` of the delta that produced the event, which does not depend on the
  // chunking (Q-35), so there is nothing left for a sample point to control. The
  // old loop fed `st` code units at a time — about a thousand `feed` calls per
  // document — and each chunk end then quantised `syntax` and `settled`. The
  // trade is that the delta queue holds the whole document for one drain; a
  // caller that cannot afford that should drive `SemanticWatcher` in chunks
  // itself.
  if n > 0 {
    w.feed(input)
  }
  let fin = w.finish()
  let required = schema.required_paths()
  let none_required = required.length() == 0
  // The verdict is the caller's: the watcher measured under `KeepLast`, so when
  // `KeepFirst` was asked for, the truth is what `parse` under those options
  // produces (Q-36).
  let verdict = if opts.duplicate_keys is KeepFirst {
    schema.evaluate(parse(input, options=opts).value)
  } else {
    schema.evaluate(fin.value)
  }
  let syntax = if w.syntax_at() < 0 { 1000 } else { permille(w.syntax_at(), n) }
  let settled = if none_required {
    0
  } else if w.settled_at() < 0 {
    1000
  } else {
    permille(w.settled_at(), n)
  }
  let schema_perm = if verdict.ok {
    if none_required {
      0
    } else if w.settled_at() < 0 {
      1000
    } else {
      permille(w.settled_at(), n)
    }
  } else {
    1000
  }
  {
    syntax_permille: syntax,
    schema_permille: schema_perm,
    settled_permille: settled,
    step: st,
    verdict,
  }
}
