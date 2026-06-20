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

"""Typed configuration for the agent harness."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field

from devops_bench.core import get_env, get_int

__all__ = ["AgentConfig"]


def _parse_csv(raw: str | None) -> tuple[str, ...]:
    """Split a comma-separated env value into a tuple, skipping blanks."""
    if not raw:
        return ()
    return tuple(item.strip() for item in raw.split(",") if item.strip())


@dataclass
class AgentConfig:
    """Typed configuration for an agent run.

    All optional fields default to ``None`` / empty so a bare ``AgentConfig()``
    represents "use the agent's built-in defaults". :meth:`from_env` is the one
    place that reads ``AGENT_*`` environment variables; agents themselves stop
    self-reading the environment.

    Attributes:
        model: Optional model id; flows from ``AGENT_MODEL``.
        provider: Optional provider key (``gemini``/``anthropic``/``ollama``/...);
            flows from ``AGENT_PROVIDER``.
        api_key: Optional API key delivered to provider-specific env vars by the
            concrete agent; flows from ``AGENT_API_KEY``.
        target: Optional path / endpoint for the underlying agent binary or
            service; flows from ``AGENT_TARGET``. CLI agents resolve their
            binary path from this when present.
        timeout_sec: Wall-clock seconds before an external call is aborted; the
            base harness threads this into every subprocess invocation. ``None``
            disables the timeout (use only for tests / local debug).
        allowed_tools: Names of tools the agent may invoke. PR1 interim field
            (CSV-parsed from ``AGENT_ALLOWED_TOOLS``); PR3 migrates this into
            ``McpBinding.tools`` supplied by the orchestrator catalog and this
            field is removed.
        skills_paths: Filesystem locations to discover local skill files
            (``SKILL.md``) the API agent exposes as synthetic tools. PR2 interim
            field (CSV-parsed from ``AGENT_SKILLS_PATHS``); PR3 migrates this
            into ``SkillBinding.paths`` and the field is removed. Skills are
            decoupled from MCP: an agent may have skills without MCP and vice
            versa.
        max_turns: Safety cap on the API agent's tool-use loop turns; flows from
            ``AGENT_MAX_TURNS``. ``None`` uses the agent's built-in default.
        extra_env: Provider-agnostic env overlay forwarded to subprocess calls.
            Concrete agents may add their own provider-specific keys on top.
    """

    model: str | None = None
    provider: str | None = None
    api_key: str | None = None
    target: str | None = None
    timeout_sec: float | None = 600.0
    allowed_tools: tuple[str, ...] = ()
    skills_paths: tuple[str, ...] = ()
    max_turns: int | None = None
    extra_env: Mapping[str, str] = field(default_factory=dict)

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> AgentConfig:
        """Build a config from the ``AGENT_*`` environment variables.

        Reads ``AGENT_MODEL`` / ``AGENT_PROVIDER`` / ``AGENT_API_KEY`` /
        ``AGENT_TARGET`` / ``AGENT_TIMEOUT_SEC`` / ``AGENT_ALLOWED_TOOLS`` /
        ``AGENT_SKILLS_PATHS`` / ``AGENT_MAX_TURNS``. A missing variable yields
        the dataclass default — this method never raises on unset variables.

        Args:
            env: Optional mapping to read from (defaults to ``os.environ``).
                Tests inject a dict here to avoid mutating the process env.

        Returns:
            A populated :class:`AgentConfig`.
        """
        timeout = get_int("AGENT_TIMEOUT_SEC", env=env)
        max_turns = get_int("AGENT_MAX_TURNS", env=env)
        return cls(
            model=get_env("AGENT_MODEL", env=env),
            provider=get_env("AGENT_PROVIDER", env=env),
            api_key=get_env("AGENT_API_KEY", env=env),
            target=get_env("AGENT_TARGET", env=env),
            timeout_sec=float(timeout) if timeout is not None else 600.0,
            allowed_tools=_parse_csv(get_env("AGENT_ALLOWED_TOOLS", env=env)),
            skills_paths=_parse_csv(get_env("AGENT_SKILLS_PATHS", env=env)),
            max_turns=max_turns,
        )
