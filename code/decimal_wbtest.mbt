// Exact decimal numbers (`decimal.mbt`), the arithmetic the numeric constraints
// stand on. The cases that matter are the ones a `Double` gets wrong: two
// different integers that collapse onto one double, and the spellings of the
// same number (`1`, `1.0`, `1e0`) that must compare equal.

///|
/// `Dec::parse`, or a zero when the text is not a number.
fn dec(text : String) -> Dec {
  match Dec::parse(text) {
    Some(d) => d
    None => { negative: false, digits: "0", exp: 0, }
  }
}

///|
test "TC-DEC-01: the same number in three spellings is one Dec" {
  for text in ["1", "1.0", "1e0", "10e-1", "0.1e1"] {
    assert_eq(dec(text).text(), "1", msg=text)
    assert_eq(dec(text).compare(dec("1")), 0, msg=text)
  }
  for text in ["100", "1e2", "10e1", "100.0"] {
    assert_eq(dec(text).text(), "100", msg=text)
  }
  for text in ["0", "-0", "0.0", "0e5", "-0e-5"] {
    assert_eq(dec(text).is_zero(), true, msg=text)
    assert_eq(dec(text).text(), "0", msg=text)
  }
}

///|
test "TC-DEC-02: a text that is not a number is not a Dec" {
  for
    text in [
      "", "-", "+", ".", "e5", "1e", "1e+", "1.2.3", "1-2", "--1", "0x10", "1 ",
      " 1", "NaN", "Infinity", "1_000",
    ] {
    assert_true(Dec::parse(text) is None, msg=text)
  }
}

///|
test "TC-DEC-03: two integers past 2^53 compare by their digits" {
  let a = dec("9007199254740992")
  let b = dec("9007199254740993")
  assert_eq(a.compare(b), -1)
  assert_eq(b.compare(a), 1)
  assert_eq(a.compare(a), 0)
  // A longer integer is larger, whatever the doubles say.
  assert_eq(dec("12345678901234567890123456789").compare(a), 1)
  // Sign decides before magnitude.
  assert_eq(dec("-9007199254740993").compare(a), -1)
  assert_eq(dec("-1").compare(dec("1")), -1)
}

///|
test "TC-DEC-04: fractions and exponents compare exactly" {
  assert_eq(dec("0.1").compare(dec("0.1")), 0)
  assert_eq(dec("0.1").compare(dec("0.10000000000000001")), -1)
  assert_eq(dec("-0.0015").compare(dec("-1.5e-3")), 0)
  assert_eq(dec("1e-7").compare(dec("0.0000001")), 0)
  assert_eq(dec("1e400").compare(dec("1e401")), -1)
  assert_eq(dec("-1e400").compare(dec("1e400")), -1)
}

///|
test "TC-DEC-05: the text form is canonical and re-parses" {
  assert_eq(dec("1.50").text(), "1.5")
  assert_eq(dec("-0.015").text(), "-0.015")
  assert_eq(dec("1e3").text(), "1000")
  assert_eq(dec("1.5e-2").text(), "0.015")
  // A large exponent stays short instead of printing hundreds of zeros.
  assert_eq(dec("1e400").text(), "1e400")
  assert_eq(dec("1e-400").text(), "1e-400")
  // And the canonical text is a fixed point.
  for text in ["1.5", "1000", "0.015", "1e400", "-1e-400", "0"] {
    assert_eq(dec(dec(text).text()).text(), dec(text).text(), msg=text)
  }
}

///|
test "TC-DEC-06: integer-ness is exact" {
  for text in ["0", "1", "-1", "2147483648", "9007199254740993", "1.0", "1e3"] {
    assert_eq(dec(text).is_integer(), true, msg=text)
  }
  for text in ["1.5", "1e-1", "0.999999", "-0.5"] {
    assert_eq(dec(text).is_integer(), false, msg=text)
  }
}

///|
test "TC-DEC-07: a length bound is a non-negative Int32 or nothing" {
  assert_eq(dec("0").length_value(), Some(0))
  assert_eq(dec("64").length_value(), Some(64))
  assert_eq(dec("2147483647").length_value(), Some(2147483647))
  // Out of range, negative, or not an integer: no length.
  assert_eq(dec("2147483648").length_value() is None, true)
  assert_eq(dec("1e10").length_value() is None, true)
  assert_eq(dec("-1").length_value() is None, true)
  assert_eq(dec("1.5").length_value() is None, true)
}

///|
test "TC-DEC-08: a JSON number's exact value uses its source text" {
  // The engine keeps the text when the double cannot reproduce it.
  let v = @json.parse("9007199254740993", preserve_number_repr=true) catch {
    _ => Json::null()
  }
  assert_eq(number_dec(v).unwrap().text(), "9007199254740993")
  // A number with no text at all falls back to the shortest round-trip form,
  // which orders the same way the double does.
  assert_eq(number_dec(Json::number(1.5)).unwrap().text(), "1.5")
  assert_eq(number_dec(Json::number(0.1)).unwrap().text(), "0.1")
  // A non-number has no decimal value.
  assert_true(number_dec(Json::string("1")) is None)
}
