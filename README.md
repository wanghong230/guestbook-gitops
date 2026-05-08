# guestbook-gitops

GitOps repo that promotes `mirror.gcr.io/library/busybox` versions through
three environments across two clusters using Argo CD for sync and Kargo for
promotion. (We use Google's pull-through cache `mirror.gcr.io/library/*`
instead of `docker.io/library/*` to avoid Docker Hub's anonymous pull rate
limit.) The Deployment runs a busybox echo loop that prints the current
`RELEASE_ID` (produced by the per-promotion terraform run) every 10 seconds.

## Layout

```
guestbook-gitops/
├── apps/guestbook/
│   ├── base/                       # Deployment (busybox echo loop) + nominal Service
│   └── overlays/
│       ├── dev/                    # ns: guestbook-dev,    1 replica
│       ├── staging/                # ns: guestbook-staging, 2 replicas
│       └── prod/                   # ns: guestbook-prod,    3 replicas
├── argocd/
│   ├── projects/                   # AppProject "guestbook"
│   ├── clusters/                   # Cluster Secrets (skip on Akuity Platform)
│   └── applications/
│       ├── 00-app-of-apps.yaml     # Parent — apply once; syncs the rest
│       ├── 10-custom-steps.yaml    # → kargo/custom-steps/ on local-nonprod
│       ├── 11-verification.yaml    # → verification/ on local-nonprod
│       ├── guestbook-dev.yaml      # → stage/dev branch
│       ├── guestbook-staging.yaml  # → stage/staging branch
│       └── guestbook-prod.yaml     # → stage/prod branch
├── policies/
│   └── guestbook-max-replicas.yaml # Kyverno ClusterPolicy: dev/staging ≤20, prod ≤100
├── terraform/
│   └── release-marker/             # Placeholder OpenTofu module — runs every promotion
├── verification/
│   ├── analysistemplate-verify-release-echo.yaml  # Argo Rollouts AnalysisTemplate
│   └── rbac.yaml                                  # SA + ClusterRole + binding for the AT Job
├── kargo/
│   ├── project.yaml                # Kargo Project + Git creds Secret
│   ├── warehouse.yaml              # Subscribes to image + git
│   ├── custom-steps/               # Cluster-scoped CustomPromotionStep
│   │   └── kyverno-validate.yaml
│   ├── promotion-tasks/            # Reusable promotion logic (PromotionTask)
│   │   └── kustomize-promote.yaml
│   └── stages/                     # dev → staging → prod
└── .github/workflows/
    └── kargo-apply.yml             # CI: kargo apply on push for project content
```

## How writes flow (rendered-manifest pattern)

`main` is owned by humans. Kargo never writes back to `main`. Each stage has
its own branch where Kargo pushes the **fully rendered** Kubernetes YAML:

```
main                source manifests + Kustomize bases/overlays
stage/dev           kustomize-build output for dev (one manifests.yaml)
stage/staging       kustomize-build output for staging
stage/prod          kustomize-build output for prod
```

A promotion clones BOTH branches into the same pod (`./src` and `./out`),
edits `./src` only in-memory, runs `kustomize-build` to write the result
into `./out/manifests.yaml`, then commits and pushes `./out` only — the
stage branch — never `main`. So:

- A dev promotion can't accidentally touch staging or prod.
- `git log stage/prod -p` is your audit log of what's running in prod.
- Manual edits to `main` no longer race against Kargo's writes.

## Promotion template

The three Stages share a single `PromotionTask` (`kargo/promotion-tasks/kustomize-promote.yaml`)
rather than each carrying its own copy of the steps. The task uses
`${{ ctx.stage }}` to pick the matching overlay
(`apps/guestbook/overlays/${{ ctx.stage }}`) and Argo CD app
(`guestbook-${{ ctx.stage }}`), so each `Stage` resource only has to declare
its upstream Freight source — the step list collapses to:

```yaml
promotionTemplate:
  spec:
    steps:
      - task:
          name: kustomize-promote
```

