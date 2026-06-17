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

"""GCP deployer that provisions clusters with ``kubetest2 gke``."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from devops_bench.core import ClusterInfo, get_env, get_logger
from devops_bench.core.subprocess import run
from devops_bench.deployers.base import Deployer

__all__ = ["GCPDeployer", "resolve_variables"]

# This module lives at ``<repo_root>/devops_bench/deployers/gcp.py``; the repo
# root is therefore three levels up, and the bundled kubetest2 binaries live
# under ``<repo_root>/third_party/kubetest2/bin``.
_REPO_ROOT = Path(__file__).resolve().parents[2]
_KUBETEST2_BIN = _REPO_ROOT / "third_party" / "kubetest2" / "bin"

_DEFAULT_LOCATION = "us-central1-a"

_log = get_logger("deployers.gcp")


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


class GCPDeployer(Deployer):
    """Deployer that manages a GKE cluster via ``kubetest2 gke``.

    Args:
        project: GCP project ID.
        location: Cluster region or zone; falls back to ``zone``, then
            ``GCP_LOCATION``, then ``us-central1-a``.
        cluster_name: Name of the cluster to manage.
        zone: Alternative spelling of ``location``.
        **config: Extra ``kubetest2`` flags, passed as ``--key value`` with
            underscores converted to dashes.
    """

    def __init__(
        self,
        project: str,
        location: str | None = None,
        cluster_name: str | None = None,
        zone: str | None = None,
        **config: Any,
    ) -> None:
        self.project = project
        self.cluster_name = cluster_name
        self.config = config

        self.location = location or zone or get_env("GCP_LOCATION", _DEFAULT_LOCATION)
        self.zone = self.location

        self.bin_dir = str(_KUBETEST2_BIN.resolve())

    def _path_env(self) -> dict[str, str]:
        """Prepend the bundled kubetest2 bin dir to ``PATH``."""
        return {"PATH": f"{self.bin_dir}:{get_env('PATH', '')}"}

    def _state_file(self) -> Path:
        return Path(f"/tmp/{self.project}-{self.location}-{self.cluster_name}_created")

    def up(self) -> None:
        check_cmd = [
            "gcloud",
            "container",
            "clusters",
            "describe",
            self.cluster_name,
            "--project",
            self.project,
            "--location",
            self.location,
        ]
        _log.info("Checking if cluster exists: %s", " ".join(check_cmd))
        result = run(check_cmd, capture=True, check=False)

        state_file = self._state_file()

        if result.returncode == 0:
            _log.info("Cluster %s already exists. Getting credentials.", self.cluster_name)
            run(
                [
                    "gcloud",
                    "container",
                    "clusters",
                    "get-credentials",
                    self.cluster_name,
                    "--project",
                    self.project,
                    "--location",
                    self.location,
                ],
                capture=False,
            )
            state_file.write_text("false")
        else:
            _log.info(
                "Cluster %s does not exist or error checking. Creating it.",
                self.cluster_name,
            )
            cmd = [
                "kubetest2",
                "gke",
                "--project",
                self.project,
                "--zone",
                self.location,
                "--cluster-name",
                self.cluster_name,
            ]
            for key, value in self.config.items():
                if value is not None:
                    cmd.extend([f"--{key.replace('_', '-')}", str(value)])
            cmd.append("--up")

            _log.info("Running: %s", " ".join(cmd))
            run(cmd, extra_env=self._path_env(), capture=False)
            state_file.write_text("true")

    def down(self) -> None:
        state_file = self._state_file()
        created_by_us = True
        if state_file.exists():
            created_by_us = state_file.read_text().strip() == "true"

        if not created_by_us:
            _log.info("Skipping teardown for pre-existing cluster %s", self.cluster_name)
            return

        cmd = [
            "kubetest2",
            "gke",
            "--project",
            self.project,
            "--zone",
            self.location,
            "--cluster-name",
            self.cluster_name,
            "--down",
        ]
        _log.info("Running: %s", " ".join(cmd))
        run(cmd, extra_env=self._path_env(), capture=False)

    def get_cluster_info(self) -> ClusterInfo:
        """Return connection details for the managed cluster.

        Returns:
            The cluster's :class:`~devops_bench.core.ClusterInfo`.
        """
        return ClusterInfo.from_dict(
            {
                "name": self.cluster_name,
                "location": self.location,
                "project": self.project,
            }
        )
