"""The README quickstart is code: extract it and run it.

P2-04 (marks/1120优化.md §5): the example read `plan["text"]` after a default
`analyze()`, but `text` is only present with `with_text=True`, so copying the
quickstart raised `KeyError: 'text'`. A snippet that is not executed is a claim,
not an example; this test executes the first Python block against the real
engine and checks the value it says it produces.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
