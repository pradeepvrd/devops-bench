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

"""Unit tests for the scaling_complete verifier.

The k8s ``get_json`` wrapper is patched at the verifier module; backoff polling
is exercised by patching ``_check_scaling`` so no real time passes.
"""

from devops_bench.core.errors import SubprocessError
from devops_bench.verification.verifiers.scaling_complete import ScalingCompleteVerifier


def test_check_scaling_success(mocker):
    mocker.patch(
        "devops_bench.verification.verifiers.scaling_complete.get_json",
        return_value={"status": {"readyReplicas": 3}},
    )

    verifier = ScalingCompleteVerifier(deployment="my-dep", min_replicas=3)
    success, details = verifier._check_scaling()

    assert success is True
    assert "Ready replicas (3) >= min replicas (3)" in details["reason"]


def test_check_scaling_below_minimum(mocker):
    mocker.patch(
        "devops_bench.verification.verifiers.scaling_complete.get_json",
        return_value={"status": {"readyReplicas": 1}},
    )

    verifier = ScalingCompleteVerifier(deployment="my-dep", min_replicas=3)
    success, details = verifier._check_scaling()

    assert success is False
    assert "Ready replicas (1) < min replicas (3)" in details["reason"]


def test_check_scaling_handles_null_status(mocker):
    # A freshly-created deployment may report "status": null before the
    # controller populates it; treat readyReplicas as 0 instead of crashing.
    mocker.patch(
        "devops_bench.verification.verifiers.scaling_complete.get_json",
        return_value={"status": None},
    )

    verifier = ScalingCompleteVerifier(deployment="my-dep", min_replicas=2)
    success, details = verifier._check_scaling()

    assert success is False
    assert "Ready replicas (0) < min replicas (2)" in details["reason"]


def test_check_scaling_get_failure(mocker):
    mocker.patch(
        "devops_bench.verification.verifiers.scaling_complete.get_json",
        side_effect=SubprocessError(["kubectl", "get"], returncode=1, stderr="not found"),
    )

    verifier = ScalingCompleteVerifier(deployment="my-dep")
    success, details = verifier._check_scaling()

    assert success is False
    assert "Failed to get deployment" in details["reason"]


def test_verify_polling_succeeds_on_first_check(mocker):
    # A first-pass success returns immediately with no backoff sleep, so the
    # verifier formats the "Scaling complete" result from the real poll_until.
    mock_check = mocker.patch.object(
        ScalingCompleteVerifier,
        "_check_scaling",
        return_value=(True, {"reason": "done"}),
    )

    verifier = ScalingCompleteVerifier(deployment="my-dep", min_replicas=2)
    result = verifier.verify(timeout_sec=60)

    assert result.success is True
    assert result.reason == "Scaling complete: done"
    assert mock_check.call_count == 1


def test_verify_polling_succeeds_after_retry(mocker):
    # First check fails, then succeeds. Wrap the real poll_until with a no-op
    # sleep injected so the backoff recheck happens without any real waiting.
    from devops_bench.k8s import poll_until as real_poll_until

    mock_check = mocker.patch.object(
        ScalingCompleteVerifier,
        "_check_scaling",
        side_effect=[
            (False, {"reason": "not yet"}),
            (True, {"reason": "done"}),
        ],
    )
    mocker.patch(
        "devops_bench.verification.verifiers.scaling_complete.poll_until",
        side_effect=lambda predicate, **kw: real_poll_until(
            predicate, **{**kw, "sleep": lambda _seconds: None}
        ),
    )

    verifier = ScalingCompleteVerifier(deployment="my-dep", min_replicas=2)
    result = verifier.verify(timeout_sec=60)

    assert result.success is True
    assert result.reason == "Scaling complete: done"
    assert mock_check.call_count == 2


def test_verify_timeout_failure(mocker):
    mocker.patch.object(
        ScalingCompleteVerifier,
        "_check_scaling",
        return_value=(False, {"reason": "still scaling"}),
    )

    verifier = ScalingCompleteVerifier(deployment="my-dep", min_replicas=5)
    result = verifier.verify(timeout_sec=0)

    assert result.success is False
    assert "Timeout reached: still scaling" in result.reason