To override the repo URL or image for one Stage, pass step-level vars on the
task reference (see the Promotion Tasks reference for syntax).

## Replica-cap validation (Kyverno)

The promotion task renders the overlay with `kustomize-build` and then runs a
custom step (`kyverno-validate`) that invokes the Kyverno CLI against
`policies/guestbook-max-replicas.yaml`. The policy carries one rule per Stage
namespace:

| Stage     | Namespace          | Max replicas |
|-----------|--------------------|--------------|
| dev       | guestbook-dev      | 20           |
| staging   | guestbook-staging  | 20           |
| prod      | guestbook-prod     | 100          |

If the rendered Deployment violates the cap, Kyverno exits non-zero, the
custom step fails, and the promotion stops **before** anything is committed,
pushed, or synced — the bad replica count never reaches the cluster.

Requirements (per the Kargo docs):

- `CustomPromotionStep` is an **Akuity Platform (Kargo EE) v1.10+** feature,
  currently alpha.
- The Promotion Controller and a self-hosted agent must be enabled.
- `kargo/custom-steps/kyverno-validate.yaml` is **cluster-scoped** — a Kargo
  cluster admin must apply it once.

To change a cap, edit `policies/guestbook-max-replicas.yaml` directly. To add
another check (image registry allowlist, resource limits, etc.), add a rule
to the same file or a sibling policy under `policies/`.

## Cloud-resource provisioning (placeholder)

Each promotion runs `tf-apply` against `terraform/release-marker/`, a real
OpenTofu module that today only uses zero-cred providers (`random` +
built-in `terraform_data`). It produces a stable `release_id` for the
`(stage, image_tag)` pair and exposes it to subsequent steps via
`tf-output`. State is local and ephemeral — fine for a placeholder, **not**
fine the moment a real cloud resource lands here.

The `tf-apply` step sits before `git-commit`, so a terraform failure stops
the promotion before anything is committed, pushed, or synced (same
fail-closed posture as the Kyverno gate).

To evolve this into actual provisioning, see the README inside
`terraform/release-marker/` — short version: add a remote backend, add real
provider blocks, replace `terraform_data.marker` with real resources, and
uncomment the commented-out `env:` block in
`kargo/promotion-tasks/kustomize-promote.yaml` to wire credentials via
`secret('aws-creds').…` expressions.

`tf-apply` is an Akuity Platform / Kargo EE feature (v1.9+) and requires the
Promotion Controller — same operational story as the Kyverno custom step.

### Threading `release_id` into the running Pod

The Deployment's single container is busybox running a 10-second echo loop:

```yaml
containers:
  - name: guestbook
    image: mirror.gcr.io/library/busybox:1.36   # newTag rewritten per promotion
    command: ["/bin/sh", "-c"]
    args: ["while true; do echo \"release: $RELEASE_ID\"; sleep 10; done"]
    env:
      - name: RELEASE_ID
        value: "unset"   # base default; overlay overrides this
```

After `tf-output` captures `release_id`, the promotion runs `yaml-update`
to write the value into the per-overlay `release-info-patch.yaml`, which
strategic-merges its `RELEASE_ID` env onto the base container (env entries
are merged by `name`, so only that one variable changes). On every
promotion the env value flips → Deployment spec changes → Argo CD rolls
the Pods → busybox starts emitting the new ID.

To watch it:

```bash
kubectl logs -n guestbook-dev deploy/guestbook -f
```

Each promoted busybox tag (1.36 → 1.36.1 → 1.37.0 …) is what Kargo's
Warehouse picks up — image promotion and release-marker propagation
happen in the same pipeline.

## Post-deploy verification (AnalysisTemplate)

After every successful promotion to a Stage, Kargo creates an `AnalysisRun`
from `verification/analysistemplate-verify-release-echo.yaml` (an Argo
Rollouts `AnalysisTemplate` re-used by Kargo). The Freight is only marked
"verified in this Stage" if the AnalysisRun ends `Successful`. Downstream
Stages refuse Freight that hasn't been verified upstream, so a failed
verification stops the pipeline immediately.

