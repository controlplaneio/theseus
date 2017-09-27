#!/usr/bin/env bash

load '_helper'


@test "generates Route YAML with full invocation beefjerky" {

  pwd
  run "${APP}" \
    test/theseus/asset/beefjerky-deployment-v1.yaml \
    --dry-run \
    --tag steak \
    --weight 1 \
    --cookie user=jason \
    --test "export GATEWAY_URL=\$(kubectl get po -l istio=ingress -o 'jsonpath={.items[0].status.hostIP}'):\$(kubectl get svc istio-ingress -o 'jsonpath={.spec.ports[0].nodePort}'); curl http://\$GATEWAY_URL/productpage"

  assert_success
  assert_line --regexp 'type: routerule'
  assert_line --regexp 'name: beefjerky-steak'
  assert_line --regexp '  destination: beefjerky.default.svc.cluster.local'
  assert_line --regexp '  precedence: ' # TODO: what number should go here?
  assert_line --regexp '  match:'
  assert_line --regexp '    httpHeaders:'
  assert_line --regexp '      cookie:'
  assert_line --regexp '      regex: "user=jason"'
  assert_line --regexp '  route:'
  assert_line --regexp '  - tags:'
  assert_line --regexp '      version: steak'
}



@test "Route YAML: tag" {

  pwd
  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --tag BIG_TAG \
    --weight 1 \
    --cookie user=jason \
    --test "true"

  assert_success
  assert_line --regexp './theseus:.*Route YAML:.*$'
  assert_line --regexp '      version: BIG_TAG'
}

@test "Route YAML: precedence" {

  pwd
  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --tag BIG_TAG \
    --precedence 90210 \
    --weight 1 \
    --cookie user=jason \
    --test "true"

  assert_success
  assert_line --regexp './theseus:.*Route YAML:.*$'
  assert_line --regexp '  precedence: 90210'
}

@test "Route YAML: rule name via --name" {

  pwd
  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --name SOME-RULE-NAME \
    --tag BIG_TAG \
    --precedence 90210 \
    --weight 1 \
    --cookie user=jason \
    --test "true"

  TARGET_LINE=$(echo "$output" | grep --line-number 'Route YAML:' | head -n1 | cut -d: -f1)
  TARGET_LINE=$((TARGET_LINE - 2))

  assert_success
  assert_line --regexp './theseus:.*Route YAML:.*$'
  assert_line \
    --index "$((TARGET_LINE + 2))" \
    --regexp 'name: SOME-RULE-NAME'

}

@test "Route YAML: rule name via yaml and --tag" {

  pwd
  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --tag BIG_TAG \
    --weight 1 \
    --cookie user=jason \
    --test "true"

  assert_success
  assert_line --regexp './theseus:.*Route YAML:.*$'
  assert_line --regexp 'name: reviews-BIG_TAG'

}

@test "Route YAML: destination" {

  pwd
  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --tag BIG_TAG \
    --weight 1 \
    --cookie user=jason \
    --test "true"

  assert_success
  assert_line --regexp './theseus:.*Route YAML:.*$'
  assert_line --regexp '  destination: reviews.default.svc.cluster.local'

}


@test "generates Route YAML with full invocation" {

  pwd
  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --tag v2 \
    --weight 1 \
    --cookie user=jason \
    --test "export GATEWAY_URL=\$(kubectl get po -l istio=ingress -o 'jsonpath={.items[0].status.hostIP}'):\$(kubectl get svc istio-ingress -o 'jsonpath={.spec.ports[0].nodePort}'); curl http://\$GATEWAY_URL/productpage"

  TARGET_LINE=$(echo "$output" | grep --line-number 'Route YAML:' | head -n1 | cut -d: -f1)
  TARGET_LINE=$((TARGET_LINE - 2))

  echo "$output"

  assert_success
  assert_line \
    --index "${TARGET_LINE}" \
    --regexp './theseus:.*Route YAML:.*$'
  assert_line \
    --index "$((TARGET_LINE + 1))" \
    --regexp 'type: routerule'
  assert_line \
    --index "$((TARGET_LINE + 2))" \
    --regexp 'name: reviews-v2'
  assert_line --regexp '  destination: reviews.default.svc.cluster.local'
  assert_line --regexp '  precedence: ' # TODO: what number should go here?
  assert_line --regexp '  match:'
  assert_line --regexp '    httpHeaders:'
  assert_line --regexp '      cookie:'
  assert_line --regexp '        regex: "user=jason"'
  assert_line --regexp '  route:'
  assert_line --regexp '  - tags:'
  assert_line --regexp '      version: v2'
}

# errors if no selector found in pod
