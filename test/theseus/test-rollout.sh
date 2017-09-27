#!/usr/bin/env bash

load '_helper'

undeployment_asserts() {
  TARGET_LINE=$(echo "$output" | grep --line-number 'Route YAML:' | head -n1 | cut -d: -f1)
  TARGET_LINE=$((TARGET_LINE - 2))

  assert_success
  assert_line \
    --index "${TARGET_LINE}" \
    --regexp './theseus:.*Route YAML:.*$'
  assert_line \
    --index "$((TARGET_LINE + 1))" \
    --regexp 'type: routerule'
  assert_line \
    --index "$((TARGET_LINE + 2))" \
    --regexp 'name: reviews-steak'
  assert_line \
    --regexp 'Deployment of .* succeeded in'
}

@test "undeploys previous deployment on success via stdin" {

  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --tag steak \
    --weight 1 \
    --cookie user=jason \
    --test "true" \
    --undeploy <(cat test/theseus/asset/reviews-deployment-v1.yaml)

  undeployment_asserts
  assert_line --regexp 'Undeploying deployment'
}

@test "undeploys previous deployment on success via selector" {

  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --tag steak \
    --weight 1 \
    --cookie user=jason \
    --test "true" \
    --undeploy reviews-v2

  undeployment_asserts
  assert_line --regexp 'Undeploying deployment'
}

@test "undeploys previous deployment on success via file" {

  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --tag steak \
    --weight 1 \
    --cookie user=jason \
    --test "true" \
    --undeploy test/theseus/asset/reviews-deployment-v1.yaml

  undeployment_asserts
  assert_line --regexp 'Undeploying file'
}


