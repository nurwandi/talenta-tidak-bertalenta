#!/usr/bin/env bash
set -euo pipefail

# NOTE: on Apple Silicon, `docker build --platform linux/amd64` can segfault under
# QEMU emulation. If that happens, build via a native amd64 VM (e.g. colima with an
# x86_64 profile) or a `docker buildx` builder configured for linux/amd64.

TAG="${1:?usage: ./build-push.sh <tag, e.g. v1>}"
REGION="ap-southeast-3"
REPO="talenta-tidak-bertalenta"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Create the ECR repo if it doesn't exist yet (Terraform reads it as a data source).
aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$REPO" --region "$REGION" \
    --image-tag-mutability IMMUTABLE \
    --tags Key=Project,Value="$REPO" Key=Resource,Value=ecr >/dev/null

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR"

docker build --platform linux/amd64 -t "${REPO}:${TAG}" .
docker tag "${REPO}:${TAG}" "${ECR}/${REPO}:${TAG}"
docker push "${ECR}/${REPO}:${TAG}"

echo "pushed ${ECR}/${REPO}:${TAG}"
