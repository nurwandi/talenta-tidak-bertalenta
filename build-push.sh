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

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR"

docker build --platform linux/amd64 -t "${REPO}:${TAG}" .
docker tag "${REPO}:${TAG}" "${ECR}/${REPO}:${TAG}"
docker push "${ECR}/${REPO}:${TAG}"

echo "pushed ${ECR}/${REPO}:${TAG}"
