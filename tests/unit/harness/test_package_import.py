# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""``import devops_bench.harness`` stays light (CONVENTIONS.md §8).

The orchestrator is the only layer allowed to consume every component, so it
sits structurally close to the heavy optional dependencies (``deepeval``,
provider SDKs, ``mcp``). Importing the package must still not pull any of
them: the metrics judge is imported lazily inside ``DefaultHarness._score``,
the API agent's SDK loads at construction, and the chaos fault's fortio /
provider modules load only when the fault actually injects.
"""

from __future__ import annotations

import importlib
import subprocess
import sys
import textwrap


def _run_in_subprocess(snippet: str) -> str:
    """Run ``snippet`` in a clean Python process and return stdout.

    A fresh interpreter prevents leaks from earlier test imports (the wider
    test session has often already pulled ``deepeval``).
    """
    result = subprocess.run(
        [sys.executable, "-c", textwrap.dedent(snippet)],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


def test_importing_harness_pulls_no_sdk_or_concrete() -> None:
    """A bare ``import devops_bench.harness`` does not pull heavy modules."""
    output = _run_in_subprocess(
        """
        import sys
        import devops_bench.harness  # noqa: F401
        forbidden = {
            "deepeval",
            "mcp",
            "anthropic",
            "google.genai",
            "openai",
            "ollama",
        }
        leaked = sorted(name for name in forbidden if name in sys.modules)
        print(",".join(leaked))
        """
    )
    leaked = [name for name in output.strip().split(",") if name]
    assert leaked == [], f"importing devops_bench.harness pulled: {leaked}"


def test_harness_facade_exports_present() -> None:
    """The lazy facade resolves :class:`DefaultHarness` and :class:`ScenarioManager`."""
    pkg = importlib.import_module("devops_bench.harness")
    # ``Harness`` and ``ResultReporter`` are eagerly imported (light deps).
    assert pkg.Harness.__name__ == "Harness"
    assert pkg.ResultReporter.__name__ == "ResultReporter"
    # ``DefaultHarness`` / ``ScenarioManager`` flow through ``__getattr__``.
    assert pkg.DefaultHarness.__name__ == "DefaultHarness"
    assert pkg.ScenarioManager.__name__ == "ScenarioManager"
