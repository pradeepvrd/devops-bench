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

"""Tests for the OpenTofu deployer."""

from __future__ import annotations

import json
import os
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from devops_bench.deployers.tofu import _TF_ROOT, TFDeployer


@pytest.fixture
def tf_deployer(mocker):
    variables = {
        "project_id": "test-project",
        "cluster_name": "test-cluster",
        "location": "us-central1-a",
        "node_count": 3,
    }
    mocker.patch("devops_bench.deployers.tofu.Path.exists", return_value=True)
    return TFDeployer(tf_dir="prebuilt/minimum", variables=variables)


def test_up(mocker, tf_deployer):
    mock_run = mocker.patch("devops_bench.deployers.tofu.run")
    tf_deployer.up()

    calls = mock_run.call_args_list
    assert len(calls) == 2
    assert calls[0].args[0] == ["tofu", "init", "-input=false"]
    assert calls[0].kwargs["cwd"] == tf_deployer.tf_dir
    assert calls[1].args[0] == [
        "tofu",
        "apply",
        "-auto-approve",
        "-input=false",
        "-var",
        "project_id=test-project",
        "-var",
        "cluster_name=test-cluster",
        "-var",
        "location=us-central1-a",
        "-var",
        "node_count=3",
    ]
    assert calls[1].kwargs["cwd"] == tf_deployer.tf_dir


def test_down(mocker, tf_deployer):
    mock_run = mocker.patch("devops_bench.deployers.tofu.run")
    tf_deployer.down()

    calls = mock_run.call_args_list
    assert len(calls) == 2
    assert calls[0].args[0] == ["tofu", "init", "-input=false"]
    assert calls[1].args[0] == [
        "tofu",
        "destroy",
        "-auto-approve",
        "-input=false",
        "-var",
        "project_id=test-project",
        "-var",
        "cluster_name=test-cluster",
        "-var",
        "location=us-central1-a",
        "-var",
        "node_count=3",
    ]


def _output_process(location):
    proc = MagicMock()
    proc.stdout = json.dumps(
        {
            "cluster_name": {"value": "test-cluster"},
            "cluster_location": {"value": location},
        }
    )
    return proc


def test_get_cluster_info(mocker, tf_deployer):
    mock_run = mocker.patch("devops_bench.deployers.tofu.run")
    mock_run.side_effect = [MagicMock(), _output_process("us-central1-a"), MagicMock()]

    info = tf_deployer.get_cluster_info()

    assert info.name == "test-cluster"
    assert info.location == "us-central1-a"
    assert info.project == "test-project"
    assert info.kubeconfig_path

    calls = mock_run.call_args_list
    assert len(calls) == 3
    assert calls[0].args[0] == ["tofu", "init", "-input=false"]
    assert calls[1].args[0] == ["tofu", "output", "-json"]
    assert calls[2].args[0] == [
        "gcloud",
        "container",
        "clusters",
        "get-credentials",
        "test-cluster",
        "--location",
        "us-central1-a",
        "--project",
        "test-project",
    ]


def test_get_cluster_info_regional(mocker, tf_deployer):
    mock_run = mocker.patch("devops_bench.deployers.tofu.run")
    mock_run.side_effect = [MagicMock(), _output_process("us-central1"), MagicMock()]

    info = tf_deployer.get_cluster_info()

    assert info.name == "test-cluster"
    assert info.location == "us-central1"
    assert info.project == "test-project"

    calls = mock_run.call_args_list
    assert len(calls) == 3
    assert calls[2].args[0] == [
        "gcloud",
        "container",
        "clusters",
        "get-credentials",
        "test-cluster",
        "--location",
        "us-central1",
        "--project",
        "test-project",
    ]


def test_get_cluster_info_local(mocker, tf_deployer):
    mock_run = mocker.patch("devops_bench.deployers.tofu.run")
    mock_run.side_effect = [MagicMock(), _output_process("local")]

    info = tf_deployer.get_cluster_info()

    assert info.name == "test-cluster"
    assert info.location == "local"
    assert info.project == "test-project"
    assert info.kubeconfig_path

    calls = mock_run.call_args_list
    assert len(calls) == 2
    assert calls[0].args[0] == ["tofu", "init", "-input=false"]
    assert calls[1].args[0] == ["tofu", "output", "-json"]
    for call in calls:
        assert "gcloud" not in call.args[0]


def test_get_cluster_info_local_no_project(mocker):
    mocker.patch("devops_bench.deployers.tofu.Path.exists", return_value=True)
    deployer = TFDeployer(tf_dir="prebuilt/minimum", variables={})

    mock_run = mocker.patch("devops_bench.deployers.tofu.run")
    mock_run.side_effect = [MagicMock(), _output_process("local")]

    mocker.patch.dict(os.environ, {}, clear=True)
    info = deployer.get_cluster_info()

    assert info.name == "test-cluster"
    assert info.location == "local"
    assert info.project == "local-kind"
    assert info.kubeconfig_path


def test_init_path_resolution(mocker):
    # Absolute path that exists.
    mocker.patch("devops_bench.deployers.tofu.Path.exists", return_value=True)
    abs_path = "/tmp/my-tf-stack"
    deployer = TFDeployer(tf_dir=abs_path)
    assert deployer.tf_dir == abs_path

    # Relative path resolved under <repo_root>/tf.
    deployer = TFDeployer(tf_dir="my-repo-stack")
    assert deployer.tf_dir == str(_TF_ROOT / "my-repo-stack")
    assert Path(deployer.tf_dir) == _TF_ROOT / "my-repo-stack"
