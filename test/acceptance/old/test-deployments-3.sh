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

echo "Failing deploy" ; {

  # intentionally failing deployment (service starts, healthchecks, fails after 5s)
  run ${APP} test/theseus/asset/bad-ghost-deployment.yaml \
    ${DEBUG} \
    --user-agent '.*' \
    --test "test \$(curl -A 'Mozilla/4.0' --compressed --connect-timeout 5 \
   --max-time 5  \"http://\${GATEWAY_URL}/productpage\" \
   | grep '\bglyphicon-star\b' \
   | grep --fixed-strings '<font color=\"red\">' \
   | wc -l) -eq 1"

  assert_failure
}

echo "review v2 take 2" ; {

  run ${APP} test/theseus/asset/reviews-deployment-v2.yaml \
    ${DEBUG} \
    --user-agent '.*' \
    --test "test \$(curl -A 'Mozilla/4.0' --compressed --connect-timeout 5 \
   --max-time 5  http://\${GATEWAY_URL}/productpage \
   | grep -o '\bglyphicon-star\b' \
   | wc -l) -ge 10"

  assert_success
}

echo "helloworld - clean and deploy v1 and service" ; {

  for FILE in test/theseus/asset/helloworld*; do
    kubectl delete -f "${FILE}" || true
  done

  sleep 10

  run ${APP} test/theseus/asset/helloworld-service-and-v1.yaml \
    ${DEBUG} \
    --user-agent '.*'

  assert_success
}

echo "helloworld - route by external header" ; {

  run ${APP} test/theseus/asset/helloworld-v2.yaml \
    ${DEBUG} \
    --user-agent 'andy' \
    --test "test \$(curl -vvv -A 'andy' --max-time 5  \"http://\${GATEWAY_URL}/hello\" | grep 'Hello version: v2,' | wc -l) -eq 1"
  assert_success
}


# assert
# refute
# assert_equal
# assert_success
# assert_failure
# assert_output
# refute_output
# assert_line
# refute_line

echo "review v3 take 2 - route by cookie header" ; {

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

echo "review v3 take 2 - route by user-agent header" ; {

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
