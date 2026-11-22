"""The README quickstart is code: extract it and run it.

P2-04 (marks/1120优化.md §5): the example read `plan["text"]` after a default
`analyze()`, but `text` is only present with `with_text=True`, so copying the
quickstart raised `KeyError: 'text'`. A snippet that is not executed is a claim,
not an example; this test executes the first Python block against the real
engine and checks the value it says it produces.
"""

from __future__ import annotations

import ast
import re
import unittest
from pathlib import Path
from types import SimpleNamespace

from liwenjson import Client

README = Path(__file__).resolve().parents[1] / "README.md"
PYTHON_BLOCK = re.compile(r"```python\n(.*?)```", re.S)


class ReadmeQuickstartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = README.read_text(encoding="utf-8")
        blocks = PYTHON_BLOCK.findall(cls.source)
        if not blocks:
            raise AssertionError("the README has no ```python block to execute")
        cls.quickstart = blocks[0]

    def test_quickstart_runs_and_returns_the_documented_value(self) -> None:
        namespace: dict = {}
        exec(compile(self.quickstart, str(README), "exec"), namespace)  # noqa: S102
        self.assertEqual(namespace["args"], {"query": "MoonBit"})
        self.assertTrue(namespace["plan"]["executable"])

    def test_quickstart_does_not_read_text_without_opting_in(self) -> None:
        # The bug was a KeyError on the default plan; the snippet must not
        # mention plan["text"] unless it also passes with_text=True.
        self.assertNotIn('plan["text"]', self.quickstart)

    def test_readme_names_the_platform_contract(self) -> None:
        self.assertIn("## Platforms", self.source)
        self.assertIn("py3-none-any", self.source)
        self.assertIn("LIWENJSON_BIN", self.source)
        self.assertIn("Alpine/musl is not tested", self.source)
        self.assertIn("before the first call", self.source)
        for platform in ("Linux x86_64", "Linux arm64", "macOS arm64", "Windows x86_64"):
            self.assertIn(platform, self.source)

    def test_pyproject_does_not_claim_os_independence(self) -> None:
        # P2-05: the wheel tag is py3-none-any because it bundles four native
        # engines, not because the package runs anywhere. Saying
        # "Operating System :: OS Independent" contradicts the diagnosis a
        # user on an unsupported host gets before the first call.
        pyproject = (README.parent / "pyproject.toml").read_text(encoding="utf-8")
        self.assertNotIn("Operating System :: OS Independent", pyproject)
        for classifier in (
            "Operating System :: POSIX :: Linux",
            "Operating System :: MacOS :: MacOS X",
            "Operating System :: Microsoft :: Windows",
        ):
            self.assertIn(classifier, pyproject)

    def test_readme_version_matches_pyproject(self) -> None:
        pyproject = (README.parent / "pyproject.toml").read_text(encoding="utf-8")
        match = re.search(r'^version\s*=\s*"([^"]+)"', pyproject, re.M)
        assert match is not None
        self.assertIn(match.group(1), self.source)


class IntegrationExamplesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.path = README.parents[1] / "docs" / "INTEGRATIONS.md"
        cls.blocks = PYTHON_BLOCK.findall(cls.path.read_text(encoding="utf-8"))

    def test_execution_pattern_returns_values_and_stops_unsafe_retries(self) -> None:
        source = next(block for block in self.blocks if 'plan = jm.analyze(model_text' in block)
        wrapped = "def run():\n" + "".join("    " + line + "\n" for line in source.splitlines())
        with Client() as client:
            namespace = dict(jm=client, tool={"inputSchema": {"type": "object"}},
                             execute=lambda value: ("execute", value),
                             retry_with=lambda prompt: "retry", refuse=lambda prompt: "refuse")
            exec(compile(wrapped, str(self.path), "exec"), namespace)
            namespace["model_text"] = '{"a":1}'
            self.assertIsNone(namespace["run"]())
            namespace["model_text"] = '{"a":1'
            self.assertEqual(namespace["run"](), "retry")
            namespace["model_text"] = '{"a":1e400}'
            self.assertEqual(namespace["run"](), "refuse")

    def test_host_gate_example_executes_the_approved_value(self) -> None:
        source = next(block for block in self.blocks if "def gate(tool_name:" in block)
        captured = []
        namespace = dict(ToolArgumentsRefused=ValueError,
                         call=SimpleNamespace(name="f", arguments_text='{"a":1}'),
                         TOOLS={"f": {"inputSchema": {"type": "object"}}},
                         execute=lambda name, value: captured.append((name, value)))
        try:
            exec(compile(source, str(self.path), "exec"), namespace)
            self.assertEqual(captured, [("f", {"a": 1})])
            with self.assertRaises(ValueError):
                namespace["gate"]("f", '{"a":1', namespace["TOOLS"]["f"])
        finally:
            if "GATE" in namespace:
                namespace["GATE"].close()

    def test_output_parser_body_returns_the_value_without_requiring_text(self) -> None:
        source = next(block for block in self.blocks if "class LIWENJSONParser" in block)
        method = next(node for node in ast.walk(ast.parse(source))
                      if isinstance(node, ast.FunctionDef) and node.name == "parse")
        namespace = {}
        exec(compile(ast.Module(body=[method], type_ignores=[]), str(self.path), "exec"), namespace)
        with Client() as client:
            parser = SimpleNamespace(_jm=client, _schema={"type": "object"})
            self.assertEqual(namespace["parse"](parser, '{"a":1}'), {"a": 1})
            with self.assertRaises(ValueError):
                namespace["parse"](parser, '{"a":1')


if __name__ == "__main__":
    unittest.main()
