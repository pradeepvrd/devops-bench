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

"""Unit tests for devops_bench.k8s.conditions.

A fake clock and fake sleep drive ``poll_until`` so the backoff schedule is
verified without any real waiting.
"""

from devops_bench.k8s import conditions


class FakeClock:
    """Monotonic clock stub whose ``sleep`` advances the recorded time."""

    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


def test_poll_until_returns_true_immediately_without_sleeping():
    clock = FakeClock()

    result = conditions.poll_until(
        lambda: True,
        timeout_sec=100,
        sleep=clock.sleep,
        monotonic=clock.monotonic,
    )

    assert result is True
    assert clock.sleeps == []


def test_poll_until_succeeds_after_a_few_attempts():
    clock = FakeClock()
    calls = {"n": 0}

    def predicate() -> bool:
        calls["n"] += 1
        return calls["n"] == 3

    result = conditions.poll_until(
        predicate,
        timeout_sec=100,
        sleep=clock.sleep,
        monotonic=clock.monotonic,
    )

    assert result is True
    # Two failures before success -> two backoff sleeps.
    assert clock.sleeps == [1.0, 2.0]


def test_poll_until_backoff_sequence_is_capped():
    clock = FakeClock()

    # Always false; deadline large enough to exercise the cap, but the fake
    # clock advances via sleep so the loop terminates deterministically.
    result = conditions.poll_until(
        lambda: False,
        timeout_sec=40,
        sleep=clock.sleep,
        monotonic=clock.monotonic,
    )

    assert result is False
    # Doubling capped at max_delay (10): the fake clock reaches the deadline
    # after now hits 45 (0,1,3,7,15,25,35,45).
    assert clock.sleeps == [1.0, 2.0, 4.0, 8.0, 10.0, 10.0, 10.0]


def test_poll_until_respects_custom_delays():
    clock = FakeClock()

    result = conditions.poll_until(
        lambda: False,
        timeout_sec=20,
        initial_delay=2.0,
        max_delay=5.0,
        sleep=clock.sleep,
        monotonic=clock.monotonic,
    )

    assert result is False
    # 0 -> 2 -> 6 -> 11 -> 16 -> 21 (>= 20 deadline).
    assert clock.sleeps == [2.0, 4.0, 5.0, 5.0, 5.0]


def test_poll_until_timeout_returns_false():
    clock = FakeClock()

    result = conditions.poll_until(
        lambda: False,
        timeout_sec=0,
        sleep=clock.sleep,
        monotonic=clock.monotonic,
    )

    # Deadline already passed: no loop body, just the final check.
    assert result is False
    assert clock.sleeps == []


def test_poll_until_final_check_catches_boundary_success():
    clock = FakeClock()
    calls = {"n": 0}

    def predicate() -> bool:
        calls["n"] += 1
        # False on the first in-loop check, True on the final post-deadline check.
        return calls["n"] == 2

    result = conditions.poll_until(
        predicate,
        timeout_sec=1,
        sleep=clock.sleep,
        monotonic=clock.monotonic,
    )

    assert result is True


def test_all_pods_running_true_when_all_running():
    pods = {
        "items": [
            {"status": {"phase": "Running"}},
            {"status": {"phase": "Running"}},
        ]
    }
    assert conditions.all_pods_running(pods) is True


def test_all_pods_running_false_when_any_not_running():
    pods = {
        "items": [
            {"status": {"phase": "Running"}},
            {"status": {"phase": "Pending"}},
        ]
    }
    assert conditions.all_pods_running(pods) is False


def test_all_pods_running_false_when_empty():
    assert conditions.all_pods_running({"items": []}) is False
    assert conditions.all_pods_running({}) is False


def test_deployment_ready_true_when_enough_replicas():
    dep = {"status": {"readyReplicas": 3}}
    assert conditions.deployment_ready(dep, min_replicas=3) is True
    assert conditions.deployment_ready(dep, min_replicas=2) is True


def test_deployment_ready_false_when_insufficient():
    dep = {"status": {"readyReplicas": 1}}
    assert conditions.deployment_ready(dep, min_replicas=3) is False


def test_deployment_ready_defaults_missing_status_to_zero():
    assert conditions.deployment_ready({}, min_replicas=1) is False
