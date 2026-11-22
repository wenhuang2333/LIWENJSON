"""Client tests. Run from `code/python`: `python -m unittest discover -s tests`."""

from __future__ import annotations

import json
import unittest

from liwenjson import Client, LIWENJSONError, find_binary
from version import engine_version, registry_version



class ClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = find_binary()

    def setUp(self) -> None:
        self.client = Client(binary=self.binary, timeout=10)

    def tearDown(self) -> None:
        self.client.close()

    def test_package_version_matches_the_engine_version(self) -> None:
        # The package declares its version; the declaration must be the engine
        # version. A literal here went stale once (1.1.0 while the package was
        # 1.1.1), so the check reads the declaration instead of pinning one.
        import liwenjson

        self.assertEqual(liwenjson.__version__, engine_version())

    def test_hello_reports_both_version_channels(self) -> None:
        hello = self.client.hello()
        self.assertEqual(hello["name"], "liwenjson")
        self.assertEqual(hello["engine"], engine_version())
        self.assertEqual(hello["registry"], registry_version())
        self.assertEqual(hello["protocol"], 1)
        self.assertIn("analyze", hello["capabilities"])

    def test_repair(self) -> None:
        result = self.client.repair("{'a':1,}")
        self.assertEqual(result["text"], '{"a":1}')
        self.assertEqual(result["exactness"], "cosmetic")
        self.assertIn("R005", [r["rule"] for r in result["repairs"]])

    def test_analyze_blocks_an_ambiguous_repair(self) -> None:
        plan = self.client.analyze('{"words":["a" "b"]}', profile="execution")
        self.assertEqual(plan["decision"], "ambiguous")
        self.assertFalse(plan["executable"])
        self.assertEqual(plan["error"]["code"], "E011")
        self.assertIn("Re-emit", plan["retry"]["prompt"])

    def test_analyze_accepts_a_json_schema_subset(self) -> None:
        plan = self.client.analyze(
            '{"query":"x","limit":0}',
            profile="agent",
            schema_json={
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1},
                },
                "required": ["query", "limit"],
            },
        )
        self.assertFalse(plan["executable"])
        self.assertEqual(plan["schema_total"], 2)
        self.assertEqual(plan["schema_satisfied"], 1)

    def test_unsupported_schema_keyword_is_an_error(self) -> None:
        with self.assertRaises(LIWENJSONError) as caught:
            self.client.analyze("{}", schema_json={"$ref": "#/x"})
        self.assertEqual(caught.exception.code, "E070")
        self.assertIn("$ref", caught.exception.message)


    def test_const_and_enum_are_conjunctive_whatever_the_field_order(self) -> None:
        """The audit's headline reproducer, through the Python wrapper."""
        orders = [
            {
                "type": "object",
                "properties": {
                    "mode": {
                        "type": "string",
                        "const": "read",
                        "enum": ["read", "write"],
                    }
                },
                "required": ["mode"],
            },
            {
                "type": "object",
                "properties": {
                    "mode": {
                        "type": "string",
                        "enum": ["read", "write"],
                        "const": "read",
                    }
                },
                "required": ["mode"],
            },
        ]
        for schema_json in orders:
            self.assertFalse(
                self.client.analyze('{"mode":"write"}', schema_json=schema_json)[
                    "executable"
                ]
            )
            self.assertTrue(
                self.client.analyze('{"mode":"read"}', schema_json=schema_json)[
                    "executable"
                ]
            )

    def test_a_container_constraint_does_not_skip_the_shape_inside_it(self) -> None:
        schema_json = {
            "type": "object",
            "properties": {
                "items": {
                    "type": "array",
                    "enum": [[1], ["bad"]],
                    "items": {"type": "integer"},
                }
            },
            "required": ["items"],
        }
        self.assertFalse(
            self.client.analyze('{"items":["bad"]}', schema_json=schema_json)[
                "executable"
            ]
        )
        self.assertTrue(
            self.client.analyze('{"items":[1]}', schema_json=schema_json)["executable"]
        )

    def test_repair_honours_the_declaration_it_is_given(self) -> None:
        with self.assertRaises(LIWENJSONError) as caught:
            self.client.repair(
                '{"mode":"write"}',
                schema_json={
                    "type": "object",
                    "properties": {"mode": {"type": "string", "const": "read"}},
                    "required": ["mode"],
                },
            )
        self.assertEqual(caught.exception.code, "E070")

    def test_validate(self) -> None:
        self.assertTrue(self.client.validate('{"a":1}')["valid"])
        bad = self.client.validate("{a:1,}")
        self.assertFalse(bad["valid"])
        self.assertEqual(bad["error"]["code"], "E010")
        self.assertEqual(bad["repaired"], '{"a":1}')

    def test_readiness(self) -> None:
        ready = self.client.readiness(
            '{"query":"x","limit":10}', schema="{!query:string,!limit:integer}"
        )
        self.assertEqual(ready["syntax_permille"], 1000)
        self.assertEqual(ready["schema_permille"], 1000)
        self.assertTrue(ready["verdict"]["ok"])

    def test_watch(self) -> None:
        self.client.watch_start(schema="{!a:string}")
        first = self.client.watch_feed('{"a":"x"}')
        kinds = [event["kind"] for event in first["events"]]
        self.assertIn("field_ready", kinds)
        self.assertIn("root_ready", kinds)
        final = self.client.watch_finish()
        self.assertEqual(final["final"]["value"], {"a": "x"})

    def test_llm_stream(self) -> None:
        self.client.llm_open("anthropic")
        events = [
            '{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"get_weather","input":{}}}',
            '{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"location\\":\\"Paris\\"}"}}',
            '{"type":"content_block_stop","index":0}',
        ]
        for event in events:
            self.client.llm_feed(event)
        closed = self.client.llm_close()
        self.assertEqual(closed["calls"][0]["name"], "get_weather")
        self.assertEqual(closed["calls"][0]["value"], {"location": "Paris"})
        self.assertEqual(closed["calls"][0]["end"], "complete")

    def test_host_number_conversion_refuses_changed_execution_values(self) -> None:
        for number in ("0.99999999999999999999", "1.00000000000000000001", "1e400", "1e-400", "-1e-400"):
            for text in (number, '{"amount":' + number + '}'):
                with self.subTest(text=text):
                    plan = self.client.analyze(text, profile="agent", with_text=True)
                    self.assertFalse(plan["executable"])
                    self.assertEqual(plan["error"]["code"], "E070")
                    self.assertFalse(plan["refusal"]["auto_retry"])
                    self.assertIsNone(plan["value"])
                    self.assertEqual(plan["text"], text)
                    self.assertEqual(self.client.repair(text)["text"], text)
        self.assertEqual(self.client.hello()["name"], "liwenjson")

    def test_host_number_conversion_preserves_representable_values_and_big_integers(self) -> None:
        for text, value in (("0.1", 0.1), ("1.0", 1.0), ("1e3", 1000.0), ("9007199254740993", 9007199254740993)):
            with self.subTest(text=text):
                plan = self.client.analyze(text, profile="agent")
                self.assertTrue(plan["executable"])
                self.assertEqual(plan["value"], value)
                self.assertIn(type(plan["value"]), (int, float))
                json.dumps(plan, allow_nan=False)

    def test_host_number_conversion_guards_refused_and_streaming_values(self) -> None:
        for number in ("1e400", "1e-400", "0.99999999999999999999"):
            with self.subTest(number=number):
                plan = self.client.analyze('{"amount":' + number + ',"words":["a" "b"]}', profile="permissive")
                self.assertFalse(plan["executable"])
                self.assertIsNone(plan["value"])
                self.assertFalse(plan["refusal"]["auto_retry"])
                json.dumps(plan, allow_nan=False)
                self.client.watch_start(schema="{!amount:number}")
                for request in (
                    lambda: self.client.watch_feed('{"amount":' + number + '}'),
                    self.client.watch_finish,
                ):
                    with self.assertRaises(LIWENJSONError) as caught:
                        request()
                    self.assertEqual(caught.exception.code, "E070")
        self.assertEqual(self.client.hello()["name"], "liwenjson")

    def test_host_number_conversion_guards_nested_llm_call_values(self) -> None:
        for executable in ("true", "false"):
            for number in ("1e400", "1e-400", "0.99999999999999999999"):
                with self.subTest(executable=executable, number=number):
                    frame = self.client._classify(
                        '{"id":1,"ok":true,"result":{"calls":[{"executable":' + executable
                        + ',"value":{"amount":' + number + '}}]}}'
                    )
                    call = frame.payload["result"]["calls"][0]
                    self.assertFalse(call["executable"])
                    self.assertIsNone(call["value"])
                    self.assertFalse(call["refusal"]["auto_retry"])
                    json.dumps(frame.payload, allow_nan=False)
        json.dumps(frame.payload, allow_nan=False)

    def test_unknown_profile_is_rejected(self) -> None:
        with self.assertRaises(LIWENJSONError) as caught:
            self.client.analyze("{}", profile="nope")
        self.assertEqual(caught.exception.code, "E050")


