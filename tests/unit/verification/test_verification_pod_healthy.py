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

"""Unit tests for the pod_healthy verifier.

The k8s wrappers (``wait``/``get_json``) are patched at the verifier module so
no real kubectl is invoked.
"""

import subprocess

from devops_bench.core.errors import SubprocessError
from devops_bench.verification.verifiers.pod_healthy import PodHealthyVerifier


def _completed(stdout: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=[], returncode=0, stdout=stdout)


def test_check_pods_status_success(mocker):
    mocker.patch(
        "devops_bench.verification.verifiers.pod_healthy.get_json",
        return_value={
            "items": [
                {"status": {"phase": "Running"}},
                {"status": {"phase": "Running"}},
            ]
        },
    )

    verifier = PodHealthyVerifier(selector="app=my-app")
    details = verifier._get_pods_details()
    success = verifier._check_pods_status(details)

    assert success is True
    assert len(details["items"]) == 2


def test_check_pods_status_failure(mocker):
    mocker.patch(
        "devops_bench.verification.verifiers.pod_healthy.get_json",
        return_value={
            "items": [
                {"status": {"phase": "Running"}},
                {"status": {"phase": "Pending"}},
            ]
        },
    )

    verifier = PodHealthyVerifier(selector="app=my-app")
    details = verifier._get_pods_details()

    assert verifier._check_pods_status(details) is False


def test_verify_wait_success(mocker):
    mocker.patch(
        "devops_bench.verification.verifiers.pod_healthy.wait",
        return_value=_completed("pod/my-pod condition met"),
    )

    verifier = PodHealthyVerifier(selector="app=my-app")
    result = verifier.verify(timeout_sec=60)

    assert result.success is True
    assert result.reason == "Condition met via kubectl wait"


def test_verify_wait_failure_fallback_success(mocker):
    # kubectl wait fails, but the Running-phase fallback holds.
    mocker.patch(
        "devops_bench.verification.verifiers.pod_healthy.wait",
        side_effect=SubprocessError(["kubectl", "wait"], returncode=1, stderr="timed out"),
    )
    mocker.patch(
        "devops_bench.verification.verifiers.pod_healthy.get_json",
        return_value={"items": [{"status": {"phase": "Running"}}]},
    )

    verifier = PodHealthyVerifier(selector="app=my-app")
    result = verifier.verify(timeout_sec=60)

    assert result.success is True
    assert result.reason == "Condition met via polling fallback"


def test_verify_wait_failure_fallback_failure(mocker):
    # kubectl wait fails and no pods are Running -> overall failure.
    mocker.patch(
        "devops_bench.verification.verifiers.pod_healthy.wait",
        side_effect=SubprocessError(["kubectl", "wait"], returncode=1, stderr="timed out"),
    )
    mocker.patch(
        "devops_bench.verification.verifiers.pod_healthy.get_json",
        return_value={"items": []},
    )

    verifier = PodHealthyVerifier(selector="app=my-app")
    result = verifier.verify(timeout_sec=60)

    assert result.success is False
    assert "timed out" in result.reason
