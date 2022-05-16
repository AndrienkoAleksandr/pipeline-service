#!/usr/bin/env bash

set -exuo pipefail

parent_path=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
pushd "$parent_path"

source ../local/.utils

detect_container_engine

IMAGE="$KO_DOCKER_REPO/ckcp:50e3ab2dcfe2e17dc0bd9d0adf1517e98b59c55d"
${CONTAINER_ENGINE} build -t "$IMAGE" docker/ckcp/
${CONTAINER_ENGINE} push "$IMAGE"

popd
