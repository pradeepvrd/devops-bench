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

"""Unit tests for the recursive VerifierAgent dispatcher.

Verifier ``verify`` methods are stubbed so the dispatcher logic is tested in
isolation from kubectl.
"""

from devops_bench.verification.base import VerificationResult
from devops_bench.verification.runner import VerifierAgent
from devops_bench.verification.verifiers.pod_healthy import PodHealthyVerifier
from devops_bench.verification.verifiers.scaling_complete import ScalingCompleteVerifier


def _ok(reason: str = "ok") -> VerificationResult:
    return VerificationResult(success=True, elapsed_time=0.0, reason=reason)


def _fail(reason: str = "nope") -> VerificationResult:
    return VerificationResult(success=False, elapsed_time=0.0, reason=reason)


def test_single_spec_delegates_to_verifier(mocker):
    mocker.patch.object(PodHealthyVerifier, "verify", return_value=_ok("pod ready"))

    spec = {"type": "pod_healthy", "selector": "app=my-app"}
    result = VerifierAgent().wait_for_condition(spec, timeout_sec=60)

    assert result.success is True
    assert result.reason == "pod ready"


def test_compound_dict_success(mocker):
    mocker.patch.object(PodHealthyVerifier, "verify", return_value=_ok())
    mocker.patch.object(ScalingCompleteVerifier, "verify", return_value=_ok())

    spec = {
        "pod_spec": {"type": "pod_healthy", "selector": "app=my-app"},
        "scaling_spec": {
            "type": "scaling_complete",
            "deployment": "my-dep",
            "min_replicas": 2,
        },
    }
    result = VerifierAgent().wait_for_condition(spec, timeout_sec=60)

    assert result.success is True
    assert "pod_spec succeeded" in result.reason
    assert "scaling_spec succeeded" in result.reason
    assert set(result.details) == {"pod_spec", "scaling_spec"}


def test_compound_dict_failure(mocker):
    mocker.patch.object(PodHealthyVerifier, "verify", return_value=_fail("timed out"))
    mocker.patch.object(ScalingCompleteVerifier, "verify", return_value=_ok())

    spec = {
        "pod_spec": {"type": "pod_healthy", "selector": "app=my-app"},
        "scaling_spec": {
            "type": "scaling_complete",
            "deployment": "my-dep",
            "min_replicas": 2,
        },
    }
    result = VerifierAgent().wait_for_condition(spec, timeout_sec=60)

    assert result.success is False
    assert "pod_spec failed" in result.reason
    assert "scaling_spec succeeded" in result.reason


def test_compound_list_aggregates_in_order(mocker):
    mocker.patch.object(PodHealthyVerifier, "verify", return_value=_ok())
    mocker.patch.object(ScalingCompleteVerifier, "verify", return_value=_fail())

    spec = [
        {"type": "pod_healthy", "selector": "app=my-app"},
        {"type": "scaling_complete", "deployment": "my-dep", "min_replicas": 2},
    ]
    result = VerifierAgent().wait_for_condition(spec, timeout_sec=60)

    assert result.success is False
    assert "spec[0] succeeded" in result.reason
    assert "spec[1] failed" in result.reason
    assert isinstance(result.details, list)
    assert len(result.details) == 2


def test_nested_compound_spec_recurses(mocker):
    # A dict whose value is a list (compound nested inside compound) must parse
    # under the recursive schema and dispatch through both levels.
    mocker.patch.object(PodHealthyVerifier, "verify", return_value=_ok())
    mocker.patch.object(ScalingCompleteVerifier, "verify", return_value=_fail("scaled short"))

    spec = {
        "group_a": [
            {"type": "pod_healthy", "selector": "app=a"},
            {"type": "scaling_complete", "deployment": "d", "min_replicas": 2},
        ],
    }
    result = VerifierAgent().wait_for_condition(spec, timeout_sec=60)

    # Outer dict fails because its inner list fails.
    assert result.success is False
    assert "group_a failed" in result.reason
    # The nested group is itself a VerificationResult holding the two child results.
    group = result.details["group_a"]
    assert isinstance(group, VerificationResult)
    assert isinstance(group.details, list)
    assert [c.success for c in group.details] == [True, False]
    assert "spec[1] failed" in group.reason


def test_deeply_nested_list_of_lists_parses(mocker):
    # list-of-lists previously raised ValidationError under the flat schema.
    mocker.patch.object(PodHealthyVerifier, "verify", return_value=_ok())

    spec = [[[{"type": "pod_healthy", "selector": "app=a"}]]]
    result = VerifierAgent().wait_for_condition(spec, timeout_sec=60)

    assert result.success is True


def test_remaining_can_go_non_positive(mocker):
    # _remaining no longer clamps to 1: once the budget is spent it returns <= 0
    # so callers can short-circuit instead of borrowing another second.
    mocker.patch("devops_bench.verification.runner.time.time", return_value=150.0)
    assert VerifierAgent._remaining(start_time=100.0, timeout_sec=30) == -20


def test_compound_list_aborts_remaining_members_when_budget_exhausted(mocker):
    # Clock: start at 0, then the first member's _remaining sees 1s elapsed (ok),
    # and every subsequent reading is past the 5s budget so members 2+ are
    # skipped without their verify() ever running.
    times = iter([0.0, 1.0, 99.0, 99.0, 99.0, 99.0])
    mocker.patch(
        "devops_bench.verification.runner.time.time",
        side_effect=lambda: next(times),
    )
    pod_verify = mocker.patch.object(PodHealthyVerifier, "verify", return_value=_ok())
    scaling_verify = mocker.patch.object(ScalingCompleteVerifier, "verify", return_value=_ok())

    spec = [
        {"type": "pod_healthy", "selector": "app=my-app"},
        {"type": "scaling_complete", "deployment": "my-dep", "min_replicas": 2},
    ]
    result = VerifierAgent().wait_for_condition(spec, timeout_sec=5)

    # First member ran and passed; second was never invoked and is timed out.
    assert pod_verify.call_count == 1
    assert scaling_verify.call_count == 0
    assert result.success is False
    assert "spec[0] succeeded" in result.reason
    assert "spec[1] failed: timed out" in result.reason
    assert len(result.details) == 2
    assert result.details[1].success is False


def test_compound_dict_aborts_remaining_members_when_budget_exhausted(mocker):
    times = iter([0.0, 1.0, 99.0, 99.0, 99.0, 99.0])
    mocker.patch(
        "devops_bench.verification.runner.time.time",
        side_effect=lambda: next(times),
    )
    pod_verify = mocker.patch.object(PodHealthyVerifier, "verify", return_value=_ok())
    scaling_verify = mocker.patch.object(ScalingCompleteVerifier, "verify", return_value=_ok())

    spec = {
        "pod_spec": {"type": "pod_healthy", "selector": "app=my-app"},
        "scaling_spec": {
            "type": "scaling_complete",
            "deployment": "my-dep",
            "min_replicas": 2,
        },
    }
    result = VerifierAgent().wait_for_condition(spec, timeout_sec=5)

    assert pod_verify.call_count == 1
    assert scaling_verify.call_count == 0
    assert result.success is False
    assert "pod_spec succeeded" in result.reason
    assert "scaling_spec failed: timed out" in result.reason
    assert result.details["scaling_spec"].success is False
