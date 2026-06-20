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

"""Lightweight-import guard: ``devops_bench.chaos`` pulls no heavy SDKs.

CONVENTIONS §8 — importing the chaos package must not transitively load
provider SDKs, ``deepeval``, ``mcp``, or fortio tooling. Concretes register
lazily; provider SDKs are loaded only when ``ChaosAgent`` constructs a client.
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
