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

"""Tests for the GCP (kubetest2) deployer."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock

import pytest

from devops_bench.deployers.gcp import GCPDeployer


@pytest.fixture
def gcp_setup():
    return {
        "project": "test-project",
        "location": "us-central1-a",
        "cluster_name": "test-cluster",
        "deployer": GCPDeployer("test-project", "us-central1-a", "test-cluster"),
    }


def _path_env(call):
    """Extract the env mapping passed to a mocked ``run`` call."""
    return call.kwargs.get("extra_env") or call.kwargs.get("env")


def test_up(mocker, gcp_setup):
    deployer = gcp_setup["deployer"]
    mock_write_text = mocker.patch.object(Path, "write_text")
    mock_run = mocker.patch("devops_bench.deployers.gcp.run")

    describe = MagicMock()
    describe.returncode = 1
    mock_run.side_effect = [describe, MagicMock()]

    deployer.up()

    calls = mock_run.call_args_list
    assert len(calls) == 2
    assert calls[0].args[0] == [
        "gcloud",
        "container",
        "clusters",
        "describe",
        gcp_setup["cluster_name"],
        "--project",
        gcp_setup["project"],
        "--location",
        gcp_setup["location"],
    ]

    cmd = calls[1].args[0]
    assert "kubetest2" in cmd
    assert "gke" in cmd
    assert "--up" in cmd
    assert gcp_setup["project"] in cmd

    env = _path_env(calls[1])
    assert env is not None
    assert deployer.bin_dir in env["PATH"]
    mock_write_text.assert_called_once_with("true")


def test_up_with_config(mocker, gcp_setup):
    deployer = GCPDeployer(
        gcp_setup["project"],
        gcp_setup["location"],
        gcp_setup["cluster_name"],
        machine_type="n1-standard-4",
        num_nodes=5,
    )
    mock_write_text = mocker.patch.object(Path, "write_text")
    mock_run = mocker.patch("devops_bench.deployers.gcp.run")

    describe = MagicMock()
    describe.returncode = 1
    mock_run.side_effect = [describe, MagicMock()]

    deployer.up()

    calls = mock_run.call_args_list
    assert len(calls) == 2
    cmd = calls[1].args[0]
    assert "--machine-type" in cmd
    assert "n1-standard-4" in cmd
    assert "--num-nodes" in cmd
    assert "5" in cmd
    mock_write_text.assert_called_once_with("true")


def test_down(mocker, gcp_setup):
    deployer = gcp_setup["deployer"]
    mock_run = mocker.patch("devops_bench.deployers.gcp.run")
    mocker.patch.object(Path, "exists", return_value=True)
    mocker.patch.object(Path, "read_text", return_value="true")

    deployer.down()

    mock_run.assert_called_once()
    cmd = mock_run.call_args.args[0]
    assert "kubetest2" in cmd
    assert "gke" in cmd
    assert "--down" in cmd
    assert gcp_setup["project"] in cmd

    env = _path_env(mock_run.call_args)
    assert env is not None
    assert deployer.bin_dir in env["PATH"]


def test_get_cluster_info(gcp_setup):
    info = gcp_setup["deployer"].get_cluster_info()
    assert info.name == gcp_setup["cluster_name"]
    assert info.location == gcp_setup["location"]
    assert info.project == gcp_setup["project"]
    assert info.kubeconfig_path
