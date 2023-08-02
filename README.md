# InfraBlocks

Portfolio reference implementation of a 2021 project, built to show reusable Terraform modules and a GitOps-style pipeline for an e-commerce platform's AWS footprint.

**Stack:** Terraform 0.14 (AWS provider 3.x), AWS (VPC, ECS Fargate, ALB, RDS PostgreSQL, S3, Secrets Manager), GitHub Actions with OIDC, Python policy checks.

## Layout
```
modules/
  vpc/           3-AZ VPC, public/private /20s, NAT per AZ (or one shared), reject flow logs to S3
  s3-bucket/     private by default: SSE, versioning, public-access block, TLS-only policy, lifecycle
  rds-postgres/  encrypted, private, Multi-AZ, force_ssl, pg_stat_statements, password generated and stored in Secrets Manager
  ecs-service/   Fargate service + target group + listener rule, circuit-breaker rollback,
                 CPU target tracking, secrets injected from Secrets Manager, read-only root FS
envs/staging, envs/prod   compositions; S3 backend with DynamoDB locking
bootstrap/       state bucket, lock table, GitHub OIDC provider and plan/apply roles (applied once by hand)
policy/          static guardrails (python-hcl2) + tests
.github/workflows/terraform.yml
```

## Guardrails (`policy/check.py`)
These run on every PR before `plan`, with no cloud credentials needed:

| Rule | What it enforces |
|---|---|
| `s3-public-access` | every bucket has an `aws_s3_bucket_public_access_block` that references it |
| `s3-encryption` | every bucket has server-side encryption configured |
| `rds-encryption`, `rds-private`, `rds-password` | storage is encrypted, `publicly_accessible = false`, and the password comes from `random_password` |
| `open-ingress` | `0.0.0.0/0` ingress only on ports 80 and 443 |
| `pinned-provider` | providers use `~>` or `=` version constraints |
| `remote-state`, `required-tags` | env roots use an encrypted, locked S3 backend and define the Environment, Owner and CostCenter tags |
| `pinned-image` | no `:latest` or untagged container images |

## Pipeline
1. **PR:**
   - `fmt -check`, then `validate` on each module.
   - Policy tests and checks, then `tflint`.
   - A `plan` for staging and prod, posted as a PR comment. The comment includes a warning banner when the plan would destroy resources.
2. **Merge to main:** applies the **saved plan artifact** (exactly what was reviewed), staging first, then prod.
   - Prod is gated by a GitHub Environment that requires reviewer approval.
   - Applies are never cancelled midway (`cancel-in-progress: false`).
3. **Credentials:**
   - CI assumes AWS roles through GitHub OIDC, so there are no stored access keys.
   - Plan roles are read-only. Apply roles can only be assumed from a GitHub environment.

## Run the checks locally
```bash
pip install python-hcl2==4.3.4 pytest
python policy/check.py        # 0 violations on this repo
(cd policy && pytest -q)      # 16 tests, each rule exercised with failing fixtures
terraform fmt -check -recursive
```
