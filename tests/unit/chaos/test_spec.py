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

"""Unit tests for the discriminated-union chaos spec."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from devops_bench.chaos import FAULTS, TRIGGERS, ChaosSpec
from devops_bench.chaos.faults.generate_load import GenerateLoadFault, LoadTarget
from devops_bench.chaos.schema import json_schema, validate_spec
from devops_bench.chaos.triggers.time_delay import TimeTrigger


def test_minimal_chaos_spec_parses_and_discriminates():
    spec = ChaosSpec.model_validate(
        {
            "trigger": {"type": "time", "delay_seconds": 3},
            "action": {
                "type": "generate_load",
                "target": {"service_url": "http://web", "qps": 50},
            },
        }
    )

    assert spec.name == "Planned Disruption"
    assert isinstance(spec.trigger, TimeTrigger)
    assert spec.trigger.delay_seconds == 3
    assert isinstance(spec.action, GenerateLoadFault)
    assert spec.action.target.service_url == "http://web"
    assert spec.action.target.qps == 50
    assert spec.verify is None


def test_chaos_spec_with_name_and_verify_reference():
    spec = ChaosSpec.model_validate(
        {
            "name": "spike",
            "trigger": {"type": "time", "delay_seconds": 0},
            "action": {
                "type": "generate_load",
                "target": {"service_url": "http://svc", "qps": 1},
            },
            "verify": "post_spike_check",
        }
    )

    assert spec.name == "spike"
    assert spec.verify == "post_spike_check"


def test_legacy_verification_alias_is_accepted():
    # The real ``optimize-scale/task.yaml`` ships ``verification`` (not
    # ``verify``); the spec accepts both so Phase A lands without touching
    # task files. Phase B will migrate the on-disk shape.
    spec = ChaosSpec.model_validate(
        {
            "trigger": {"type": "time", "delay_seconds": 5},
            "action": {
                "type": "generate_load",
                "target": {"service_url": "http://svc", "qps": 1},
            },
            "verification": "Planned Load Spike Verification",
        }
    )

    assert spec.verify == "Planned Load Spike Verification"


def test_bare_list_or_dict_at_node_position_is_rejected():
    # A bare list is the legacy authoring anti-pattern: the spec must be a
    # typed mapping, not a free-form list/dict.
    with pytest.raises(ValidationError):
        ChaosSpec.model_validate([{"type": "time"}])
    with pytest.raises(ValidationError):
        # action position taking a bare list
        ChaosSpec.model_validate(
            {
                "trigger": {"type": "time"},
                "action": [{"type": "generate_load"}],
            }
        )


def test_unknown_extra_field_is_forbidden():
    # ``extra="forbid"`` keeps schema drift loud.
    with pytest.raises(ValidationError):
        ChaosSpec.model_validate(
            {
                "trigger": {"type": "time"},
                "action": {
                    "type": "generate_load",
                    "target": {"service_url": "http://x", "qps": 1},
                },
                "wat": "unexpected",
            }
        )


def test_unknown_discriminator_value_raises_validation_error():
    with pytest.raises(ValidationError):
        ChaosSpec.model_validate(
            {
                "trigger": {"type": "made_up"},
                "action": {
                    "type": "generate_load",
                    "target": {"service_url": "http://x", "qps": 1},
                },
            }
        )
    with pytest.raises(ValidationError):
        ChaosSpec.model_validate(
            {
                "trigger": {"type": "time"},
                "action": {"type": "no_such_fault"},
            }
        )


def test_validate_spec_returns_typed_chaos_spec():
    parsed = validate_spec(
        {
            "trigger": {"type": "time"},
            "action": {
                "type": "generate_load",
                "target": {"service_url": "http://x", "qps": 1},
            },
        }
    )
    assert isinstance(parsed, ChaosSpec)
    assert isinstance(parsed.action, GenerateLoadFault)


def test_json_schema_emits_a_top_level_object():
    schema = json_schema()
    assert schema.get("type") == "object"
    # Discriminator metadata lives under the property's reference; we just
    # assert the schema mentions the canonical fields and the union members.
    schema_str = repr(schema)
    assert "trigger" in schema_str
    assert "action" in schema_str
    assert "generate_load" in schema_str
    assert "time" in schema_str


def test_registries_advertise_the_phase_a_concretes():
    assert "generate_load" in FAULTS
    assert FAULTS.get("generate_load") is GenerateLoadFault
    assert "time" in TRIGGERS
    assert TRIGGERS.get("time") is TimeTrigger


def test_load_target_qps_must_be_positive():
    with pytest.raises(ValidationError):
        LoadTarget.model_validate({"service_url": "http://x", "qps": 0})


def test_time_trigger_delay_must_be_non_negative():
    with pytest.raises(ValidationError):
        TimeTrigger.model_validate({"type": "time", "delay_seconds": -1})