How the expected value is plumbed:

1. The promotion task's last step is `set-metadata`, which stamps the
   `release_id` (output of `tf-output`) onto the Stage's metadata.
2. Each Stage's `verification.args` reads it back via
   `${{ stageMetadata(ctx.stage).release_id }}` and passes it to the
   AnalysisTemplate as `expected_release_id`.
3. Inside the AnalysisTemplate (Argo Rollouts syntax: single braces, no
   `$`) the value lands in the verification Job as `{{ args.expected_release_id }}`.
4. The Job runs `kubectl rollout status`, sleeps one echo cycle, then
   `kubectl logs deploy/guestbook | grep -F "release: $EXPECTED"`.
   Exit 0 → AnalysisRun pass → freight verified. Otherwise fail.

The Job runs in the `akuity` namespace (where the self-hosted Kargo
agent materializes AnalysisRuns). The `ClusterRoleBinding` in
`verification/rbac.yaml` grants cluster-wide read access on `pods`,
`pods/log`, and `deployments` to two ServiceAccounts in `akuity`:
`kargo-verify` (the explicitly-named one) and `default` (the one the
AnalysisRun pod actually runs as today, because Kargo's verification
controller doesn't propagate the AnalysisTemplate's `serviceAccountName`
to the Job pod). If your security model demands per-namespace
bindings, swap the single `ClusterRoleBinding` for three `RoleBinding`s
in the `guestbook-{dev,staging,prod}` namespaces.

Inspecting verification:

```bash
# List analysis runs in the project namespace
kubectl -n guestbook get analysisruns

# Stage metadata — what the verification compared against
kubectl -n guestbook get stage dev -o jsonpath='{.status.metadata}'

# If a run failed, find its Job pod and read the logs
kubectl -n guestbook get analysisrun -o name | xargs -I{} kubectl -n guestbook describe {}
```

What this catches: stale Argo CD sync, a busted `yaml-update`, manual
overrides on a live Deployment, anything that prevents the new
`RELEASE_ID` from showing up in the Pod logs.

## Cluster topology

| Stage     | Argo CD cluster name | Namespace          |
|-----------|----------------------|--------------------|
| dev       | local-nonprod        | guestbook-dev      |
| staging   | local-nonprod        | guestbook-staging  |
| prod      | local-prod           | guestbook-prod     |

## Promotion flow

1. A new busybox tag is published (e.g. `1.37.0`) to Docker Hub.
2. Kargo's `Warehouse` discovers it and produces new Freight.
3. The `dev` Stage auto-promotes: it clones the repo, runs `kustomize edit
   set image` against `apps/guestbook/overlays/dev`, applies the terraform
   release-marker module to mint a fresh `release_id`, stamps it into
   `release-info-patch.yaml`, validates against the Kyverno replica caps,
   commits, pushes, and tells Argo CD to sync `guestbook-dev`.
4. After dev observation, you promote the same Freight to `staging` —
   identical pipeline, different overlay.
5. Same for `prod`, which targets the `local-prod` cluster.

Each Stage only accepts Freight from the prior stage, so you can't skip
straight from a fresh image to prod.

## Bootstrap

Two control-plane setups happen separately because they target different
APIs (Akuity Platform doesn't expose a Kubernetes API for Kargo's project
content):

```
            ┌─ Argo CD (Akuity-managed) ──┐    ┌─ Kargo (Akuity-managed) ─┐
            │                             │    │                          │
manifests   │  app-of-apps Application    │    │  Project, Warehouse,     │
in this    →│  child Applications, one    │    │  PromotionTask, Stages   │
repo        │  per concern (control-plane │    │  applied via             │
            │  pieces + per-stage apps)   │    │  `kargo apply`           │
            └─────────────────────────────┘    └──────────────────────────┘
                       Argo CD syncs                  CI workflow runs
                       on every commit                on every commit to
                       (continuous reconciliation)    paths under kargo/*
```

