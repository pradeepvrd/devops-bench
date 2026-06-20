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

"""Lightweight-import guard: ``devops_bench.metrics`` pulls no heavy SDKs.

The metrics package keeps a lazy ``__getattr__`` facade and imports its builtin
metric modules at call time (CONVENTIONS.md §8) so ``import devops_bench.metrics``
never eagerly pulls ``deepeval`` or any provider SDK.
"""

from __future__ import annotations

import subprocess
import sys


def test_import_pulls_no_heavy_sdks():
    # Run in a fresh interpreter so other tests cannot pollute sys.modules.
    code = (
        "import sys\n"
        "import devops_bench.metrics  # noqa: F401\n"
        "loaded = set(sys.modules)\n"
        "for forbidden in ('deepeval', 'mcp', 'anthropic', 'google.genai', 'openai'):\n"
        "    assert forbidden not in loaded, forbidden\n"
        "# The registry primitives are eagerly exposed from base.py (no SDK),\n"
        "# so this still resolves without triggering a lazy import.\n"
        "assert hasattr(devops_bench.metrics, 'METRICS')\n"
        "assert hasattr(devops_bench.metrics, 'MetricScore')\n"
        "print('ok')\n"
    )
    proc = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, timeout=30
    )
    assert proc.returncode == 0, proc.stderr
    assert "ok" in proc.stdout
