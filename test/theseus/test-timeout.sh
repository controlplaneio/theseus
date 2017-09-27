#!/usr/bin/env bash

# load '_helper'
#
# @test "Times out after 1s" {
#
#   local START_TIME="${SECONDS}"
#
#   run "${APP}" \
#     test/theseus/asset/reviews-deployment-v2.yaml \
#     --dry-run \
#     --timeout 1 \
#     --timeout-test-delay 1 \
#     --cookie cookie \
#     --test "true"
#
#   local DURATION=$((SECONDS - START_TIME))
#
#   assert_failure
#   assert_line --regexp './theseus:.*Timeout reached after 1s.*$'
#   assert [ ${DURATION} -lt 3 ]
# }
#
# @test "Times out after 5s" {
#
#   local START_TIME="${SECONDS}"
#
#   run "${APP}" \
#     test/theseus/asset/reviews-deployment-v2.yaml \
#     --dry-run \
#     --timeout 5 \
#     --timeout-test-delay 5 \
#     --cookie cookie \
#     --test "true"
#
#   local DURATION=$((SECONDS - START_TIME))
#
#   assert_failure
#   assert_line --regexp './theseus:.*Timeout reached after 5s.*$'
#   assert [ ${DURATION} -lt 7 ]
# }
