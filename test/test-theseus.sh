#!/bin/bash

set -eu -o pipefail

declare -r DIR=$(cd "$(dirname "$0")" && pwd)
cd "${DIR}"
THIS_SCRIPT="${DIR}"/$(basename "$0")

TEST_FILTER="${1:-*}"

printf '' | tee ../debug.log

./bin/bats/bin/bats theseus/*${TEST_FILTER}*.sh
