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

"""Registry for task definitions and task-type handlers."""

from __future__ import annotations

from devops_bench.core import Registry

__all__ = ["TASKS"]

#: Name-to-object registry for task definitions or task-type handlers. Register
#: with ``@TASKS.register("name")`` and look up with ``TASKS.get("name")``.
TASKS: Registry = Registry("tasks")
