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

"""Capture files an agent generates by diffing a directory before and after."""

from __future__ import annotations

import os
import shutil

from devops_bench.core import get_logger

__all__ = ["snapshot_dir", "collect_generated_files"]

_log = get_logger("harness.artifacts")


def snapshot_dir(path: str = ".") -> set[str]:
    """Snapshot the immediate entries of a directory.

    Args:
        path: Directory to list; defaults to the current working directory.

    Returns:
        The set of entry names directly under ``path``.
    """
    return set(os.listdir(path))


def collect_generated_files(
    before: set[str],
    run_dir: str,
    *,
    source_dir: str = ".",
) -> list[str]:
    """Copy entries created since ``before`` into the run's artifact directory.

    New files and directories (those present now but absent from ``before``) are
    copied into ``<run_dir>/generated_files/``. The destination directory is
    created only when there is at least one new entry to copy.

    Args:
        before: Entry names captured by :func:`snapshot_dir` prior to the run.
        run_dir: The run output directory; artifacts land under its
            ``generated_files`` subdirectory.
        source_dir: Directory the agent wrote into; defaults to the current
            working directory.

    Returns:
        The names of the entries that were copied.
    """
    after = snapshot_dir(source_dir)
    new_entries = after - before
    if not new_entries:
        return []

    gen_files_dir = os.path.join(run_dir, "generated_files")
    os.makedirs(gen_files_dir, exist_ok=True)

    copied: list[str] = []
    for name in new_entries:
        src = os.path.join(source_dir, name)
        dst = os.path.join(gen_files_dir, name)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True)
            copied.append(name)
        elif os.path.isfile(src):
            shutil.copy(src, dst)
            copied.append(name)

    _log.info("collected %d generated artifact(s) into %s", len(copied), gen_files_dir)
    return copied
