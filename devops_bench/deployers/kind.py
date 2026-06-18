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

"""Variable resolution for local KinD stacks.

KinD clusters are provisioned via :class:`~devops_bench.deployers.tofu.TFDeployer`
with a kind stack; there is no dedicated KinD deployer class.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from devops_bench.core import get_env

__all__ = ["resolve_variables"]

_DEFAULT_CLUSTER_NAME = "devops-bench-kind"


def resolve_variables(
    stack: str,
    custom_variables: dict[str, Any],
    global_project_id: str,
    global_cluster_name: str,
    global_location: str,
) -> dict[str, Any]:
    """Resolve default OpenTofu variables for local KinD stacks.

    Args:
        stack: Stack name (unused; kept for resolver signature parity).
        custom_variables: Task-specified variables, preserved over defaults.
        global_project_id: Default project ID (unused for local clusters).
        global_cluster_name: Default cluster name; falls back to
            ``devops-bench-kind`` when empty.
        global_location: Default location (unused; local clusters are ``local``).

    Returns:
        A new mapping with ``cluster_name``, ``location`` (``"local"``), and
        ``kubeconfig_path`` filled in where not already set.
    """
    variables = custom_variables.copy()
    cluster_name = global_cluster_name or _DEFAULT_CLUSTER_NAME
    variables.setdefault("cluster_name", cluster_name)
    variables.setdefault("location", "local")

    kubeconfig_path = get_env("KUBECONFIG") or str(Path("~/.kube/config").expanduser().resolve())
    variables.setdefault("kubeconfig_path", kubeconfig_path)
    return variables
