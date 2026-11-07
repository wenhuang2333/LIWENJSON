// A bridge from the JSON Schema subset that agent tool declarations already
// use into the library's skeleton (`Schema`).
//
// The library is not a JSON Schema validator and does not aim to become one
// (`schema.mbt` explains why). What this file adds is narrower and more
// useful: the shape of a tool's `inputSchema` — object with typed properties,
// a `required` list, array items and the handful of value constraints the
// skeleton already understands — can be read directly, so an integration does
// not have to hand-translate the declaration it already has.
//
// The contract is deliberately strict:
//
//   * a supported keyword is mapped;
//   * an annotation (`title`, `description`, `default`, `examples`, `$schema`,
//     `$id`, `deprecated`, `readOnly`, `writeOnly`, `format`) is ignored;
//   * `additionalProperties: true` is a no-op, `false` closes the object: the
//     value may not carry a member the declaration does not name (1.5.2). It is
//     what an OpenAI "strict" declaration says, including the `inputSchema`
//     this server publishes itself, so refusing it made the server reject its
//     own tool declarations;
//   * anything else (`$ref`, `oneOf`, `anyOf`, `allOf`, `not`, `minItems`,
//     `uniqueItems`, `multipleOf`, …) is an `E070`, never a silent ignore.
//
// A gate that silently drops half of a declaration is worse than one that
// refuses it: the caller would believe a guarantee that was never checked.
//
// The keywords of one node are **conjunctive**, the way JSON Schema reads them,
// and the order they were written in means nothing:
//
//   * `const` and `enum` on the same node admit `{const}` ∩ `enum`; an empty
//     intersection is an `E070`, because the declaration can never be
//     satisfied;
//   * a node with `const`/`enum` *and* `properties`/`items` enforces both --
//     the value has to be in the set and its required members and element kinds
//     have to hold;
//   * the root node is checked like every other node.
//
// A declaration the skeleton cannot express exactly is refused rather than
// approximated: `items` without `type:"array"`, `properties`/`required` on a
// kind that is not an object, an empty `enum`, a `const` outside its `enum`,
// a bound pair that cannot be satisfied, and a `pattern` quantifier past
// `Int32` are all `E070`.

///|
/// Fields of a JSON Schema node that carry no validation meaning here.
fn json_schema_annotation(key : String) -> Bool {
  key == "title" ||
  key == "description" ||
  key == "default" ||
  key == "examples" ||
  key == "$schema" ||
  key == "$id" ||
  key == "$comment" ||
  key == "deprecated" ||
  key == "readOnly" ||
  key == "writeOnly"
}

///|
/// Keywords that are *annotations* in JSON Schema but assertions to a caller of
/// an execution gate.
///
/// `format` is an annotation in the standard: a validator may ignore it. Here,
/// ignoring it would mean `{"type":"string","format":"email"}` accepts
/// `"not-an-email"` while the caller who wrote the declaration believes email
/// addresses are checked, and this product's contract is "unsupported means
/// refused, never silently weaker". The whole set is therefore an `E070` with a
/// sentence that says what to do about it, rather than a keyword dropped on the
/// floor. The same reasoning applies to `contentEncoding` and
/// `contentMediaType`: they are claims about the bytes a string carries, and no
/// check here can back them.
fn json_schema_unchecked_assertion(key : String) -> Bool {
  key == "format" || key == "contentEncoding" || key == "contentMediaType"
}

///|
/// Refuse a keyword the skeleton cannot represent.
fn json_schema_unsupported(key : String) -> Unit raise InterJSONError {
  raise SchemaError(
    "json schema: unsupported keyword `" +
    key +
    "`; supported: type, properties, required, items, enum, const, minimum, maximum, exclusiveMinimum, exclusiveMaximum, minLength, maxLength, pattern, additionalProperties",
  )
}

