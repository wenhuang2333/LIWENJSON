// Small JSON readers used by the event adapters. The event envelope is a
// complete JSON document, so it is parsed with the strict core parser; only the
// field access needs helpers.

///|
/// Object value of `v`, if it is an object.
pub fn as_object(v : Json) -> Map[String, Json]? {
  match v {
    Json::Object(m) => Some(m)
    _ => None
  }
}

///|
/// Array value of `v`, if it is an array.
pub fn as_array(v : Json) -> Array[Json]? {
  match v {
    Json::Array(a) => Some(a)
    _ => None
  }
}

///|
/// String value of `v`, if it is a string.
pub fn as_string(v : Json) -> String? {
  match v {
    Json::String(s) => Some(s)
    _ => None
  }
}

///|
/// Integer value of `v`, if it is a whole number that fits an `Int32`.
///
/// A JSON number such as `0.5` or `2147483648` is not an integer. Truncating it
/// made a malformed tool-call index (`"index": 0.5`) merge into the call at
/// index 0, and a wrapped index move a fragment into an unrelated call, so
/// non-integral and out-of-range numbers are `None` here, never a cast.
pub fn as_int(v : Json) -> Int32? {
  match v {
    Json::Number(n, ..) =>
      if n.is_nan() || n.is_inf() || n != n.floor() {
        None
      } else if n > 2147483647.0 || n < -2147483648.0 {
        None
      } else {
        Some(n.to_int())
      }
    _ => None
  }
}

///|
/// Member `k` of `v` when `v` is an object.
pub fn field(v : Json, k : String) -> Json? {
  match v {
    Json::Object(m) => m.get(k)
    _ => None
  }
}

///|
/// Member `k` of `v` when `v` is an object, or `None`.
pub fn field_string(v : Json, k : String) -> String? {
  match field(v, k) {
    Some(x) => as_string(x)
    None => None
  }
}

///|
/// Member `k` of `v` as an integer, or `None`.
pub fn field_int(v : Json, k : String) -> Int32? {
  match field(v, k) {
    Some(x) => as_int(x)
    None => None
  }
}

///|
/// An event index field: absent is `None`, present but not a whole `Int32` is
/// `E060`.
///
/// The distinction matters: a missing index has a documented default (0), but a
/// malformed one must not silently become that default — that is how a fragment
/// of call `0.5` was appended to call 0 and a wrapped index merged two calls.
fn field_index(v : Json, k : String) -> Int32? raise @liwenjson.LIWENJSONError {
  match field(v, k) {
    None => None
    Some(x) =>
      match as_int(x) {
        Some(i) => Some(i)
        None =>
          raise @liwenjson.InvalidEvent(
            "an event index field must be a whole number in Int32 range",
          )
      }
  }
}