### Argo CD side — once, then continuous

```bash
# Apply the parent Application. From here on, Argo CD owns everything in
# argocd/applications/ — edits in main propagate automatically.
argocd app create -f argocd/applications/00-app-of-apps.yaml
# (or `kubectl apply -f` against the Argo CD control plane if you prefer)
```

The parent will create:

- `guestbook-custom-steps`  → `kargo/custom-steps/`  on `local-nonprod`
- `guestbook-verification`  → `verification/`        on `local-nonprod`
- `guestbook-dev`           → `stage/dev` branch     on `local-nonprod`
- `guestbook-staging`       → `stage/staging` branch on `local-nonprod`
- `guestbook-prod`          → `stage/prod` branch    on `local-prod`

### Kargo side — via CI

`.github/workflows/kargo-apply.yml` runs `kargo apply` against your
Akuity-hosted Kargo instance on every push that touches `kargo/project.yaml`,
`kargo/warehouse.yaml`, `kargo/stages/`, or `kargo/promotion-tasks/`. Set
these secrets in the GitHub repo settings before the first push:

- `AKUITY_API_KEY_ID`, `AKUITY_API_KEY_SECRET` — Owner-role API key.
- `AKUITY_ORGANIZATION` — your Akuity org name.
- `KARGO_INSTANCE_URL` — `https://<id>.kargo.akuity.cloud`.
- `KARGO_ADMIN_PASSWORD` — admin password set via Akuity UI.

To apply manually without a push, trigger the workflow from the Actions
tab (`Run workflow` button on `kargo-apply`).

### Placeholders to fill before first run

- `kargo/project.yaml` — replace the `gitops-repo-creds` username/password
  with a real GitHub PAT. **Don't commit it**: only inject the live value at
  apply time, or move the Secret out of git entirely and create it via
  `kargo create credentials …` from your terminal.
- `argocd/clusters/*-secret.yaml` — only relevant if you self-host Argo CD.
  On Akuity Platform, `akuity argocd cluster create …` handles registration
  and these placeholder Secrets are unused.
- `argocd/applications/*.yaml` — `spec.source.repoURL` if you forked.

### First promotion creates the stage branches

The PromotionTask's `git-clone` uses `create: true` for the stage branch.
On the very first promotion to dev/staging/prod, the `stage/<env>` branch
is created from an empty working tree, populated with `manifests.yaml`, and
pushed. From then on each promotion is a fast-forward commit on the
existing branch.

## Testing the manifests locally

```bash
kubectl kustomize apps/guestbook/overlays/dev
kubectl kustomize apps/guestbook/overlays/staging
kubectl kustomize apps/guestbook/overlays/prod

# Dry-run the same Kyverno check the promotion will run
for env in dev staging prod; do
  kubectl kustomize apps/guestbook/overlays/$env > /tmp/rendered-$env.yaml
  kyverno apply policies/guestbook-max-replicas.yaml --resource /tmp/rendered-$env.yaml
done

# Dry-run the placeholder terraform module
cd terraform/release-marker
terraform init
terraform apply -var=stage=dev -var=image_tag=v0.0.0-local
terraform output
cd -
```

## Notes

- Overlays pin `mirror.gcr.io/library/busybox:1.36` as a stable default.
  With the rendered-manifest pattern Kargo no longer rewrites `newTag` in
  `main`; the actual deployed tag lives in each `stage/<env>` branch's
  `manifests.yaml`.
- The `Service` is nominal — busybox doesn't actually serve HTTP, so its
  endpoints will be empty. Swap to a real server image (or add an `httpd
  -f -p 80` sidecar) if you need a working ClusterIP.
- `dev` is set to auto-promote; `staging` and `prod` require an explicit
  promotion (a `Promotion` resource, the Kargo UI button, or `kargo promote`).
- Each Argo CD `Application` carries `kargo.akuity.io/authorized-stage` so
  only the corresponding Stage can drive it.