///|
/// A numeric field, accepting an integer or a finite double.
fn json_schema_number(v : Json, key : String) -> Dec raise InterJSONError {
  match v {
    Json::Number(_, ..) =>
      match number_dec(v) {
        Some(d) =>
          // `1e9999999999` is a JSON number whose exact value this library
          // cannot compare. A bound the gate cannot enforce exactly is refused
          // at modelling time instead of being silently weakened.
          if d.text().length() == 0 {
            raise SchemaError(
              "json schema: `" + key + "` cannot be normalised exactly",
            )
          } else {
            d
          }
        None =>
          raise SchemaError(
            "json schema: `" + key + "` cannot be normalised exactly",
          )
      }
    _ => raise SchemaError("json schema: `" + key + "` must be a number")
  }
}

///|
/// A non-negative integer field.
///
/// `Int32::to_int` on a double outside its range is not a conversion the schema
/// can rely on, so the bound is checked in `Double` space first: a declaration
/// whose bound the implementation cannot represent is an `E070`, never a silent
/// clamp.
fn json_schema_uint(v : Json, key : String) -> Int32 raise InterJSONError {
  let d = json_schema_number(v, key)
  match d.length_value() {
    Some(n) => n
    None =>
      raise SchemaError(
        "json schema: `" +
        key +
        "` must be a non-negative integer no greater than 2147483647",
      )
  }
}

///|
/// A string field.
fn json_schema_string(v : Json, key : String) -> String raise InterJSONError {
  match v {
    Json::String(s) => s
    _ => raise SchemaError("json schema: `" + key + "` must be a string")
  }
}

///|
/// `required` as a lookup table.
fn json_schema_required(v : Json) -> Map[String, Bool] raise InterJSONError {
  let out : Map[String, Bool] = Map([])
  match v {
    Json::Array(items) =>
      for item in items {
        out[json_schema_string(item, "required")] = true
      }
    _ =>
      raise SchemaError("json schema: `required` must be an array of strings")
  }
  out
}

///|
/// A `pattern` translated into the skeleton's character class plus the length
/// bounds its quantifier implies.
priv struct PatternSpec {
  class_text : String
  min_len : Int32?
  max_len : Int32?
}

///|
/// Parse a decimal integer used in a `{n,m}` quantifier.
///
/// The accumulated value must be exactly the number that was written. Without
/// the check below, `n * 10 + digit` wraps around Int32 in silence, and
/// `{4294967296}` -- 2^32 -- became `{0}`: a declaration that requires an empty
/// string where it actually demanded two-to-the-thirty-second characters. The
/// bound is checked *before* the multiply-add, so no intermediate values are
/// computed.
fn json_schema_quantifier_int(s : StringView) -> Int32 raise InterJSONError {
  if s.length() == 0 {
    raise SchemaError("json schema: empty quantifier bound")
  }
  let mut n = 0
  for i = 0; i < s.length(); i = i + 1 {
    let c = s.at(i).to_int()
    if c < 0x30 || c > 0x39 {
      raise SchemaError(
        "json schema: quantifier bounds must be decimal integers",
      )
    }
    let digit = c - 0x30
    if n > (2147483647 - digit) / 10 {
      raise SchemaError(
        "json schema: quantifier bound exceeds 2147483647 and cannot be represented",
      )
    }
    n = n * 10 + digit
  }
  n
}

