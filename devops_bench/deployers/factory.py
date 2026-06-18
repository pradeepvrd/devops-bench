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

"""Factory selecting an infrastructure deployer from task config and env."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from devops_bench.core import ConfigError, Registry, get_bool, get_env
from devops_bench.deployers.base import Deployer
from devops_bench.deployers.gcp import resolve_variables as resolve_gcp_vars
from devops_bench.deployers.kind import resolve_variables as resolve_kind_vars

__all__ = ["DEPLOYERS", "get_deployer"]

_DEFAULT_LOCATION = "us-central1-a"
_DEFAULT_STACK = "prebuilt/kind"

# Per-provider OpenTofu variable resolvers, keyed by deduced provider name. The
# resolver modules are lightweight, so they are imported and registered eagerly
# at module load to keep registration race-free under concurrent callers.
DEPLOYERS: Registry[Callable[..., dict[str, Any]]] = Registry("deployers")
DEPLOYERS.register("gcp")(resolve_gcp_vars)
DEPLOYERS.register("kind")(resolve_kind_vars)


def get_deployer(
    infra_config: dict[str, Any],
    global_project_id: str,
    global_cluster_name: str,
    global_location: str | None = None,
) -> Deployer:
    """Instantiate the deployer selected by task config and environment.

    OpenTofu (``tofu``) is the sole provisioning engine; the provider (``gcp`` or
    ``kind``) only selects which variable resolver fills the stack defaults. Set
    ``BENCH_NO_INFRA=true`` or ``deployer: noop`` to skip provisioning entirely;
    ``BENCH_NO_INFRA`` takes precedence over any task config. Location precedence:
    ``global_location`` arg → ``GCP_LOCATION`` env → ``us-central1-a``.

    Args:
        infra_config: Task infrastructure config (``deployer``, ``stack``,
            ``variables``).
        global_project_id: Default project ID.
        global_cluster_name: Default cluster name.
        global_location: Explicit location override.

    Returns:
        A configured :class:`~devops_bench.deployers.base.Deployer`.

    Raises:
        ConfigError: If ``infra_config["deployer"]`` is set to anything other
            than ``tofu`` or ``noop``.
    """
    deployer_type = (infra_config.get("deployer") or "").lower()

    if get_bool("BENCH_NO_INFRA") or deployer_type == "noop":
        # Imported lazily to keep package import light.
        from devops_bench.deployers.noop import NoOpDeployer

        return NoOpDeployer(cluster_name=global_cluster_name, project_id=global_project_id)

    if deployer_type and deployer_type != "tofu":
        raise ConfigError(
            f"unsupported deployer {deployer_type!r}; use 'tofu', or 'noop' / "
            "BENCH_NO_INFRA=true to skip infra"
        )

    # The concrete engine is imported here so importing this module stays light.
    from devops_bench.deployers.tofu import TFDeployer

    location = global_location or get_env("GCP_LOCATION", _DEFAULT_LOCATION)
    stack = infra_config.get("stack") or _DEFAULT_STACK
    variables = infra_config.get("variables", {})

    cloud_provider = (get_env("CLOUD_PROVIDER", "") or "").lower()
    provider = cloud_provider or ("kind" if "kind" in stack else "gcp")
    if provider in DEPLOYERS:
        resolver = DEPLOYERS.get(provider)
        variables = resolver(stack, variables, global_project_id, global_cluster_name, location)

    return TFDeployer(tf_dir=stack, variables=variables)
