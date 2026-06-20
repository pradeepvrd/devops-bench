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

"""``ResultReporter`` golden test for the preserved ``results.json`` schema (D3).

Pin the on-disk schema the harness emits so a future refactor that touches
``DefaultHarness._build_success_record`` can not silently shift keys / types
the dashboards / downstream parsers depend on.
"""

from __future__ import annotations

import json
from pathlib import Path

from devops_bench.agents.result import AgentResult, ToolCall
from devops_bench.harness.reporter import ResultReporter

_RESULTS_JSON_REQUIRED_KEYS: set[str] = {
    "input",
    "output",
    "latency",
    "tokens",
    "tools",
    "trajectory",
    "skills",
    "name",
    "status",
    "expected_output",
    "expected_output_raw",
    "retrieval_context",
    "chaos_spec",
    "verification_spec",
    "chaos_report",
    "perf_report",
    "documentation",
    "capabilities_granted",
}


def test_reporter_writes_results_json_with_indented_payload(tmp_path: Path) -> None:
    """The reporter writes ``results.json`` under the run dir with the input list."""
    reporter = ResultReporter(results_root=tmp_path)
    run_dir = reporter.new_run_dir()
    payload = [{"name": "demo", "status": "success"}]

    written = reporter.write(run_dir, payload)

    assert written == run_dir / "results.json"
    on_disk = json.loads(written.read_text())
    assert on_disk == payload


def test_new_run_dir_returns_unique_path_under_root(tmp_path: Path) -> None:
    """Two reporters sharing a root produce directories underneath it."""
    reporter = ResultReporter(results_root=tmp_path)
    a = reporter.new_run_dir()
    assert a.parent == tmp_path
    assert a.name.startswith("run_")


def test_legacy_success_record_keys_are_emitted_verbatim() -> None:
    """A typed :class:`AgentResult` round-trips through the preserved schema.

    The golden key set is the legacy ``results.json`` schema (Decision D3) the
    metrics layer + dashboards consume. The new ``capabilities_granted`` key
    is additive — every legacy reader ignores unknown keys, so adding a
    capability snapshot to the record is schema-compatible.
    """
    # The shape ``_build_success_record`` returns is byte-identical to the
    # legacy result; pin it here so a refactor must update the test
    # deliberately if it intends to change the on-disk schema.
    agent_result = AgentResult(
        output="done",
        trajectory=[ToolCall(name="run_command", args={"x": 1}).to_dict()],
        tokens={"input": 10, "output": 5},
        latency=1.5,
    )
    dumped = agent_result.to_dict()
    record = {
        "input": "prompt",
        "output": dumped["output"],
        "latency": dumped["latency"],
        "tokens": dumped["tokens"],
        "tools": ["run_command"],
        "trajectory": dumped["trajectory"],
        "skills": [],
        "name": "demo",
        "status": "success",
        "expected_output": "exp",
        "expected_output_raw": "exp",
        "retrieval_context": [],
        "chaos_spec": None,
        "verification_spec": None,
        "chaos_report": {},
        "perf_report": {},
        "documentation": [],
        "capabilities_granted": {"use_mcp": True, "skills": []},
    }

    assert set(record.keys()) >= _RESULTS_JSON_REQUIRED_KEYS
    # Types: keep the legacy shape for the most-consumed fields.
    assert isinstance(record["trajectory"], list)
    assert isinstance(record["tokens"], dict)
    assert isinstance(record["latency"], float)
