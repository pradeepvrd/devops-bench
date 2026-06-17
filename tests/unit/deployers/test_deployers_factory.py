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

"""Tests for the deployer factory."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from devops_bench.deployers.factory import get_deployer
from devops_bench.deployers.gcp import GCPDeployer
from devops_bench.deployers.tofu import _TF_ROOT, TFDeployer


@pytest.fixture
def base_config():
    return {
        "project_id": "test-project",
        "cluster_name": "test-cluster",
        "location": "us-central1-a",
    }


def _expected_kubeconfig():
    return os.environ.get("KUBECONFIG") or str(Path("~/.kube/config").expanduser().resolve())


def test_get_deployer_default(mocker, base_config):
    mocker.patch("devops_bench.deployers.tofu.Path.exists", return_value=True)
    deployer = get_deployer(
        {},
        base_config["project_id"],
        base_config["cluster_name"],
        base_config["location"],
    )
    assert isinstance(deployer, TFDeployer)
    assert deployer.tf_dir == str(_TF_ROOT / "prebuilt/kind")


def test_get_deployer_kubetest2(base_config):
    deployer = get_deployer(
        {"deployer": "kubetest2"},
        base_config["project_id"],
        base_config["cluster_name"],
        base_config["location"],
    )
    assert isinstance(deployer, GCPDeployer)


def test_get_deployer_tofu_default_stack(mocker, base_config):
    mocker.patch("devops_bench.deployers.tofu.Path.exists", return_value=True)
    deployer = get_deployer(
        {"deployer": "tofu"},
        base_config["project_id"],
        base_config["cluster_name"],
        base_config["location"],
    )
    assert isinstance(deployer, TFDeployer)
    assert deployer.variables == {
        "cluster_name": base_config["cluster_name"],
        "location": "local",
        "kubeconfig_path": _expected_kubeconfig(),
    }
    assert deployer.tf_dir == str(_TF_ROOT / "prebuilt/kind")


def test_get_deployer_tofu_custom_stack_and_vars(mocker, base_config):
    mocker.patch("devops_bench.deployers.tofu.Path.exists", return_value=True)
    infra_config = {
        "deployer": "tofu",
        "stack": "custom/stack",
        "variables": {
            "node_count": 5,
            "machine_type": "n2-standard-4",
            "cluster_name": "custom-cluster",  # overrides global
        },
    }
    deployer = get_deployer(
        infra_config,
        base_config["project_id"],
        base_config["cluster_name"],
        base_config["location"],
    )
    assert isinstance(deployer, TFDeployer)
    assert deployer.variables == {
        "project_id": base_config["project_id"],
        "cluster_name": "custom-cluster",
        "location": base_config["location"],
        "node_count": 5,
        "machine_type": "n2-standard-4",
    }
    assert deployer.tf_dir == str(_TF_ROOT / "custom/stack")


def test_get_deployer_location_from_env(mocker, base_config):
    mocker.patch.dict(os.environ, {"GCP_LOCATION": "us-west1-b"})
    deployer = get_deployer(
        {"deployer": "kubetest2"},
        base_config["project_id"],
        base_config["cluster_name"],
        global_location=None,
    )
    assert deployer.zone == "us-west1-b"


def test_get_deployer_tofu_kind_stack(mocker, base_config):
    mocker.patch("devops_bench.deployers.tofu.Path.exists", return_value=True)
    deployer = get_deployer(
        {"deployer": "tofu", "stack": "prebuilt/kind"},
        base_config["project_id"],
        base_config["cluster_name"],
        base_config["location"],
    )
    assert isinstance(deployer, TFDeployer)
    assert deployer.variables == {
        "cluster_name": base_config["cluster_name"],
        "location": "local",
        "kubeconfig_path": _expected_kubeconfig(),
    }
    assert deployer.tf_dir == str(_TF_ROOT / "prebuilt/kind")
