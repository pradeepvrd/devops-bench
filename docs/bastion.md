# Eval-harness bastion (GCE)

A static Google Compute Engine VM that serves as the **execution environment for
the eval harness**. Use it when you can't run the agent CLI (openclaw / `oc`)
locally: you SSH into the bastion over IAP and run the whole harness there.

The harness drives `oc` as a **local subprocess** (the openclaw agent on the
refactor branch is local-only — the SSH transport was removed), so everything —
infra provisioning (tofu), the agent run (`oc`), and the judge — happens on the
VM.

The bastion is intentionally **generic and reusable**; secret-rotation is just
the first eval it runs.

## Architecture

```
You ──IAP SSH──> bastion VM "bench-bastion" (us-central1-a)
                   runs as openclaw-vm-sa  (ADC via the metadata server)
                   │
                   ├─ devops-bench CLI (the harness)
                   │    ├─ tofu apply  ->  GKE cluster + Secret Manager + ESO + app
                   │    ├─ oc agent --local   (openclaw performs the rotation)
                   │    │     └─ kubectl + gcloud + Secret Manager  (as the VM SA)
                   │    └─ judge (Gemini/Anthropic via API key)
                   └─ openclaw API key for the agent model
   (code pushed from your laptop via gcloud compute scp over IAP, subset only)
```

### Why this service account
The bastion runs as `openclaw-vm-sa@<project>.iam.gserviceaccount.com`. That is
**not arbitrary**: the secret-rotation tofu stack already references that exact
email — `tf/prebuilt/secret-rotation/cluster/main.tf` grants it
`roles/secretmanager.admin`, and `tf/modules/gke` grants the cluster's
`agent_service_account` `roles/container.admin` and opens an IAP-SSH firewall.
Nothing in those stacks *creates* the SA or a VM — this bastion fills that gap.
The SA id is the `sa_account_id` variable, so other harnesses can use a different
one.

The bastion SA also gets broad **provisioning** rights (`roles/editor` +
`roles/resourcemanager.projectIamAdmin` + `roles/iam.serviceAccountAdmin`) so the
harness can run the task's tofu (which creates GKE, secrets, service accounts, and
sets project/SA IAM bindings) *as this SA*. Tighten via `sa_roles` if needed; the
lazy alternative is `["roles/owner"]`.

## Files

| Path | Purpose |
|------|---------|
| `tf/modules/bastion/` | Reusable module: SA + IAM, the VM, the IAP-SSH firewall, `startup.sh`. |
| `tf/prebuilt/bastion/` | Concrete stack you `tofu apply`. |
| `scripts/bastion/sync-to-bastion.sh` | Push your local working tree (subset) to the VM. |
| `scripts/bastion/vm-setup.sh` | One-time per-user setup on the VM (venv + install + env). |

## 1. Provision the bastion

```bash
cd tf/prebuilt/bastion
tofu init
tofu apply -var project_id=<your-project>
```

Useful outputs: `iap_ssh_command`, `sa_email`. The VM's `startup.sh` installs the
toolchain on first boot (OpenTofu, gcloud + gke-gcloud-auth-plugin, kubectl,
Node 22, and `openclaw`, symlinked as `oc`); it touches
`/var/lib/bench-bastion-ready` when finished and logs to
`/var/log/bench-bastion-startup.log`.

Variables you may want: `name` (VM name, default `bench-bastion`), `zone`
(default `us-central1-a`), `machine_type` (default `e2-standard-4`),
`sa_account_id` (default `openclaw-vm-sa`), `assign_external_ip` (default `true`).

## 2. SSH in (over IAP)

```bash
gcloud compute ssh bench-bastion --zone us-central1-a --project <proj> --tunnel-through-iap
```

(the `iap_ssh_command` output prints this exact line). SSH ingress is restricted
to Google's IAP range (`35.235.240.0/20`); the external IP, if any, is for egress
only.

Sanity-check the toolchain:

```bash
cat /var/lib/bench-bastion-ready   # exists once startup finished
oc --version && tofu version && gcloud --version | head -1
kubectl version --client | head -1 && python3 --version && node --version
```

## 3. Ship your code + set up

From your laptop (reflects local, unpushed changes — only the needed subset is
sent):

```bash
scripts/bastion/sync-to-bastion.sh        # tars + scps over IAP into ~/devops-bench
```

By default this uses `gcloud compute ssh/scp --tunnel-through-iap`. In special
environments (e.g. Google corp hosts reachable directly at
`nic0.<vm>.<zone>.c.<project>.internal.gcpnode.com`) you can override the
transport without changing the default:

```bash
# Auto-build the gcpnode host from VM/zone/project, user defaults to <you>_google_com:
BASTION_USE_GCPNODE=1 scripts/bastion/sync-to-bastion.sh
# Or point at an explicit host / user:
BASTION_SSH_HOST=nic0.bench-bastion.us-central1-a.c.my-proj.internal.gcpnode.com \
  BASTION_SSH_USER=me_google_com scripts/bastion/sync-to-bastion.sh
```

Then on the VM, once:

```bash
~/devops-bench/scripts/bastion/vm-setup.sh   # venv + pip install .[all] + ~/bench.env
openclaw onboard                              # persist the agent model API key
```

`vm-setup.sh` writes a `~/bench.env` template. Fill in your project and judge key,
then `source ~/bench.env`.

> The harness does **not** pass an API key to `oc`. openclaw holds the agent
> model's key itself — set it with `openclaw onboard` (or a provider env var your
> openclaw build reads, e.g. `GEMINI_API_KEY`).

## 4. Run the secret-rotation eval

```bash
cd ~/devops-bench && source .venv/bin/activate
source ~/bench.env
devops-bench complextasks/secret-rotation/task.yaml
```

The harness provisions the GKE cluster + Secret Manager + External Secrets
Operator + the `db-secret-viewer` app, runs `oc agent --local` to rotate the
secret, judges the result, then tears the infra down.

Iterating: keep the cluster between runs with `export BENCH_NO_TEARDOWN=true` and
bump `NAMESPACE` per run; or skip provisioning entirely with `--no-infra`.

## Cost & security notes

- **Static VM** — it bills while it exists. `tofu destroy` in `tf/prebuilt/bastion`
  when you're done, or stop the instance between sessions.
- **SSH is IAP-only.** The optional external IP is egress-only; remove it
  (`-var assign_external_ip=false`) if your VPC has Cloud NAT.
- **Broad SA.** `openclaw-vm-sa` holds near-project-admin rights so it can
  provision eval infra. Keep it in a non-production / sandbox project. The agent's
  model key lives in openclaw's config on the VM (per your chosen API-key auth);
  promoting it to Secret Manager is a tracked follow-up.
