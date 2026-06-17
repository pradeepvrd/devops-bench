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

"""Variable resolution for GCP-based OpenTofu stacks.

GCP clusters are provisioned via :class:`~devops_bench.deployers.tofu.TFDeployer`
with a GCP stack; there is no dedicated GCP deployer class.
"""

from __future__ import annotations

from typing import Any

from devops_bench.core import get_env

__all__ = ["resolve_variables"]


def resolve_variables(
    stack: str,
    custom_variables: dict[str, Any],
    global_project_id: str,
    global_cluster_name: str,
    global_location: str,
) -> dict[str, Any]:
    """Resolve default OpenTofu variables for GCP-based stacks.

    Args:
        stack: Stack name (unused; kept for resolver signature parity).
        custom_variables: Task-specified variables, preserved over defaults.
        global_project_id: Default ``project_id``.
        global_cluster_name: Default ``cluster_name``.
        global_location: Default ``location``.

    Returns:
        A new mapping with defaults filled in where not already set, plus
        ``namespace`` from the ``NAMESPACE`` environment variable when present.
    """
    variables = custom_variables.copy()
    variables.setdefault("project_id", global_project_id)
    variables.setdefault("cluster_name", global_cluster_name)
    variables.setdefault("location", global_location)
    namespace = get_env("NAMESPACE")
    if namespace is not None:
        variables.setdefault("namespace", namespace)
    return variables
