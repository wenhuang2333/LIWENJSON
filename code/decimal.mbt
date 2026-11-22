// Exact decimal numbers for value constraints.
//
// JSON numbers are decimal text; a `Double` is not. `9007199254740993` and
// `9007199254740992` are different numbers that become the same `Double`, so a
// constraint compared in `Double` space allows a value it should refuse --
// which, on an execution gate, is the wrong direction to be wrong in. The
// engine already keeps the source text of a number (`Json::Number(_, repr~)`),
// so the exact value is available; this file is the comparison over it.
//
// A `Dec` is a normalised decimal: `value = (-1)^negative * digits * 10^exp`,
// `digits` without leading or trailing zeros (a zero is `"0"` with `exp = 0`).
// Two texts that denote the same number therefore normalise to the same triple:
// `1`, `1.0` and `1e0` are one `Dec`, and so are `100` and `1e2`.
//
// A text whose exponent cannot be normalised into `Int32` (a hand-written
// `1e9999999999`) is not represented at all: `Dec::parse` returns `None`.
// Callers must fail closed rather than substitute a rounded or underflowed
// `Double` for a source text they could not understand exactly.

///|
/// An exact decimal number, normalised (see the file header).
pub(all) struct Dec {
  negative : Bool
  /// Significant digits, no leading or trailing zero; `"0"` for zero.
  digits : String
  /// Power of ten applied to `digits`.
  exp : Int32
}

///|
/// Explicit `Eq` implementation for `Dec` (exact value, not spelling).
pub impl Eq for Dec with fn equal(self : Dec, other : Dec) -> Bool {
  self.compare(other) == 0
}

///|
/// Explicit `Eq` extension for `Dec`.
pub extend Dec with Eq::{not_equal, equal}

///|
/// The normalised form of a decimal number text, or `None` when the text is not
/// a decimal number this library can normalise exactly.
///
/// The grammar is JSON's own (`-`?int`(`.`frac)?(`e`exp)?). A leading `+` is
/// accepted because the skeleton's constraint parser feeds it tokens from a
/// hand-written declaration, where `+1` is a plausible spelling; the JSON
/// reader never produces one.
pub fn Dec::parse(text : String) -> Dec? {
  match decimal_key(text) {
    Some((negative, digits, exp)) => Some({ negative, digits, exp, })
    None => None
  }
}

///|
/// The exact value of a JSON number, using the source text when the engine kept
/// it and the shortest round-trip spelling of the `Double` otherwise.
///
/// The shortest round-trip spelling has the same ordering as the `Double` it
/// names (the intervals do not overlap), so a comparison over it agrees with a
/// `Double` comparison whenever the text is the only thing there is.
pub fn Dec::of_number(d : Double, repr : String?) -> Dec? {
  match repr {
    Some(text) => Dec::parse(text)
    None => Dec::parse(d.to_string())
  }
}

///|
/// The canonical text of a `Dec`: plain decimal when that stays short, the
/// scientific form otherwise, so a constraint on `1e400` does not print four
/// hundred zeros into a retry prompt.
pub fn Dec::text(self : Dec) -> String {
  let sb = StringBuilder()
  if self.negative && self.digits != "0" {
    sb.write_char('-')
  }
  let len = self.digits.length()
  if self.digits == "0" {
    sb.write_string("0")
    return sb.to_string()
  }
  // The position of the decimal point inside `digits`: `len + exp` digits come
  // before it. `1.5` is `digits="15"`, `exp=-1`, so one digit is before the
  // point; `0.015` is `digits="15"`, `exp=-3`, so the point is before both.
  let point = len.to_int64() + self.exp.to_int64()
  if self.exp >= 0 && point <= 21 {
    sb.write_string(self.digits)
    for i = 0; i < self.exp; i = i + 1 {
      sb.write_char('0')
    }
  } else if self.exp < 0 && point > 0 && len <= 21 {
    sb.write_string(self.digits[:point.to_int()].to_owned())
    sb.write_char('.')
    sb.write_string(self.digits[point.to_int():].to_owned())
  } else if self.exp < 0 && point <= 0 && -point <= 21 && len <= 21 {
    sb.write_string("0.")
    for i = 0L; i < -point; i = i + 1L {
      sb.write_char('0')
    }
    sb.write_string(self.digits)
  } else {
    // Scientific: one digit, an optional fraction, and the exponent of the
    // leading digit.
    sb.write_char(Int32::unsafe_to_char(self.digits.at(0).to_int()))
    if len > 1 {
      sb.write_char('.')
      sb.write_string(self.digits[1:].to_owned())
    }
    sb.write_char('e')
    sb.write_string((point - 1L).to_string())
  }
  sb.to_string()
}

