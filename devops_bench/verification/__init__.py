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

"""Type-safe verification engine for validating cluster state."""

from devops_bench.verification.base import BaseVerifier, VerificationResult
from devops_bench.verification.runner import VerifierAgent
from devops_bench.verification.spec import VerificationSpec

__all__ = [
    "BaseVerifier",
    "VerificationResult",
    "VerificationSpec",
    "VerifierAgent",
]
