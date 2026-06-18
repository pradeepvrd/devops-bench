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

"""OpenTofu-backed deployer driving repo-local ``tf/`` stacks."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from devops_bench.core import ClusterInfo, ConfigError, get_env, get_logger
from devops_bench.core.subprocess import run
from devops_bench.deployers.base import Deployer

__all__ = ["TFDeployer"]

# This module lives at ``<repo_root>/devops_bench/deployers/tofu.py``; the repo
# root is therefore three levels up, and Tofu stacks live under ``<repo_root>/tf``.
_REPO_ROOT = Path(__file__).resolve().parents[2]
_TF_ROOT = _REPO_ROOT / "tf"

_log = get_logger("deployers.tofu")


def _format_var(value: Any) -> str:
    """Format a Python value as an OpenTofu ``-var`` literal.

    Args:
        value: Variable value to serialize.

    Returns:
        ``"true"``/``"false"`` for booleans, JSON for lists and dicts,
        ``"null"`` for ``None``, and ``str(value)`` otherwise.
    """
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (list, dict)):
        return json.dumps(value)
    if value is None:
        return "null"
    return str(value)


class TFDeployer(Deployer):
    """Deployer that provisions a cluster via an OpenTofu stack.

    Honors the ``TF_DATA_DIR`` environment variable so OpenTofu state can be
    redirected for idempotent runs.

    Args:
        tf_dir: Stack directory; an absolute path or a name resolved under
            ``<repo_root>/tf``.
        variables: OpenTofu input variables passed as ``-var`` flags.

    Raises:
        ConfigError: If the stack directory does not exist.
    """

    def __init__(self, tf_dir: str, variables: dict[str, Any] | None = None) -> None:
        tf_path = Path(tf_dir)
        if tf_path.is_absolute():
            if not tf_path.exists():
                raise ConfigError(f"Absolute TF directory not found: {tf_dir}")
            self.tf_dir = str(tf_path)
        else:
            repo_tf_path = _TF_ROOT / tf_path
            if not repo_tf_path.exists():
                raise ConfigError(f"TF stack not found in repo: {tf_dir} (checked {repo_tf_path})")
            self.tf_dir = str(repo_tf_path)

        self.variables = variables or {}

    def _var_flags(self) -> list[str]:
        flags: list[str] = []
        for key, value in self.variables.items():
            flags.extend(["-var", f"{key}={_format_var(value)}"])
        return flags

    def up(self) -> None:
        tf_path = Path(self.tf_dir)
        if not tf_path.exists():
            raise ConfigError(f"TF directory not found: {self.tf_dir}")

        run(["tofu", "init", "-input=false"], cwd=self.tf_dir, capture=False)

        cmd = ["tofu", "apply", "-auto-approve", "-input=false", *self._var_flags()]
        run(cmd, cwd=self.tf_dir, capture=False)

    def down(self) -> None:
        tf_path = Path(self.tf_dir)
        if not tf_path.exists():
            _log.warning("TF directory %s not found. Skipping teardown.", self.tf_dir)
            return

        run(["tofu", "init", "-input=false"], cwd=self.tf_dir, capture=False)

        cmd = ["tofu", "destroy", "-auto-approve", "-input=false", *self._var_flags()]
        run(cmd, cwd=self.tf_dir, capture=False)

    def get_cluster_info(self) -> ClusterInfo:
        """Read cluster details from the stack outputs.

        For non-local clusters this also configures ``kubectl`` credentials via
        ``gcloud``.

        Returns:
            The provisioned cluster's :class:`~devops_bench.core.ClusterInfo`.

        Raises:
            ConfigError: If required outputs are missing, or a non-local cluster
                has no resolvable project.
        """
        run(["tofu", "init", "-input=false"], cwd=self.tf_dir, capture=False)

        result = run(["tofu", "output", "-json"], cwd=self.tf_dir, capture=True)
        try:
            outputs = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise ConfigError("failed to parse 'tofu output -json'") from exc

        cluster_name = outputs.get("cluster_name", {}).get("value")
        if not cluster_name:
            raise ConfigError("Failed to retrieve 'cluster_name' from TF outputs.")

        location = outputs.get("cluster_location", {}).get("value")
        if not location:
            raise ConfigError("Failed to retrieve 'cluster_location' from TF outputs.")

        if location == "local":
            project = self.variables.get("project_id") or get_env("GCP_PROJECT_ID") or "local-kind"
            return ClusterInfo.from_dict(
                {"name": cluster_name, "location": location, "project": project}
            )

        project = self.variables.get("project_id") or get_env("GCP_PROJECT_ID")
        if not project:
            raise ConfigError("Project ID not found in variables or environment (GCP_PROJECT_ID).")

        _log.info("Configuring kubectl for cluster: %s in %s...", cluster_name, location)
        run(
            [
                "gcloud",
                "container",
                "clusters",
                "get-credentials",
                cluster_name,
                "--location",
                location,
                "--project",
                project,
            ],
            capture=False,
        )

        return ClusterInfo.from_dict(
            {"name": cluster_name, "location": location, "project": project}
        )
