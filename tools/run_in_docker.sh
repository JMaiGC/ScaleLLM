#!/bin/bash
# Adapted from https://github.com/tensorflow/serving

# ==============================================================================
#
# Script to run commands (like builds and scripts) in a docker container.
#
# Note: This script binds your working directory (via pwd) and /tmp to the
# Docker container. Any scripts or programs you run will need to have its
# output files/dirs written to one of the above locations for persistence.
#
# Typical usage (to build from latest upstream source):
# $ git clone --recursive https://github.com/vectorch-ai/ScaleLLM.git
# $ cd ScaleLLM
# $ ./tools/run_in_docker.sh cmake -G Ninja -S . -B build
# $ ./tools/run_in_docker.sh cmake --build build --target all

set -e

function usage() {
  local progname=$(basename $0)
  echo "Usage:"
  echo "  ${progname} [-d <docker-image-name>] [-o <docker-run-options>] <command> [args ...]"
  echo ""
  echo "Examples:"
  echo "  ${progname} cmake -G Ninja -S . -B build"
  echo "  ${progname} cmake --build build --target all"
  exit 1
}

(( $# < 1 )) && usage

IMAGE="vectorchai/scalellm_devel:latest"
RUN_OPTS=()
while [[ $# > 1 ]]; do
  case "$1" in
    -d)
      IMAGE="$2"; shift 2;;
    -o)
      RUN_OPTS=($2); shift 2;;
    *)
      break;;
  esac
done

RUN_OPTS+=(--rm -it --network=host)
# Map the working directory and /tmp to allow scripts/binaries to run and also
# output data that might be used by other scripts/binaries
RUN_OPTS+=("-v $(pwd):$(pwd)")
RUN_OPTS+=("-v /tmp:/tmp")
RUN_OPTS+=("-v ${HOME}:${HOME}")

# Carry over cache settings
VCPKG_DEFAULT_BINARY_CACHE=${VCPKG_DEFAULT_BINARY_CACHE:-${HOME}/.cache/vcpkg}
mkdir -p "${VCPKG_DEFAULT_BINARY_CACHE}"
RUN_OPTS+=("-v ${VCPKG_DEFAULT_BINARY_CACHE}:${VCPKG_DEFAULT_BINARY_CACHE}")
RUN_OPTS+=("-e VCPKG_DEFAULT_BINARY_CACHE=${VCPKG_DEFAULT_BINARY_CACHE}")

CCACHE_DIR=${CCACHE_DIR:-${HOME}/.cache/ccache}
mkdir -p "${CCACHE_DIR}"
RUN_OPTS+=("-v ${CCACHE_DIR}:${CCACHE_DIR}")
RUN_OPTS+=("-e CCACHE_DIR=${CCACHE_DIR}")

# Run as the current user
RUN_OPTS+=("-u $(id -u):$(id -g)")

CMD="$@"
[[ "${CMD}" == "" ]] && usage

[[ ! -x $(command -v docker) ]] && echo "ERROR: 'docker' command missing from PATH." && usage
if ! docker pull ${IMAGE}; then
  echo "WARNING: Failed to docker pull image ${IMAGE}"
fi

# Execute the command in the Docker container
# echo "docker run ${RUN_OPTS[@]} ${IMAGE} bash -c \"cd $(pwd); ${CMD}\""
docker run ${RUN_OPTS[@]} ${IMAGE} bash -c "cd $(pwd); ${CMD}"
