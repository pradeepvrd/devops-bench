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

"""Regression: the REAL ``optimize-scale`` chaos entry parses through ChaosSpec.

The Phase-B migrated ``chaos_spec`` field in
``complextasks/optimize-scale/task.yaml`` is now authored as native YAML rather
than a JSON-in-YAML string (Decision D2: field names kept, only values
migrated). After placeholder substitution it must validate through the typed
:class:`ChaosSpec` and discriminate to
:class:`GenerateLoadFault` / :class:`TimeTrigger` with the documented
``target.service_url`` / ``qps`` / ``delay_seconds`` values.

This is the gap CONVENTIONS §9 locks for every component — without it the
typed nodes can drift away from the only real spec in the repo.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from devops_bench.chaos import ChaosSpec
from devops_bench.chaos.faults.generate_load import GenerateLoadFault
from devops_bench.chaos.triggers.time_delay import TimeTrigger

_REPO_ROOT = Path(__file__).resolve().parents[3]
_TASK_YAML = _REPO_ROOT / "complextasks" / "optimize-scale" / "task.yaml"


def _resolve_placeholders(value):
    """Substitute the task-file placeholders the harness fills in at run time.

    Walks the native-YAML structure once so ``{{...}}`` placeholders in nested
    string values (e.g. the load target's ``service_url``) get rewritten just
    like the harness does at run time.
    """
    if isinstance(value, str):
        return value.replace("{{TARGET_DEPLOYMENT_NAME}}", "web-app").replace(
            "{{NAMESPACE}}", "default"
        )
    if isinstance(value, list):
        return [_resolve_placeholders(item) for item in value]
    if isinstance(value, dict):
        return {key: _resolve_placeholders(val) for key, val in value.items()}
    return value


def _load_chaos_entry() -> dict:
    raw = yaml.safe_load(_TASK_YAML.read_text())
    entries = _resolve_placeholders(raw["chaos_spec"])
    assert isinstance(entries, list) and len(entries) == 1
    return entries[0]


def test_real_optimize_scale_chaos_entry_is_native_yaml():
    """The migrated chaos_spec is a native YAML list, not a JSON-in-YAML string."""
    raw = yaml.safe_load(_TASK_YAML.read_text())
    # Native YAML migration (Decision D2): the value is now a list of mappings,
    # not a JSON-in-YAML string, so authors edit one shape.
    assert isinstance(raw["chaos_spec"], list)


def test_real_optimize_scale_chaos_entry_parses_through_chaos_spec():
    entry = _load_chaos_entry()

    spec = ChaosSpec.model_validate(entry)

    assert spec.name == "Planned Load Spike"
    # Trigger discriminates to the time-delay node and carries the authored delay.
    assert isinstance(spec.trigger, TimeTrigger)
    assert spec.trigger.type == "time"
    assert spec.trigger.delay_seconds == 5
    # Action discriminates to the generate-load fault with the rewritten URL,
    # qps from the task spec, and no spurious defaults overriding it.
    assert isinstance(spec.action, GenerateLoadFault)
    assert spec.action.type == "generate_load"
    assert (
        spec.action.target.service_url
        == "http://web-app.default.svc.cluster.local"
    )
    assert spec.action.target.qps == 300
    # The legacy ``verification`` alias resolves into the canonical ``verify``
    # reference field — chaos never imports a verification node.
    assert spec.verify == "Planned Load Spike Verification"