///|
/// Whether the value is a whole number (`2147483648` is, `1.5` is not).
pub fn Dec::is_integer(self : Dec) -> Bool {
  self.digits == "0" || self.exp >= 0
}

///|
/// Whether the value is zero.
pub fn Dec::is_zero(self : Dec) -> Bool {
  self.digits == "0"
}

///|
/// Decimal comparison: -1, 0 or 1 for `self` below, equal to, above `other`.
///
/// Exact, and never through a `Double`: the whole point of the type is that
/// `9007199254740993 > 9007199254740992` is decidable.
pub fn Dec::compare(self : Dec, other : Dec) -> Int32 {
  if self.is_zero() && other.is_zero() {
    return 0
  }
  if self.negative != other.negative {
    return if self.negative { -1 } else { 1 }
  }
  let mag = self.magnitude_compare(other)
  if self.negative {
    -mag
  } else {
    mag
  }
}

///|
/// Comparison of the magnitudes, both already known to have the same sign.
fn Dec::magnitude_compare(self : Dec, other : Dec) -> Int32 {
  if self.is_zero() {
    return if other.is_zero() { 0 } else { -1 }
  }
  if other.is_zero() {
    return 1
  }
  // The position of the decimal point relative to the significant digits:
  // `digits.length + exp` is the number of integer digits. Comparing that first
  // is comparing the exponent of a scientific notation.
  let a = self.digits.length().to_int64() + self.exp.to_int64()
  let b = other.digits.length().to_int64() + other.exp.to_int64()
  if a != b {
    return if a < b { -1 } else { 1 }
  }
  let n = if self.digits.length() > other.digits.length() {
    self.digits.length()
  } else {
    other.digits.length()
  }
  for i = 0; i < n; i = i + 1 {
    let x = if i < self.digits.length() {
      self.digits.at(i).to_int()
    } else {
      0x30
    }
    let y = if i < other.digits.length() {
      other.digits.at(i).to_int()
    } else {
      0x30
    }
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  0
}

///|
/// The exact value of a JSON number as a `Dec`.
pub fn number_dec(v : Json) -> Dec? {
  match v {
    Json::Number(d, repr~) => Dec::of_number(d, repr)
    _ => None
  }
}

///|
/// The value as a non-negative `Int32` when it is exactly representable as one,
/// or `None`. Used for `minLength`/`maxLength`, where `-1`, `1.5` and `1e10`
/// are all declaration errors rather than rules that never fire.
pub fn Dec::length_value(self : Dec) -> Int32? {
  if self.negative || !self.is_integer() {
    return None
  }
  // Accumulate in `Int64` over the digits followed by `exp` zeros; anything
  // above `2147483647` is refused, which is the same ceiling `Int32` has.
  let mut acc : Int64 = 0L
  let n = self.digits.length()
  for i = 0; i < n; i = i + 1 {
    acc = acc * 10L + (self.digits.at(i).to_int() - 0x30).to_int64()
    if acc > 2147483647L {
      return None
    }
  }
  for i = 0; i < self.exp; i = i + 1 {
    acc = acc * 10L
    if acc > 2147483647L {
      return None
    }
  }
  Some(acc.to_int())
}

///|
/// The number of Unicode code points in `s`.
///
/// `String::length` counts UTF-16 code units, which is not what JSON Schema's
/// `minLength`/`maxLength` mean: a non-BMP character is two units and one
/// character. Iterating the string yields code points, so this is a plain
/// count.
pub fn code_points(s : String) -> Int32 {
  let mut n = 0
  for _c in s {
    n = n + 1
  }
  n
}
