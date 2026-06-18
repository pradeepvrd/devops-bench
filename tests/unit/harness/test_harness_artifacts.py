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

"""Tests for capturing agent-generated artifacts via directory diffing."""

from __future__ import annotations

import os

from devops_bench.harness.artifacts import collect_generated_files, snapshot_dir


def test_snapshot_dir_lists_entries(tmp_path):
    (tmp_path / "a.txt").write_text("a")
    (tmp_path / "sub").mkdir()
    assert snapshot_dir(str(tmp_path)) == {"a.txt", "sub"}


def test_collect_copies_new_files_and_dirs(tmp_path):
    source = tmp_path / "work"
    source.mkdir()
    (source / "existing.txt").write_text("old")
    before = snapshot_dir(str(source))

    (source / "new_file.yaml").write_text("kind: ConfigMap")
    new_dir = source / "manifests"
    new_dir.mkdir()
    (new_dir / "deploy.yaml").write_text("kind: Deployment")

    run_dir = tmp_path / "run"
    run_dir.mkdir()

    copied = collect_generated_files(before, str(run_dir), source_dir=str(source))

    assert set(copied) == {"new_file.yaml", "manifests"}
    gen = run_dir / "generated_files"
    assert (gen / "new_file.yaml").read_text() == "kind: ConfigMap"
    assert (gen / "manifests" / "deploy.yaml").read_text() == "kind: Deployment"
    # The pre-existing file is not captured.
    assert not (gen / "existing.txt").exists()


def test_collect_no_new_files_skips_dir(tmp_path):
    source = tmp_path / "work"
    source.mkdir()
    (source / "a.txt").write_text("a")
    before = snapshot_dir(str(source))

    run_dir = tmp_path / "run"
    run_dir.mkdir()

    copied = collect_generated_files(before, str(run_dir), source_dir=str(source))

    assert copied == []
    assert not os.path.exists(run_dir / "generated_files")