///|
/// Translate a JSON Schema `pattern` only when it is an anchored character
/// class, and turn its quantifier into length bounds.
///
/// JSON Schema's `pattern` is a regular expression and is *not* anchored: the
/// validator only requires a match somewhere in the string. The skeleton's
/// `pattern` requires every character to be in the class. Mapping an
/// unanchored expression onto it would be stricter (safe) but would silently
/// mean something else, so only anchored forms are accepted. The quantifier
/// then has an exact translation:
///
/// | pattern | skeleton |
/// | --- | --- |
/// | `^[a-z]*$` | `string(pattern:[a-z])` |
/// | `^[a-z]+$` | `string(minLength:1,pattern:[a-z])` |
/// | `^[a-z]?$` | `string(maxLength:1,pattern:[a-z])` |
/// | `^[a-z]$` | `string(minLength:1,maxLength:1,pattern:[a-z])` |
/// | `^[A-Z]{2,4}$` | `string(minLength:2,maxLength:4,pattern:[A-Z])` |
///
/// Everything else — `.`, `*` inside the class, escapes, alternation, groups —
/// is an `E070`.
fn json_schema_pattern(s : String) -> PatternSpec raise InterJSONError {
  let n = s.length()
  if n < 4 || s.at(0).to_int() != 0x5E || s.at(n - 1).to_int() != 0x24 {
    raise SchemaError(
      "json schema: `pattern` must be an anchored character class such as `^[a-z0-9_]*$`; unanchored or general regular expressions are not supported",
    )
  }
  // Drop the anchors.
  let body = s[1:n - 1].to_owned()
  if body.length() < 2 || body.at(0).to_int() != 0x5B {
    raise SchemaError("json schema: `pattern` must be a single character class")
  }
  // Find the closing bracket. Escapes are not supported, so the first `]`
  // closes the class.
  let mut close = 1
  while close < body.length() && body.at(close).to_int() != 0x5D {
    close = close + 1
  }
  if close >= body.length() {
    raise SchemaError("json schema: `pattern` has an unterminated class")
  }
  let inner = body[1:close].to_owned()
  if inner.contains("\\") || inner.contains("[") {
    raise SchemaError(
      "json schema: `pattern` character classes may not contain escapes or nested classes",
    )
  }
  let rest = body[close + 1:].to_owned()
  let (min_len, max_len) : (Int32?, Int32?) = if rest == "" {
    (Some(1), Some(1))
  } else if rest == "*" {
    (Some(0), None)
  } else if rest == "+" {
    (Some(1), None)
  } else if rest == "?" {
    (Some(0), Some(1))
  } else if rest.length() >= 2 &&
    rest.at(0).to_int() == 0x7B &&
    rest.at(rest.length() - 1).to_int() == 0x7D {
    let spec = rest[1:rest.length() - 1].to_owned()
    let parts = spec.split(",").to_array()
    if parts.length() == 1 {
      let k = json_schema_quantifier_int(parts[0])
      (Some(k), Some(k))
    } else if parts.length() == 2 {
      let lo = json_schema_quantifier_int(parts[0])
      if parts[1].length() == 0 {
        (Some(lo), None)
      } else {
        let hi = json_schema_quantifier_int(parts[1])
        if hi < lo {
          raise SchemaError(
            "json schema: quantifier upper bound is below its lower bound",
          )
        }
        (Some(lo), Some(hi))
      }
    } else {
      raise SchemaError("json schema: malformed quantifier")
    }
  } else {
    raise SchemaError(
      "json schema: unsupported `pattern` quantifier `" + rest + "`",
    )
  }
  { class_text: inner, min_len, max_len, }
}

