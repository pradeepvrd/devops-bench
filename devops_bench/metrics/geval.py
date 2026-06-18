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

"""Provider-agnostic DeepEval judge backed by the models layer."""

from __future__ import annotations

import asyncio

from deepeval.models import DeepEvalBaseLLM

from devops_bench.core import get_env, get_logger
from devops_bench.models import LLMClient, get_model

__all__ = ["ModelLayerJudge", "get_judge_model"]

_log = get_logger("metrics.geval")


class ModelLayerJudge(DeepEvalBaseLLM):
    """DeepEval judge that routes generation through the models layer.

    The legacy judges instantiated provider SDKs (``google.genai`` /
    ``anthropic``) directly. This wrapper instead holds an
    :class:`~devops_bench.models.LLMClient` obtained from
    :func:`~devops_bench.models.get_model`, so the judge is agnostic to the
    underlying provider. Judge prompts are text-only: generation issues a single
    user turn with no tools and returns the response's text content.

    Args:
        client: Pre-built LLM client to wrap. When omitted, one is constructed
            from ``provider``/``model_name`` (or the ``JUDGE_PROVIDER`` /
            ``JUDGE_MODEL`` environment variables) via ``get_model``.
        provider: Provider key forwarded to ``get_model`` when ``client`` is not
            supplied. Falls back to the ``JUDGE_PROVIDER`` environment variable.
        model_name: Model override forwarded to ``get_model`` when ``client`` is
            not supplied. Falls back to the ``JUDGE_MODEL`` environment variable.
    """

    def __init__(
        self,
        client: LLMClient | None = None,
        *,
        provider: str | None = None,
        model_name: str | None = None,
    ) -> None:
        if client is None:
            provider = provider or get_env("JUDGE_PROVIDER")
            model_name = model_name or get_env("JUDGE_MODEL")
            client = get_model(provider=provider, model_name=model_name)
        self.client = client
        # Mirror the adapter's resolved model name so DeepEval can label results.
        self._model_name = model_name or getattr(client, "model_name", None) or "judge"

    def load_model(self) -> LLMClient:
        """Return the wrapped LLM client (DeepEval contract)."""
        return self.client

    async def a_generate(self, prompt: str) -> str:
        """Generate judge text for ``prompt`` asynchronously.

        Args:
            prompt: The fully rendered judge prompt.

        Returns:
            The model's text response, or an empty string when none was produced.
        """
        response = await self.client.generate_content(
            contents=[{"role": "user", "content": prompt}],
            tools=None,
            system_instruction=None,
        )
        return self.client.get_text_content(response) or ""

    def generate(self, prompt: str) -> str:
        """Generate judge text for ``prompt`` synchronously.

        Runs the async :meth:`a_generate` to completion. Must not be called from
        within a running event loop.

        Args:
            prompt: The fully rendered judge prompt.

        Returns:
            The model's text response, or an empty string when none was produced.
        """
        return asyncio.run(self.a_generate(prompt))

    def get_model_name(self) -> str:
        """Return the configured judge model name (DeepEval contract)."""
        return self._model_name


def get_judge_model(
    provider: str | None = None, model_name: str | None = None
) -> ModelLayerJudge:
    """Build the default judge model from configuration.

    Args:
        provider: Provider key; falls back to ``JUDGE_PROVIDER``.
        model_name: Model override; falls back to ``JUDGE_MODEL``.

    Returns:
        A :class:`ModelLayerJudge` wrapping the selected provider's client.
    """
    return ModelLayerJudge(provider=provider, model_name=model_name)
