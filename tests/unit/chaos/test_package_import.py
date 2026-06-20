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

"""Lightweight-import guard: ``devops_bench.chaos`` pulls no heavy chain.

CONVENTIONS §8 — importing the chaos package must not transitively load
provider SDKs, ``deepeval``, ``mcp``, or fortio tooling, **nor** the chaos
agent / models layer. Phase 4 makes this strict: the registry-driven parser
in :mod:`devops_bench.chaos.spec` lazy-loads the concrete fault/trigger
modules only on the first parse, and :meth:`GenerateLoadFault.inject`
lazy-imports :class:`ChaosAgent`.
"""

from __future__ import annotations

import subprocess
import sys


def test_import_pulls_no_heavy_sdks():
    # Fresh interpreter so other tests cannot pollute sys.modules.
    code = (
        "import sys\n"
        "import devops_bench.chaos  # noqa: F401\n"
        "loaded = set(sys.modules)\n"
        "for forbidden in ('deepeval', 'mcp', 'anthropic', 'google.genai', 'openai', 'ollama'):\n"
        "    assert forbidden not in loaded, forbidden\n"
        "print('ok')\n"
    )
    proc = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, timeout=30
    )
    assert proc.returncode == 0, proc.stderr
    assert "ok" in proc.stdout


def test_import_does_not_pull_chaos_agent_or_models_chain():
    # Phase 4 acceptance (B1 fix): importing the chaos package must NOT pull
    # ``chaos.agent`` (the LLM driver) or any ``models.*`` module, because the
    # only consumers of those — :meth:`Fault.inject` and the spec's concrete
    # union — are gated behind lazy imports now.
    code = (
        "import sys\n"
        "import devops_bench.chaos  # noqa: F401\n"
        "loaded = set(sys.modules)\n"
        "for forbidden in (\n"
        "    'devops_bench.chaos.agent',\n"
        "    'devops_bench.models',\n"
        "    'devops_bench.models.loop',\n"
        "    'devops_bench.models.base',\n"
        "):\n"
        "    assert forbidden not in loaded, forbidden\n"
        "# Importing the package also must NOT pre-load the concrete fault /\n"
        "# trigger modules: those load on the first ChaosSpec.model_validate(...)\n"
        "# call via the registry-driven parser.\n"
        "for forbidden in (\n"
        "    'devops_bench.chaos.faults.generate_load',\n"
        "    'devops_bench.chaos.triggers.time_delay',\n"
        "):\n"
        "    assert forbidden not in loaded, forbidden\n"
        "print('ok')\n"
    )
    proc = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, timeout=30
    )
    assert proc.returncode == 0, proc.stderr
    assert "ok" in proc.stdout


def test_parsing_a_spec_does_not_pull_the_agent_or_models_chain():
    # The stronger Phase-4 invariant: even after ``ChaosSpec.model_validate``
    # has loaded the concrete fault/trigger modules (and exercised the
    # registry-driven parser), the agent + models chain stays out of
    # ``sys.modules`` until a fault actually injects.
    code = (
        "import sys\n"
        "from devops_bench.chaos import ChaosSpec\n"
        "spec = ChaosSpec.model_validate({\n"
        "    'trigger': {'type': 'time', 'delay_seconds': 0},\n"
        "    'action': {\n"
        "        'type': 'generate_load',\n"
        "        'target': {'service_url': 'http://x', 'qps': 1},\n"
        "    },\n"
        "})\n"
        "loaded = set(sys.modules)\n"
        "for forbidden in (\n"
        "    'devops_bench.chaos.agent',\n"
        "    'devops_bench.models.loop',\n"
        "    'devops_bench.models.base',\n"
        "):\n"
        "    assert forbidden not in loaded, forbidden\n"
        "print('ok')\n"
    )
    proc = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, timeout=30
    )
    assert proc.returncode == 0, proc.stderr
    assert "ok" in proc.stdout


def test_chaos_init_exports_match_handoff():
    import devops_bench.chaos as chaos

    # Handoff §5.5: export only Fault, Trigger, ChaosResult, FAULTS, TRIGGERS,
    # ChaosSpec. ChaosAgent is NOT exported.
    assert set(chaos.__all__) == {
        "ChaosResult",
        "ChaosSpec",
        "FAULTS",
        "Fault",
        "TRIGGERS",
        "Trigger",
    }
    assert not hasattr(chaos, "ChaosAgent")