///|
/// Build the constraint record of one leaf, or `None` when the node declared
/// no value constraint.
///
/// ## `const` and `enum` are conjunctive
///
/// Both keywords are assertions about the same value, so a node that carries
/// both admits exactly `const` when `const` is one of the `enum` values, and
/// nothing at all otherwise. They used to be written into the same field while
/// the object was being traversed, so the later keyword silently erased the
/// earlier one and *the order the keys happened to appear in decided whether
/// `{"mode":"write"}` passed the gate*. JSON objects are unordered; a security
/// decision cannot depend on their order. The two are therefore collected
/// separately and intersected once the traversal is over, which is what makes
/// the result independent of both the field order and the map's iteration
/// order.
///
/// The intersection is stored as the `enum` set because that is the skeleton's
/// only set-valued constraint: `const X` is the single-element set `[X]`, and
/// `const X ∩ enum [...]` is `[X]` when `X` is in the list. A declaration whose
/// intersection is empty can never be satisfied, so it is an `E070` at
/// modelling time rather than a gate that rejects everything at runtime.
fn json_schema_constraints(
  obj : Map[String, Json],
  kind : Schema,
) -> Constraints? raise InterJSONError {
  let c = Constraints::none()
  let mut any = false
  let mut pattern_spec : PatternSpec? = None
  // Collected separately from `c.enum_values` so neither keyword can erase the
  // other; intersected after the loop, so the result is order-independent.
  let mut const_value : Json? = None
  let mut enum_values : Array[Json]? = None
  for key, value in obj {
    if key == "enum" {
      match value {
        Json::Array(items) => {
          if items.length() == 0 {
            raise SchemaError(
              "json schema: `enum` must have at least one value; an empty `enum` can never be satisfied",
            )
          }
          enum_values = Some(items.copy())
        }
        _ => raise SchemaError("json schema: `enum` must be an array")
      }
    } else if key == "const" {
      const_value = Some(value)
    } else if key == "minimum" {
      c.minimum = Some(json_schema_number(value, key))
      any = true
    } else if key == "exclusiveMinimum" {
      c.exclusive_minimum = Some(json_schema_number(value, key))
      any = true
    } else if key == "maximum" {
      c.maximum = Some(json_schema_number(value, key))
      any = true
    } else if key == "exclusiveMaximum" {
      c.exclusive_maximum = Some(json_schema_number(value, key))
      any = true
    } else if key == "additionalProperties" {
      match value {
        Json::False => {
          c.additional_properties_closed = true
          any = true
        }
        _ => ()
      }
    } else if key == "minLength" {
      c.min_length = Some(json_schema_uint(value, key))
      any = true
    } else if key == "maxLength" {
      c.max_length = Some(json_schema_uint(value, key))
      any = true
    } else if key == "pattern" {
      let spec = json_schema_pattern(json_schema_string(value, key))
      c.pattern = Some(spec.class_text)
      pattern_spec = Some(spec)
      any = true
    }
  }
  match (const_value, enum_values) {
    (Some(k), Some(items)) => {
      // `const ∩ enum`: keep the constant only when the enumeration admits it.
      // Structural equality (`json_equal`), because JSON Schema's `const` and
      // `enum` compare values, not text or references.
      let mut hit = false
      for v in items {
        if json_equal(v, k) {
          hit = true
          break
        }
      }
      if !hit {
        raise SchemaError(
          "json schema: `const` " +
          k.stringify() +
          " is not one of the declared `enum` values; the declaration can never be satisfied",
        )
      }
      c.enum_values = Some([k])
      any = true
    }
    (Some(k), None) => {
      c.enum_values = Some([k])
      any = true
    }
    (None, Some(items)) => {
      c.enum_values = Some(items)
      any = true
    }
    (None, None) => ()
  }
  match pattern_spec {
    Some(spec) => {
      // The quantifier is a length bound. Combine it with an explicit
      // `minLength`/`maxLength` by intersection; an empty intersection means
      // the declaration can never match, which is an E070 rather than a gate
      // that rejects everything at runtime.
      let lo = match (c.min_length, spec.min_len) {
        (Some(a), Some(b)) => Some(if a > b { a } else { b })
        (Some(a), None) => Some(a)
        (None, b) => b
      }
      let hi = match (c.max_length, spec.max_len) {
        (Some(a), Some(b)) => Some(if a < b { a } else { b })
        (Some(a), None) => Some(a)
        (None, b) => b
      }
      match (lo, hi) {
        (Some(a), Some(b)) =>
          if a > b {
            raise SchemaError(
              "json schema: `pattern` quantifier and length bounds cannot be satisfied together",
            )
          }
        _ => ()
      }
      c.min_length = match lo {
        Some(0) => None
        _ => lo
      }
      c.max_length = hi
    }
    None => ()
  }
  if !any {
    return None
  }
  // A bound pair that cannot be satisfied together is a declaration error, not
  // a rule that silently never fires. The comparison is on the raw bounds, so
  // it does not matter which order the keywords were written in.
  if c.min_length is Some(lo) && c.max_length is Some(hi) && lo > hi {
    raise SchemaError(
      "json schema: `minLength` exceeds `maxLength`; the declaration can never be satisfied",
    )
  }
  match (c.minimum, c.maximum) {
    (Some(lo), Some(hi)) =>
      if lo.compare(hi) > 0 {
        raise SchemaError(
          "json schema: `minimum` exceeds `maximum`; the declaration can never be satisfied",
        )
      }
    _ => ()
  }
  match (c.minimum, c.exclusive_maximum) {
    (Some(lo), Some(hi)) =>
      if lo.compare(hi) >= 0 {
        raise SchemaError(
          "json schema: `minimum` is not below `exclusiveMaximum`; the declaration can never be satisfied",
        )
      }
    _ => ()
  }
  match (c.exclusive_minimum, c.maximum) {
    (Some(lo), Some(hi)) =>
      if lo.compare(hi) >= 0 {
        raise SchemaError(
          "json schema: `exclusiveMinimum` is not below `maximum`; the declaration can never be satisfied",
        )
      }
    _ => ()
  }
  match (c.exclusive_minimum, c.exclusive_maximum) {
    (Some(lo), Some(hi)) =>
      if lo.compare(hi) >= 0 {
        raise SchemaError(
          "json schema: `exclusiveMinimum` is not below `exclusiveMaximum`; the declaration can never be satisfied",
        )
      }
    _ => ()
  }
  // The kind determines which constraints make sense. Refusing a mismatched
  // constraint here is the same policy as `Schema::parse`: a declaration that
  // can never fire is an `E070`, not a silently weaker gate.
  let has_number_constraint = c.minimum is Some(_) ||
    c.maximum is Some(_) ||
    c.exclusive_minimum is Some(_) ||
    c.exclusive_maximum is Some(_)
  let has_string_constraint = c.min_length is Some(_) ||
    c.max_length is Some(_) ||
    c.pattern is Some(_)
  if c.additional_properties_closed {
    match kind.structure() {
      Obj(_) => ()
      _ =>
        raise SchemaError(
          "json schema: `additionalProperties` applies to `type: \"object\"` only",
        )
    }
  }
  match kind {
    Int | Num =>
      if has_string_constraint {
        raise SchemaError(
          "json schema: length/pattern constraints apply to strings, not numbers",
        )
      }
    Str =>
      if has_number_constraint {
        raise SchemaError(
          "json schema: numeric constraints apply to numbers, not strings",
        )
      }
    _ =>
      if has_number_constraint || has_string_constraint {
        raise SchemaError(
          "json schema: value constraints are not supported on this kind",
        )
      }
  }
  Some(c)
}

