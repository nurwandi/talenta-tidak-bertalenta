#!/usr/bin/env bash
set -euo pipefail

# Build for arm64 (Lambda Graviton). On an Apple Silicon / arm64 Docker host this
# builds NATIVELY — no QEMU emulation, so the aws-lambda-ric native compile is
# reliable (amd64 builds segfault under emulation). Lambda must be architectures=["arm64"].

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

# --provenance=false: skip buildx attestation manifests so each push is a single
# image (keeps the ECR repo clean and the keep-2 lifecycle policy predictable).
docker build --provenance=false --platform linux/arm64 -t "${REPO}:${TAG}" .
docker tag "${REPO}:${TAG}" "${ECR}/${REPO}:${TAG}"
docker push "${ECR}/${REPO}:${TAG}"

echo "pushed ${ECR}/${REPO}:${TAG}"
