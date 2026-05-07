# release-marker (placeholder)

OpenTofu / Terraform module invoked by the `kustomize-promote` Kargo
PromotionTask via `tf-apply`. Today it produces nothing of real value beyond a
random ID and a state record — it exists so that the promotion plumbing for
infrastructure provisioning is in place and exercised on every run.

## What it does today

1. Generates a `random_id` keyed on the current Stage and image tag, so the ID
   rotates whenever either input changes.
2. Records a "release marker" via a `terraform_data` resource (a built-in
   stateful no-op).
3. Exposes two outputs: `release_id` and `marker`.

No cloud providers, no credentials, no remote backend. Each promotion's apply
runs against a fresh local state in an ephemeral pod and is discarded.

## Inputs

| Variable    | Type   | Default   | Description                                         |
|-------------|--------|-----------|-----------------------------------------------------|
| `stage`     | string | required  | Kargo stage name (`dev`, `staging`, `prod`).        |
| `image_tag` | string | `"unset"` | Container image tag being promoted, from Freight.   |

## Outputs

| Output       | Description                                                 |
|--------------|-------------------------------------------------------------|
| `release_id` | Hex string for this (stage, image_tag) pair.                |
| `marker`     | Map: `{ release_id, stage, image_tag, note }`.              |

## How to evolve this into real provisioning

When you're ready to manage actual resources:

1. **Add a remote backend** in `versions.tf`. Local state in an ephemeral pod
   isn't durable. Examples are in the `versions.tf` comments (S3 + DynamoDB
   lock table, or `terraform { cloud { ... } }` for Terraform Cloud / Akuity
   Cloud Manager equivalents).
2. **Add cloud provider blocks** to `versions.tf` (`aws`, `azurerm`,
   `google`, etc.).
3. **Replace `terraform_data.marker`** with real resources
   (`aws_s3_bucket`, `azurerm_storage_account`, …).
4. **Pass credentials** through the `tf-apply` step's `env:` block in the
   PromotionTask, sourcing them with the `secret('...')` expression. The
   `kargo/promotion-tasks/kustomize-promote.yaml` file has comments showing
   where to add them.
5. **Tighten the IAM scope** — the credentials used here should only have the
   permissions to manage this module's resources.

## Local development

You can run this module on your laptop without anything special:

```bash
cd terraform/release-marker
terraform init
terraform apply -var=stage=dev -var=image_tag=v0.0.0-local
terraform output
```

`terraform destroy` cleans up — the only "resources" are the random_id and the
terraform_data record, both stateful in name only.
