#!/usr/bin/env bash

load '_helper'

# assert
# refute
# assert_equal
# assert_success
# assert_failure
# assert_output
# refute_output
# assert_line
# refute_line

@test "review v3 take 2 - route by cookie header" {

  run ${APP} test/theseus/asset/reviews-deployment-v3.yaml \
    ${DEBUG} \
    --cookie 'andy' \
    --test "test \$(curl -vvv -H 'cookie: andy' --compressed --connect-timeout 5 \
   --max-time 5  \"http://\${GATEWAY_URL}/productpage\" \
   | grep '\bglyphicon-star\b' \
   | grep --fixed-strings '<font color=\"red\">' \
   | wc -l) -eq 1"

  hr "Tests passed"
  assert_success
}

@test "review v3 take 2 - route by user-agent header" {

  run ${APP} test/theseus/asset/reviews-deployment-v3.yaml \
    ${DEBUG} \
    --user-agent 'andy' \
    --test "test \$(curl -vvv -A 'andy' --compressed --connect-timeout 5 \
   --max-time 5  \"http://\${GATEWAY_URL}/productpage\" \
   | grep '\bglyphicon-star\b' \
   | grep --fixed-strings '<font color=\"red\">' \
   | wc -l) -eq 1"

  hr "Tests passed"
  assert_success
}
