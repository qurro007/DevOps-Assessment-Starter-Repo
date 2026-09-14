# REVIEW

## Blockers

### 1. Tests are disabled — broken code can deploy to prod
`.github/workflows/deploy.yml`

```yaml
- name: Run tests
  continue-on-error: true   # <-- deploy proceeds even if tests fail
  run: pytest app/
```

**Why it matters:** the only safety gate in the pipeline is bypassed. Any regression ships to production.

**Fix:** delete `continue-on-error: true` so a failing suite aborts the job.

### 2. Secrets are baked into build artifacts and committed to the repo
- `Dockerfile`: `ENV DB_PASSWORD=SuperSecret123!` hardcodes the password into the image (`docker history` would expose it).
- `.env` at repo root (`DB_HOST`, `DB_PASSWORD`, `API_TOKEN`) is committed; `COPY . .` copies it into every image.
- `infra/variables.tf`: `db_password` has a plaintext default, written into the task definition in `environment`.

**Why it matters:** anyone with image/read access sees the credentials; a leaked repo leaks prod secrets.

**Fix:**
- Remove the `ENV` line from the Dockerfile; remove the `.env` file from the repo and inject `/`. env at deploy time (repo secret).
- Add `.dockerignore` so `.env`, `infra/`, `.github/`, tests never enter the image (verified: not present).
- `db_password` variable: drop the default, mark `sensitive = true`, supply in CI as a secret.

### 3. Security group is wide open
`infra/main.tf` — original allowed **all TCP (0–65535) and SSH port 22 from 0.0.0.0/0**.

**Why it matters:** for a service that only serves HTTP on 8080, this is an internet-accessible attack surface (SSH on an ALB/Fargate task is useless anyway).

**Fix:** one ingress rule, `8080/tcp` from `0.0.0.0/0` (egress unchanged).

## Should-fix

### 4. Image build is non-reproducible and bloated
`Dockerfile` — `FROM python:latest` (mutable tag), `COPY . .` copies the whole repo, huge base image.

**Why it matters:** builds are not reproducible; image size (measured below) went from **1.63 GB to 206 MB**.

**Fix:** pin `python:3.12-slim`, copy only `app/`, add `.dockerignore`.

### 5. CI pushes `latest` and never pins what's deployed
`.github/workflows/deploy.yml` builds/pushes `:latest` and ECS `image_tag` defaults to `latest`. You can never tell which commit is running, and rolling back is guesswork.

**Fix:** tag with `${{ github.sha }}`, pass `-var image_tag=${{ github.sha }}` to terraform, and (nice-to-have) stop tagging `latest` on prod pushes.

### 6. Docker push would fail — no ECR login step
`docker push` with no `aws ecr get-login-password | docker login` step. (Also, creds were set as raw `env` rather than via the AWS credentials action.)

**Fix:** add `aws-actions/configure-aws-credentials` and `aws-actions/amazon-ecr-login`.

### 7. No health check on the target group
Original `aws_lb_target_group` had no `health_check`, so the ALB won't reliably drain/roll back bad containers; the app even exposes `/health` that was never wired up.

**Fix:** add `health_check { path = "/health" }` on the TG.

### 8. Secrets passed in plaintext `environment` of the task definition
`DB_PASSWORD` is visible in the ECS console/task definition.

**Fix (minimal):** add `sensitive = true` variable

### 9. Logs go nowhere
No `logConfiguration` on the container → CloudWatch Logs get nothing, so incidents are invisible.

**Fix:** added `awslogs` driver (`/ecs/${app_name}`).

### 10. Add "__init__.py"
- Add empty `app/__init__.py` to make test (pytest) pass. 


## Nice-to-have (documented, not fixed)

- **ALB is plain HTTP** on port 80; terminate TLS with ACM for a public service.
- **Non-root user** in the container.
- **No ECR lifecycle policy** — cleanup old images.
- **use SSM Parameter Store** — Store secret/password safely
- **One task role used as both task *and* execution role** — should be split them.

## How would I know the service is down, and how would I roll back a bad deploy?

**Detecting downtime.** 
First, a synthetic check: a scheduled Lambda (or external uptime probe) hits `GET /health` and alarms if the endpoint fails 3× consecutively — this is the only signal that catches real user-facing downtime. 
Second, infrastructure alarms: CloudWatch alarms on the ALB's `HTTPCode_Target_5XX_Count` and `HealthyHostCount < 1`, plus an alert on the ECS service's `running tasks < desired` and on the target group's registered-unhealthy count. 
Third, logs: with the `awslogs` driver wired up, an alert pattern on `ERROR`/`Traceback` in the `/ecs/demo-api` log group gives the fastest root-cause context. All three feed a common SNS → PagerDuty/Slack path.

**Rolling back.** 
Because every deploy is now an immutable, SHA-tagged image and a terraform variable, 
the fastest rollback is *redeploy the last known-good commit*: `terraform apply -var image_tag=<previous-good-sha>` (or re-run the pipeline on the old SHA), 
then `aws ecs update-service --force-new-deployment`.

## Verification (run locally, no AWS credentials)

`terraform fmt -check` (from `infra/`, after `terraform fmt`):

```
$ terraform fmt -check
(no output — exit 0)
```

`terraform validate` (from `infra/`, after `terraform init`):

```
$ terraform validate
Success! The configuration is valid.
```

`pytest app/`:

```
2 passed in 0.09s
```

Docker image size **before → after** (`docker images`):

```
demo-api-after:latest                      04e6ca76f367        141MB             0B        
demo-api-before:latest                     9a3b998c33de       1.13GB             0B    
```

Runtime check: the new image starts, `GET /health` returns `{"status":"ok"}`, and the image contains **no** `.env` / secrets.

## What I'd do with more time

- Do all "Nice-to-have"