if __name__ == "__main__":
    unittest.main()


class DiagnosticsTests(unittest.TestCase):
    """The error path has to explain itself."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = find_binary()

    def test_stderr_is_captured_by_default(self) -> None:
        # It defaulted to DEVNULL, so every "the engine died" message ended
        # with an empty stderr and no way to find out why.
        import subprocess

        client = Client(binary=self.binary, timeout=10)
        try:
            self.assertIs(
                client.proc.stderr is not None,
                True,
                msg="stderr must be a pipe by default",
            )
        finally:
            client.close()

    def test_a_timeout_does_not_desynchronise_the_client(self) -> None:
        # A late answer used to stay in the queue, so the *next* request read
        # it and either reported an id mismatch or, worse, accepted it.
        client = Client(binary=self.binary, timeout=30)
        try:
            # A zero timeout makes the first request fail immediately.
            client.timeout = 0.0
            with self.assertRaises(TimeoutError):
                client.hello()
            # The stream is resynchronised, so a normal request still works.
            client.timeout = 10.0
            hello = client.hello()
            self.assertEqual(hello["name"], "liwenjson")
        finally:
            client.close()

    def test_a_refusal_carries_its_code(self) -> None:
        client = Client(binary=self.binary, timeout=10)
        try:
            with self.assertRaises(LIWENJSONError) as caught:
                client.repair('{"a":1,}', profile="strict")
            self.assertEqual(caught.exception.code, "E010")
        finally:
            client.close()
