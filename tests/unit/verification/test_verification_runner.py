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
