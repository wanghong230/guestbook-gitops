# guestbook-gitops

GitOps repo to deploy `quay.io/guestbook` to three environments across two
clusters using Argo CD for sync and Kargo for promotion.

## Layout

```
guestbook-gitops/
├── apps/guestbook/
│   ├── base/                       # Deployment + Service (image: quay.io/guestbook)
│   └── overlays/
│       ├── dev/                    # ns: guestbook-dev,    1 replica
│       ├── staging/                # ns: guestbook-staging, 2 replicas
│       └── prod/                   # ns: guestbook-prod,    3 replicas
├── argocd/
│   ├── projects/                   # AppProject "guestbook"
│   ├── clusters/                   # Cluster Secrets for local-nonprod, local-prod
│   └── applications/               # 3 Argo CD Applications, one per overlay
├── policies/
│   └── guestbook-max-replicas.yaml # Kyverno ClusterPolicy: dev/staging ≤20, prod ≤100
├── terraform/
│   └── release-marker/             # Placeholder OpenTofu module — runs every promotion
└── kargo/
    ├── project.yaml                # Kargo Project + Git creds Secret
    ├── warehouse.yaml              # Subscribes to image + git
    ├── custom-steps/               # Cluster-scoped CustomPromotionStep registrations
    │   └── kyverno-validate.yaml   #   runs `kyverno apply` on rendered manifests
    ├── promotion-tasks/            # Reusable promotion logic (PromotionTask)
    │   └── kustomize-promote.yaml  #   clone → set-image → build → kyverno → tf-apply → commit → push → sync
    └── stages/                     # dev → staging → prod (each just references the task)
```

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

## Cluster topology

| Stage     | Argo CD cluster name | Namespace          |
|-----------|----------------------|--------------------|
| dev       | local-nonprod        | guestbook-dev      |
| staging   | local-nonprod        | guestbook-staging  |
| prod      | local-prod           | guestbook-prod     |

## Promotion flow

1. CI pushes a new immutable tag (e.g. `v1.4.2`) to `quay.io/guestbook`.
2. Kargo's `Warehouse` discovers the tag and produces new Freight.
3. The `dev` Stage auto-promotes (per `promotionPolicies` in `kargo/project.yaml`):
   it clones the repo, runs `kustomize edit set image` against
   `apps/guestbook/overlays/dev`, commits, pushes, and tells Argo CD to sync
   `guestbook-dev`.
4. After dev verification, you (or an automated check) promote that Freight to
   `staging` — same pattern, against the staging overlay.
5. Same for `prod`, which targets the `local-prod` cluster.

Each Stage only accepts Freight from the prior stage, so you can't skip
straight from a fresh image to prod.

## Bootstrap

Replace every `REPLACE_ME` / `REPLACE-WITH-...` placeholder first, then:

```bash
# 1. Argo CD: project, cluster Secrets, Applications
kubectl apply -f argocd/projects/
kubectl apply -f argocd/clusters/
kubectl apply -f argocd/applications/

# 2. Kargo cluster admin (one-time): register the custom step
kubectl apply -f kargo/custom-steps/

# 3. Kargo project: git creds, warehouse, promotion task, stages
kubectl apply -f kargo/project.yaml
kubectl apply -f kargo/warehouse.yaml
kubectl apply -f kargo/promotion-tasks/
kubectl apply -f kargo/stages/
```

Placeholders to fill:
- `argocd/clusters/*-secret.yaml` — API server URL, bearer token, CA bundle.
- `argocd/applications/*.yaml` — `spec.source.repoURL` (your fork of this repo).
- `kargo/project.yaml` — git PAT under `gitops-repo-creds`, plus `repoURL`.
- `kargo/warehouse.yaml` and `kargo/promotion-tasks/kustomize-promote.yaml` —
  `repoURL` defaults (same value across the file).

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

- Overlays pin `quay.io/guestbook:latest` only as a starting point. Kargo
  rewrites `images[0].newTag` on each promotion, so the in-tree value drifts
  to the most recently promoted tag for each environment.
- `dev` is set to auto-promote; `staging` and `prod` require an explicit
  promotion (a `Promotion` resource, the Kargo UI button, or `kargo promote`).
- Each Argo CD `Application` carries `kargo.akuity.io/authorized-stage` so
  only the corresponding Stage can drive it.