///|
/// Translate one JSON Schema node into a skeleton.
fn json_schema_node(v : Json) -> Schema raise InterJSONError {
  json_schema_node_at(v, 0)
}

///|
/// The recursive half of `json_schema_node`, carrying the current depth.
///
/// A declaration is external input -- it is the tool's `inputSchema`, supplied
/// by a host -- so it must not be able to exhaust the stack. The limit is
/// `MAX_SCHEMA_DEPTH` and the failure is a documented `E070`, not a crash.
fn json_schema_node_at(v : Json, depth : Int32) -> Schema raise InterJSONError {
  if depth > MAX_SCHEMA_DEPTH {
    raise SchemaError(
      "json schema: declaration nests deeper than " +
      MAX_SCHEMA_DEPTH.to_string() +
      " levels",
    )
  }
  match v {
    Json::Object(obj) => {
      // Walk every keyword first so an unsupported one is named even if another
      // field is malformed.
      for key, value in obj {
        if json_schema_annotation(key) ||
          key == "type" ||
          key == "properties" ||
          key == "required" ||
          key == "items" ||
          key == "enum" ||
          key == "const" ||
          key == "minimum" ||
          key == "maximum" ||
          key == "exclusiveMinimum" ||
          key == "exclusiveMaximum" ||
          key == "minLength" ||
          key == "maxLength" ||
          key == "pattern" {
          continue
        }
        if key == "additionalProperties" {
          // `true` (the JSON Schema default) adds nothing the skeleton can
          // check. `false` is the closure of the object, which the skeleton
          // enforces since 1.5.2: it is what every OpenAI "strict" tool
          // declaration says, so refusing it made the server reject the very
          // declarations it publishes itself.
          match value {
            Json::True => continue
            Json::False => continue
            _ =>
              raise SchemaError(
                "json schema: `additionalProperties` must be a boolean",
              )
          }
        }
        if json_schema_unchecked_assertion(key) {
          raise SchemaError(
            "json schema: `" +
            key +
            "` is not checked by InterJSON; remove it (it would otherwise read as a guarantee) or validate it in the host",
          )
        }
        json_schema_unsupported(key)
      }
      let mut kind_name = ""
      match obj.get("type") {
        Some(Json::String(s)) => kind_name = s
        Some(Json::Array(items)) => {
          // `["string","null"]`-style unions are common but the skeleton has
          // no union. A one-element array is harmless; anything else is not.
          if items.length() != 1 {
            raise SchemaError(
              "json schema: `type` arrays are not supported; use a single type",
            )
          }
          kind_name = json_schema_string(items[0], "type")
        }
        Some(_) => raise SchemaError("json schema: `type` must be a string")
        None =>
          // No `type` but an object shape: treat it as an object, which is
          // what every tool declaration means.
          if obj.contains("properties") || obj.contains("required") {
            kind_name = "object"
          }
      }
      // A structural keyword that the resolved kind never reads would be
      // silently dropped, which is the failure mode this bridge exists to
      // prevent. `{"items": {...}}` is the sharp case: JSON Schema means "if
      // the value is an array, its elements must match", and inferring `array`
      // from it would reject the non-arrays JSON Schema allows, so the only
      // sound answer is `E070`.
      if obj.contains("items") && kind_name != "array" {
        raise SchemaError(
          "json schema: `items` requires `type: \"array\"`; the skeleton cannot express \"if this is an array\"",
        )
      }
      if (obj.contains("properties") || obj.contains("required")) &&
        kind_name != "object" {
        raise SchemaError(
          "json schema: `properties`/`required` require `type: \"object\"`",
        )
      }
      let base : Schema = if kind_name == "" || kind_name == "any" {
        Any
      } else if kind_name == "null" {
        Null
      } else if kind_name == "boolean" {
        Bool
      } else if kind_name == "number" {
        Num
      } else if kind_name == "integer" {
        Int
      } else if kind_name == "string" {
        Str
      } else if kind_name == "array" {
        let item = match obj.get("items") {
          Some(s) => json_schema_node_at(s, depth + 1)
          None => Any
        }
        Arr(item)
      } else if kind_name == "object" {
        let required = match obj.get("required") {
          Some(r) => json_schema_required(r)
          None => Map([])
        }
        let members : Array[SchemaMember] = []
        let seen : Map[String, Bool] = Map([])
        match obj.get("properties") {
          Some(Json::Object(props)) =>
            for key, sub in props {
              members.push({
                key,
                required: required.get(key).unwrap_or(false),
                schema: json_schema_node_at(sub, depth + 1),
              })
              seen[key] = true
            }
          Some(_) =>
            raise SchemaError("json schema: `properties` must be an object")
          None => ()
        }
        // A required member may be declared without a `properties` entry; in
        // JSON Schema that means "present, any value".
        for key, _ in required {
          if !seen.get(key).unwrap_or(false) {
            members.push({ key, required: true, schema: Any, })
          }
        }
        Obj(members)
      } else {
        raise SchemaError("json schema: unknown type `" + kind_name + "`")
      }
      match json_schema_constraints(obj, base) {
        Some(c) => Constrained(base, c)
        None => base
      }
    }
    _ =>
      raise SchemaError(
        "json schema: a schema node must be an object with a `type`, `properties`, `items`, `enum` or `const`",
      )
  }
}

///|
/// Translate a JSON Schema subset into the library's skeleton.
///
/// The supported subset is the part a tool declaration actually uses:
///
/// ```
/// { "type": "object",
///   "properties": { "query": { "type": "string" },
///                   "limit": { "type": "integer", "minimum": 1 } },
///   "required": ["query"] }
/// ```
///
/// is the same skeleton as `{!query:string,?limit:integer(minimum:1)}`.
/// Unsupported keywords raise `E070`; annotations are ignored.
pub fn Schema::of_json_schema(value : Json) -> Schema raise InterJSONError {
  json_schema_node(value)
}

///|
/// Parse JSON Schema text and translate it.
pub fn Schema::parse_json_schema(text : String) -> Schema raise InterJSONError {
  let value = @json.parse(text) catch {
    _ => raise SchemaError("json schema: input is not valid JSON")
  }
  json_schema_node(value)
}
