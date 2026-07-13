<h1 align="center">talenta-tidak-bertalenta</h1>

<p align="center">
  A <b>serverless</b> bot that clocks you in/out of Talenta HR so you don't have to.<br>
  Runs itself on AWS Lambda. No VPN, no idle servers, no drama.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/AWS-Lambda-FF9900?logo=awslambda&logoColor=white" alt="AWS Lambda">
  <img src="https://img.shields.io/badge/Playwright-1.60.0-2EAD33?logo=playwright&logoColor=white" alt="Playwright">
  <img src="https://img.shields.io/badge/Terraform-HCP-7B42BC?logo=terraform&logoColor=white" alt="Terraform / HCP">
  <img src="https://img.shields.io/badge/arch-ARM64%20Graviton-0091BD?logo=arm&logoColor=white" alt="ARM64">
  <img src="https://img.shields.io/badge/region-ap--southeast--3-232F3E?logo=amazonwebservices&logoColor=white" alt="Jakarta">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT">
</p>

<p align="center">
  <img src="https://media0.giphy.com/media/v1.Y2lkPTc5MGI3NjExcHBvYWpjbXEwbGd5dm15Y3VrNmxjcXptejlhOTZmN3Ntajd6MmQwMyZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/lVhFOxFmaJezm/giphy.gif" width="480" alt="clocking in, allegedly">
</p>

Mandatory attendance at 9AM sharp, and one minute late means your salary gets docked? Cool. Let a robot in the cloud handle it. You go write code.

This bot spins up a **headless stealth Chromium** inside AWS Lambda in the **Jakarta region (`ap-southeast-3`)**, logs into `hr.talenta.co`, and clicks **Clock In / Clock Out** on schedule. Because the Lambda lives in Jakarta, its outbound IP is already Indonesian — so **no VPN or exit-node required.** The name means "Talent with no talent," which is a subtweet, and we stand by it.

---

## Why it's built this way (the whole trick)

Talenta checks your location/IP — attendance must come from Indonesia. The trick: **run the browser directly inside a Lambda in `ap-southeast-3` (Jakarta)**. The Lambda's outbound IP is already Indonesian, so **no VPN, no exit-node, no server humming 24/7.**

One Lambda does everything: open browser → log in → click → done → go back to sleep. Nothing runs all day, nothing to babysit. You only pay when it actually works (~50 seconds, twice a day). Honestly more disciplined than most employees.

## Architecture

```
EventBridge Scheduler (cron, Asia/Jakarta, Mon–Fri)
  ├─ clock-in  (09:00) ─► Lambda clock-in   {action:"clock-in"}
  └─ clock-out (18:00) ─► Lambda clock-out  {action:"clock-out"}

Lambda (container image, ARM64/Graviton, 2 GB RAM, 2 GB /tmp)
  └─ launch stealth Chromium → log into Talenta → click Clock In/Out
        → intercept the attendance_clocks response (success = HTTP 201)
        → log out → ping Discord (success/failure + screenshot on error)

ECR  ← image built & pushed from your LAPTOP (build-push.sh)
Terraform (HCP) ← manages all infra + state + secrets
```

All infra is managed by **Terraform via HCP Terraform** (remote state & runs). Credentials live as *sensitive variables* in HCP and get injected as Lambda environment variables. No secrets in git, ever.

## Prerequisites

