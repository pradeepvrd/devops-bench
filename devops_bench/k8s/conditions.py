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

"""Wait/poll engine and readiness predicates for Kubernetes resources."""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

__all__ = [
    "all_pods_running",
    "deployment_ready",
    "poll_until",
]


def poll_until(
    predicate: Callable[[], bool],
    *,
    timeout_sec: float,
    initial_delay: float = 1.0,
    max_delay: float = 10.0,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
) -> bool:
    """Poll a predicate with exponential backoff until it holds or time runs out.

    The predicate is checked once per iteration; on failure the loop sleeps for a
    delay that doubles each round (capped at ``max_delay``) before rechecking. A
    final check runs after the deadline so a predicate that flips right at the
    boundary is not missed.

    Args:
        predicate: Zero-argument callable returning True when the wait is done.
        timeout_sec: Maximum wall-clock seconds to keep polling.
        initial_delay: Seconds to sleep after the first failed check.
        max_delay: Upper bound on the backoff delay.
        sleep: Sleep function; injectable so tests can avoid real waiting.
        monotonic: Elapsed-time source; injectable for testing.

    Returns:
        True if the predicate held within the timeout, otherwise False.
    """
    start = monotonic()
    delay = initial_delay
    while monotonic() - start < timeout_sec:
        if predicate():
            return True
        sleep(delay)
        delay = min(delay * 2, max_delay)
    # One last check in case the predicate became true during the final sleep.
    return predicate()


def all_pods_running(pods_json: dict[str, Any]) -> bool:
    """Report whether every pod in a ``kubectl get pods -o json`` result is Running.

    Args:
        pods_json: Parsed JSON document with an ``items`` list of pods.

    Returns:
        True if there is at least one pod and all are in phase ``Running``.
    """
    items = pods_json.get("items", [])
    return len(items) > 0 and all(pod.get("status", {}).get("phase") == "Running" for pod in items)


def deployment_ready(dep_json: dict[str, Any], min_replicas: int) -> bool:
    """Report whether a deployment has at least ``min_replicas`` ready replicas.

    Args:
        dep_json: Parsed JSON of a ``kubectl get deployment -o json`` result.
        min_replicas: Minimum number of ready replicas required.

    Returns:
        True if ``status.readyReplicas`` is at least ``min_replicas``.
    """
    ready_replicas = dep_json.get("status", {}).get("readyReplicas", 0)
    return ready_replicas >= min_replicas
