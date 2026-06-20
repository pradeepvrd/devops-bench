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

"""Unit tests for devops_bench.agents.cli.openclaw."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

from devops_bench.agents import AGENTS, AgentConfig
from devops_bench.agents.cli import openclaw as oc_mod
from devops_bench.agents.cli.openclaw import (
    OpenClawAgent,
    _build_local_command,
    _oc_model_id,
    _pick_session_key,
    _strip_ansi,
    parse_trajectory_export,
)
from devops_bench.core.errors import SubprocessError


def _trajectory_jsonl(*entries: dict) -> str:
    return "\n".join(json.dumps(e) for e in entries) + "\n"


SAMPLE_TRAJECTORY = _trajectory_jsonl(
    {
        "type": "tool_call",
        "id": "1",
        "name": "kubectl_get_pods",
        "args": {"namespace": "default"},
    },
    {"type": "tool_result", "id": "1", "output": "pod-a Running\n"},
    {"type": "message", "usage": {"input_tokens": 5, "output_tokens": 10}},
    {
        "type": "tool_call",
        "id": "2",
        "name": "kubectl_describe",
        "args": {"resource": "pod/pod-a"},
    },
    {"type": "tool_result", "id": "2", "output": "Phase: Running", "is_error": False},
)


def test_parse_trajectory_export_folds_call_result_pairs():
    trajectory, tokens, errors = parse_trajectory_export(SAMPLE_TRAJECTORY)
    assert errors == []
    assert tokens == {"input_tokens": 5, "output_tokens": 10}
    assert trajectory == [
        {
            "name": "kubectl_get_pods",
            "args": {"namespace": "default"},
            "result": "pod-a Running\n",
            "status": "completed",
        },
        {
            "name": "kubectl_describe",
            "args": {"resource": "pod/pod-a"},
            "result": "Phase: Running",
            "status": "completed",
        },
    ]


def test_parse_trajectory_export_surfaces_decode_errors():
    blob = "{not json}\n" + json.dumps({"type": "tool_call", "id": "1", "name": "x", "args": {}}) + "\n"
    trajectory, _tokens, errors = parse_trajectory_export(blob)
    assert any("parse error" in m for m in errors)
    assert len(trajectory) == 1


def test_parse_trajectory_export_keeps_unpaired_result_as_synthetic_entry():
    blob = _trajectory_jsonl(
        {"type": "tool_result", "id": "ghost", "output": "?"}
    )
    trajectory, _tokens, errors = parse_trajectory_export(blob)
    assert any("without matching call" in m for m in errors)
    assert trajectory and trajectory[0]["status"] == "completed"
    assert trajectory[0]["result"] == "?"


def test_strip_ansi_removes_color_codes():
    assert _strip_ansi("\x1b[31mhello\x1b[0m") == "hello"


def test_oc_model_id_normalizes_provider_alias():
    assert _oc_model_id(AgentConfig(model="gemini-2.5-pro", provider="gemini")) == (
        "google/gemini-2.5-pro"
    )


def test_oc_model_id_preserves_full_id():
    assert _oc_model_id(AgentConfig(model="anthropic/claude-opus-4-7")) == (
        "anthropic/claude-opus-4-7"
    )


def test_oc_model_id_returns_empty_when_no_model():
    assert _oc_model_id(AgentConfig()) == ""


def test_oc_model_id_defaults_to_google():
    assert _oc_model_id(AgentConfig(model="gemini-2.5-pro")) == "google/gemini-2.5-pro"


def test_build_local_command_quotes_inputs_and_includes_model_set():
    cfg = AgentConfig(model="gemini-2.5-pro", provider="gemini")
    cmd = _build_local_command(cfg, "hi 'world'", "operator", "/usr/local/bin/oc")
    # Prompt single-quote must be escaped, not break the shell line.
    assert "hi '\\''world'\\''" in cmd or "hi 'world'" not in cmd
    assert "rm -rf" in cmd  # sessions wipe
    assert "NVM_DIR" in cmd  # nvm sourced for the node runtime
    # shlex.quote leaves alnum/`/`/`-`/`.` un-quoted; just match the canonical id.
    assert "models set google/gemini-2.5-pro" in cmd
    assert "agent --local" in cmd
    assert "--agent operator" in cmd


def test_build_local_command_omits_model_set_when_no_model_configured():
    cmd = _build_local_command(AgentConfig(), "prompt", "operator", "/usr/local/bin/oc")
    assert "models set" not in cmd


def test_pick_session_key_handles_top_level_list():
    payload = json.dumps([{"key": "agent:operator:abc", "model": "x"}])
    assert _pick_session_key(payload) == "agent:operator:abc"


def test_pick_session_key_handles_wrapper_dict():
    payload = json.dumps({"sessions": [{"key": "k1"}, {"key": "k2"}]})
    assert _pick_session_key(payload) == "k1"


def test_pick_session_key_returns_none_on_empty_or_invalid():
    assert _pick_session_key("") is None
    assert _pick_session_key("{}") is None
    assert _pick_session_key(json.dumps({"sessions": []})) is None
    assert _pick_session_key(json.dumps([{"no_key": "x"}])) is None


def test_openclaw_agent_registered_under_canonical_key():
    assert AGENTS.get("openclaw") is OpenClawAgent


def _make_subprocess_result(stdout: str = "", stderr: str = "", returncode: int = 0):
    return SimpleNamespace(stdout=stdout, stderr=stderr, returncode=returncode)


def test_execute_happy_path_emits_canonical_trajectory(monkeypatch, tmp_path):
    """oc agent succeeds, oc sessions yields one row, export-trajectory parses cleanly."""

    sessions_payload = json.dumps([{"key": "agent:operator:test", "model": "google/gemini-2.5-pro"}])

    # bash subprocess: capture the command, return success.
    def fake_bash(cmd, **kwargs):
        return _make_subprocess_result(stdout="OK\nsessionFile=/tmp/ignored.jsonl\n", returncode=0)

    monkeypatch.setattr(subprocess, "run", fake_bash)

    # core.subprocess.run: dispatch on the second arg.
    def fake_core_run(argv, **kwargs):
        if argv[1] == "sessions" and "export-trajectory" not in argv:
            return _make_subprocess_result(stdout=sessions_payload, returncode=0)
        if "export-trajectory" in argv:
            ws = Path(argv[argv.index("--workspace") + 1])
            export_root = ws / ".openclaw" / "trajectory-exports" / "bundle"
            export_root.mkdir(parents=True, exist_ok=True)
            (export_root / "trajectory.jsonl").write_text(SAMPLE_TRAJECTORY)
            return _make_subprocess_result(stdout="exported", returncode=0)
        raise AssertionError(f"unexpected argv {argv}")

    monkeypatch.setattr(oc_mod, "run", fake_core_run)

    agent = OpenClawAgent(AgentConfig(target=str(tmp_path / "oc"), timeout_sec=30.0))
    result = agent.run("audit pods in default")
    assert result.errors == []
    assert len(result.trajectory) == 2
    assert result.trajectory[0]["name"] == "kubectl_get_pods"
    assert result.tokens == {"input_tokens": 5, "output_tokens": 10}
    assert result.output.startswith("OK")


def test_execute_records_when_sessions_returns_no_rows(monkeypatch, tmp_path):
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: _make_subprocess_result("ok", "", 0))

    def fake_core_run(argv, **kwargs):
        # oc sessions returns empty.
        return _make_subprocess_result(stdout=json.dumps([]), returncode=0)

    monkeypatch.setattr(oc_mod, "run", fake_core_run)

    result = OpenClawAgent(AgentConfig(target=str(tmp_path / "oc"))).run("p")
    assert result.has_errors()
    assert any("no session key" in e for e in result.errors)


def test_execute_records_export_subprocess_failure(monkeypatch, tmp_path):
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: _make_subprocess_result("ok", "", 0))

    def fake_core_run(argv, **kwargs):
        if "export-trajectory" in argv:
            raise SubprocessError(argv, returncode=1, stdout="", stderr="bad")
        return _make_subprocess_result(stdout=json.dumps([{"key": "k1"}]), returncode=0)

    monkeypatch.setattr(oc_mod, "run", fake_core_run)
    result = OpenClawAgent(AgentConfig(target=str(tmp_path / "oc"))).run("p")
    assert result.has_errors()
    assert any("export-trajectory failed" in e for e in result.errors)


def test_execute_records_bash_timeout(monkeypatch, tmp_path):
    def fake_bash(cmd, **kwargs):
        raise subprocess.TimeoutExpired(cmd=cmd, timeout=5.0)

    monkeypatch.setattr(subprocess, "run", fake_bash)
    result = OpenClawAgent(AgentConfig(target=str(tmp_path / "oc"), timeout_sec=5.0)).run("p")
    assert result.has_errors()
    assert "timed out" in result.errors[0]
    assert result.trajectory == []


def test_execute_passes_timeout_to_bash(monkeypatch, tmp_path):
    captured: dict = {}

    def fake_bash(cmd, **kwargs):
        captured.update(kwargs)
        return _make_subprocess_result("ok", "", 0)

    def fake_core_run(argv, **kwargs):
        return _make_subprocess_result(json.dumps([]), "", 0)

    monkeypatch.setattr(subprocess, "run", fake_bash)
    monkeypatch.setattr(oc_mod, "run", fake_core_run)
    OpenClawAgent(AgentConfig(target=str(tmp_path / "oc"), timeout_sec=12.5)).run("p")
    assert captured["timeout"] == 12.5


# Tests for the now-deleted legacy surface — fail-fast if SSH transport returns.

def test_legacy_ssh_runner_is_gone():
    assert not hasattr(oc_mod, "run_openclaw_agent")


def test_legacy_local_runner_is_gone():
    assert not hasattr(oc_mod, "run_openclaw_agent_local")