- **An AWS account** with `ap-southeast-3` enabled + AWS CLI configured (a local profile).
- **Docker** — on Apple Silicon (M-series) the build is native ARM64 and painless. (See the arch note below if you're on x86.)
- **Terraform** ≥ 1.6 + an **HCP Terraform** account (app.terraform.io) — free tier is plenty.
- **A Talenta account** (email + password).
- **A Discord webhook** for notifications (optional but you'll want it).
- You're physically **in Indonesia** (for Talenta's geolocation check) — or you at least understand the risk.

## Setup

### 1. Clone

```bash
git clone https://github.com/nurwandi/talenta-tidak-bertalenta.git
cd talenta-tidak-bertalenta
```

### 2. Tweak the config

- **Geolocation** — edit `geoForToday()` in `handler.js`. Defaults:
  - Mon/Fri → `-6.2118931, 106.8264782` (home)
  - Tue–Thu → `-6.1993335, 106.7623687` (office)

  Swap in your own coordinates (grab them from Google Maps).
- **Schedule** — crons live in `terraform/main.tf` (`aws_scheduler_schedule`). Defaults: clock-in `cron(0 9 ? * MON-FRI *)`, clock-out `cron(0 18 ...)`, timezone `Asia/Jakarta`.

### 3. Build & push the image to ECR

This script creates the ECR repo (if missing) + builds + pushes:

```bash
AWS_PROFILE=<your-profile> ./build-push.sh v1
```

> The image is ~1 GB (Chromium + Playwright). On Apple Silicon it builds native ARM64. On x86, see the arch note below.

### 4. Set up HCP Terraform

1. Create an **organization** & **workspace** (VCS-driven, connected to your GitHub repo):
   - Workspace name: `talenta-tidak-bertalenta`
   - **Terraform working directory: `terraform`** ← important, the `.tf` files live in a subfolder.
   - Auto-apply: OFF (so you approve manually).
2. Edit `terraform/versions.tf` → set `organization = "..."` to your HCP org name.
3. **AWS auth (OIDC dynamic credentials, no static keys):**
   - Create the `app.terraform.io` OIDC provider in IAM (skip if it already exists).
   - Create an IAM role HCP can assume (trust: `organization:<ORG>:project:*:workspace:talenta-tidak-bertalenta:run_phase:*`), attach a suitable policy.
   - Set these **environment variables** on the HCP workspace:
     - `TFC_AWS_PROVIDER_AUTH = true`
     - `TFC_AWS_RUN_ROLE_ARN = arn:aws:iam::<ACCOUNT_ID>:role/<role-name>`
4. Set these **Terraform variables** on the HCP workspace (mark the first three **Sensitive**):
   - `talenta_email`, `talenta_password`, `discord_webhook_url`
   - `discord_user_id` (your Discord ID, for the @mention)
   - `image_tag = v1`

### 5. Deploy

Push to `main` → HCP kicks off a plan → **approve the apply** in the HCP UI.

Resources created: 2 Lambdas (clock-in/out), 2 IAM roles, 2 EventBridge schedules, 2 log groups, 1 ECR lifecycle policy (keeps the last 2 images).

### 6. Test it (manually)

⚠️ **This is a REAL clock-in** (there's no dry-run). Only run it when you actually want to clock in:

```bash
AWS_PROFILE=<profile> aws lambda invoke \
  --function-name talenta-tidak-bertalenta-clock-in \
  --payload '{"action":"clock-in"}' \
  --cli-binary-format raw-in-base64-out \
  --cli-read-timeout 0 --region ap-southeast-3 /dev/stdout
```

Success → `{"ok":true}` + a Discord ping. On failure, the error screenshot gets attached to the Discord message so you can see exactly where it faceplanted.

## Pausing it (holidays, leave, sick days)

The bot doesn't know about public holidays or your approved leave — so when you're
off, flip the **manual kill switch**. It disables *both* schedules (clock-in and
clock-out), so nothing fires:

```bash
./toggle.sh off    # before a holiday / leave — the bot goes quiet
./toggle.sh on     # back to work — schedules resume
```

Check current state:

```bash
aws scheduler get-schedule --name talenta-tidak-bertalenta-sched-in \
  --group-name talenta-tidak-bertalenta --region ap-southeast-3 \
  --query State --output text        # ENABLED or DISABLED
```

Needs the `aws` CLI + [`jq`](https://jqlang.github.io/jq/). Uses `AWS_PROFILE`
(defaults to `obi-sandbox`; override with `AWS_PROFILE=<profile> ./toggle.sh off`).

> It's manual on purpose — 100% certainty over clever auto-detection. The catch:
> **remember to `toggle.sh on` when you're back**, or you'll silently skip real
> workdays. The schedules carry `lifecycle { ignore_changes = [state] }` in
> Terraform, so your toggle survives the next `terraform apply`.

## Updating the image (after code changes)

Tags are **mutable**, so just overwrite and repoint (no HCP fiddling required):

```bash
AWS_PROFILE=<profile> ./build-push.sh v1
for fn in clock-in clock-out; do
  aws lambda update-function-code \
    --function-name talenta-tidak-bertalenta-$fn \
    --image-uri <ACCOUNT_ID>.dkr.ecr.ap-southeast-3.amazonaws.com/talenta-tidak-bertalenta:v1 \
    --region ap-southeast-3
done
```

## Cost

Effectively **free**. Lambda's always-free tier is 400,000 GB-seconds + 1M requests/month; this thing uses ~44 runs/month × ~50s × 2 GB, which is *nowhere near* the limit. The only recurring cost is ECR image storage (~$0.15/month). Your coffee costs more.

## Troubleshooting (expensive lessons, now yours for free)

| Symptom | Cause & fix |
|---|---|
| `exec format error` on invoke | Image arch ≠ Lambda arch. This image is **ARM64**; make sure `architectures = ["arm64"]` in `main.tf` and build with `--platform linux/arm64`. |
| `Executable doesn't exist at /ms-playwright/...` | npm Playwright version ≠ the Chromium in the base image. **Pin `playwright` to exactly `1.60.0`** to match `mcr.microsoft.com/playwright:v1.60.0-jammy`. |
| `Target page/context/browser has been closed` on `newPage` | Lambda's process/thread limits are murdering Chromium's renderer. Required flags in `stealth-utils.js`: `--single-process --no-zygote --disable-dev-shm-usage`, plus `ephemeral_storage = 2048`. |
| `docker` build segfaults on Apple Silicon | Don't build `--platform linux/amd64` (QEMU emulation segfaults). Use **native ARM64** (this repo's default). |
| `terraform apply` fails "repository not found" | Expected — run `build-push.sh` first (it creates the ECR repo), then `apply`. |
| HCP run: "No Terraform configuration files found" | Set **Terraform working directory = `terraform`** on the HCP workspace. |

## Repo layout

```
handler.js              # Lambda entrypoint: day-of-week geolocation + Discord notify
src/attendance/clock.js # runClock(): unified clock-in/out + 3× retry
src/attendance/auth.js  # Talenta login & logout
src/browser/stealth-utils.js # launch stealth Chromium (anti-detection) + humanClick
src/core/logger.js
Dockerfile              # MS Playwright base + aws-lambda-ric
build-push.sh           # build + push image to ECR (local)
toggle.sh               # manual kill switch: enable/disable both schedules
terraform/              # infra: ECR (data source), 2× Lambda, IAM, 2× schedule
```

## ⚠️ Disclaimer

- This automates attendance on a real HR system. **Use at your own risk.** You are fully responsible for how you use it and for complying with your workplace's rules.
- Every invoke is a **real, recorded clock-in**. There is no built-in "dry-run."
- This exists for education / personal automation. It is not an endorsement of dodging attendance. It's an endorsement of not being paged by a web form. 🙂

---

*Built because "mandatory 9AM attendance + one minute late = docked pay" is a problem, and problems are just Lambdas that haven't been written yet.*
