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

"""Delete the Secret holding this program, as the change's last act.

Nothing in the cluster is hidden from a run by RBAC. living-stacks' bench_agent
scopes carefully, one Role per edit namespace, but the bench then binds the
solver ServiceAccount to the built-in "edit" ClusterRole across the whole
cluster (devops_bench/k8s/agent_credentials.py), and edit carries secrets,
pods/exec and delete in every namespace. Verified live with
`kubectl auth can-i --as`.

So the program's text cannot be hidden. It can only be gone. This removes it
once it has finished being useful, which is before the solver's turn starts.

The leak this closes was measured: as a ConfigMap beside the database, a live
solver read the Job's output and was handed the cause, the mechanism and the
confirmation in one command, then solved the task.

Failure to delete is fatal on purpose. A change window that leaves its own
instructions lying around is the defect, not a tidiness lapse, and failing here
fails the Job and so the apply.
"""

from __future__ import annotations

import os
import ssl
import sys
import urllib.error
import urllib.request

ROOT = "/var/run/secrets/kubernetes.io/serviceaccount"
NAMESPACE = os.environ["RECORDS_NAMESPACE"]
SECRET = "orders-maintenance-program"


def main() -> int:
    with open(f"{ROOT}/token") as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=f"{ROOT}/ca.crt")
    url = f"https://kubernetes.default.svc/api/v1/namespaces/{NAMESPACE}/secrets/{SECRET}"
    req = urllib.request.Request(url, method="DELETE")
    req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30, context=ctx):
            pass
    except urllib.error.HTTPError as exc:
        # Already gone is the desired end state, not a failure.
        if exc.code != 404:
            print(f"could not remove the program: {exc}", flush=True)
            return 1
    print("program retired", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
