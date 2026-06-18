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

"""API/MCP agent harness driving a model-agnostic tool-use loop.

The concrete harness lives in :mod:`devops_bench.agents.api.loop` and
self-registers under ``"api"`` via ``@AGENTS.register``. That module and
:mod:`devops_bench.agents.api.mcp` pull in heavy optional dependencies (the
``mcp`` SDK, ``deepeval``), so import the specific module when the agent is
selected rather than relying on this package importing them eagerly.
"""

from __future__ import annotations
