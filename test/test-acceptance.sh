#!/bin/bash

set -eu -o pipefail

declare -r DIR=$(cd "$(dirname "$0")" && pwd)
cd "${DIR}"
THIS_SCRIPT="${DIR}"/$(basename "$0")

TEST_FILTER="${1:-*}"

printf '' | tee ../debug.log

_debug_time() {
  echo "${BASH_SOURCE[0]} running for ${SECONDS}s ($((SECONDS / 60)) minutes)" >&2
}

#for TEST_FILE in acceptance/*${TEST_FILTER}*.sh; do
#  date
#  _debug_time
#  time ./bin/bats/bin/bats "${TEST_FILE}"
#  echo
#done
#

for TEST_FILE in acceptance/*${TEST_FILTER}*.sh; do
  date
  _debug_time
  if ! DEBUG="${DEBUG:-0}" time "${TEST_FILE}"; then
    _debug_time
    echo "Tests failed"
    exit 1
  fi

  echo
done
