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

"""Discriminated-union schema describing a verification specification."""

from __future__ import annotations

from pydantic import RootModel

from devops_bench.verification.verifiers.pod_healthy import PodHealthyVerifier
from devops_bench.verification.verifiers.scaling_complete import ScalingCompleteVerifier

__all__ = ["SingleVerificationSpec", "VerificationSpec"]

# A single check, discriminated on its literal ``type`` field. Extend this union
# (and only this union) to register a new verifier.
SingleVerificationSpec = PodHealthyVerifier | ScalingCompleteVerifier


class VerificationSpec(
    RootModel[
        dict[str, SingleVerificationSpec]
        | list[SingleVerificationSpec]
        | SingleVerificationSpec
    ]
):
    """A structured verification spec: a single check, a list, or a named dict.

    Lists run their members in sequence; dicts run named members and map each
    result back to its key. Both are evaluated recursively by
    :class:`~devops_bench.verification.runner.VerifierAgent`.
    """
