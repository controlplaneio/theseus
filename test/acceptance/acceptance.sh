#!/usr/bin/env bash

set -euo pipefail

[[ "${DEBUG:-0}" == 1 ]] && set -x

BIN="./../theseus"
APP="timeout --foreground --kill-after=15s 300s ${BIN}"
DRY_RUN_DEFAULTS="test/theseus/asset/beefjerky-deployment-v1.yaml --dry-run"

export CLICOLOR=1
export TERM="xterm-color"
export COLOUR_BLACK=$(tput setaf 0 :-"" 2>/dev/null)
export COLOUR_RED=$(tput setaf 1 :-"" 2>/dev/null)
export COLOUR_GREEN=$(tput setaf 2 :-"" 2>/dev/null)
export COLOUR_YELLOW=$(tput setaf 3 :-"" 2>/dev/null)
export COLOUR_BLUE=$(tput setaf 4 :-"" 2>/dev/null)
export COLOUR_MAGENTA=$(tput setaf 5 :-"" 2>/dev/null)
export COLOUR_CYAN=$(tput setaf 6 :-"" 2>/dev/null)
export COLOUR_WHITE=$(tput setaf 7 :-"" 2>/dev/null)
export COLOUR_RESET=$(tput sgr0 :-"" 2>/dev/null)

declare -r DIR=$(cd "$(dirname "$0")" && pwd)
THIS_SCRIPT="${DIR}"/$(basename "$0")

cd "${DIR}" >&2
[[ -n "${LOCAL_ISTIO:-}" ]] && ../local-istio.sh >&2
cd "${DIR}/.." >&2
if [[ "${DEBUG:-0}" == 1 ]]; then
  DEBUG='--debug'
else
  DEBUG=''
fi

trap 'kubectl get event | tail -n 30' EXIT

if [[ ! -f "${BIN}" ]]; then
  echo "not found from $(pwd)"
  exit 1
fi

main() {
  # assert
  # refute
  # assert_equal
  # assert_success
  # assert_failure
  # assert_output
  # refute_output
  # assert_line
  # refute_line

  function assert_success() {
    [[ $? -eq 0 ]]
  }

  function assert_failure() {
    [[ $? -gt 0 ]]
  }

  test() {
    info "TEST: ${1}" | tee ../../debug.log
  }

  test "finds application and cleans debug log"
  {
    pwd
    echo "${APP}"
    printf '' | tee ../../debug.log

    assert_success
  }

  test "patches ingress default host to productpage "
  {

    if ! kubectl describe ingress gateway | grep -qE '/hello.*helloworld:5000'; then
      kpatch-ingress gateway "" productpage 9080
    fi

    assert_success
  }
  test "patches ingress /hello to helloworld"
  {

    if ! kubectl describe ingress gateway | grep -qE '/hello.*helloworld:5000'; then
      kpatch-ingress gateway /hello helloworld 5000
    fi
    assert_success
  }

  test "accepts timeout value of 1s"
  {
    set -x
    ${APP} test/theseus/asset/reviews-deployment-v1.yaml \
      --timeout 1 \
      --cookie cookie \
      ${DEBUG}

    assert_success
  }

  test "cleans state deployment v1"
  {

    ${APP} test/theseus/asset/reviews-deployment-v1.yaml \
      --delete \
      --cookie cookie \
      ${DEBUG}

    assert_success
  }

  test "cleans state deployment v2"
  {

    ${APP} test/theseus/asset/reviews-deployment-v2.yaml \
      --delete \
      ${DEBUG}

    assert_success
  }

  test "waits for no reviews pods"
  {

    wait_for_no_pods reviews
    assert_success
  }

  test "waits for root ingress to resolve"
  {

    INGRESS_IP=$(kubectl describe ingress gateway | awk '/Address/{print $2}')
    wait_for_ingress_route http://${INGRESS_IP}
    assert_success
  }

  test "waits for productpage ingress to resolve"
  {

    INGRESS_IP=$(kubectl describe ingress gateway | awk '/Address/{print $2}')
    wait_for_ingress_route http://${INGRESS_IP}/productpage
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

  test "deploy reviews v2"
  {

    ${APP} test/theseus/asset/reviews-deployment-v2.yaml \
      ${DEBUG} \
      --cookie choc-chip \
      --test "test \$(curl -A 'Mozilla/4.0' --compressed --connect-timeout 5 \
     --header 'cookie: choc-chip' \
     --max-time 5  \"http://\${GATEWAY_URL}/productpage\" \
     | grep -o '\bglyphicon-star\b' \
     | wc -l) -ge 10"
    assert_success
  }

  test "deploy reviews v3"
  {

    ${APP} test/theseus/asset/reviews-deployment-v3.yaml \
      ${DEBUG} \
      --cookie rasperry \
      --test "test \$(curl -A 'Mozilla/4.0' --compressed --connect-timeout 5 \
     --header 'cookie: raspberry' \
     --max-time 5  \"http://\${GATEWAY_URL}/productpage\" \
     | grep '\bglyphicon-star\b' \
     | grep --fixed-strings '<font color=\"red\">' \
     | wc -l) -eq 1"

    assert_success
  }

#  test "Failing deploy"
#  {
#
#    # intentionally failing deployment (service starts, healthchecks, fails after 5s)
#    if ${APP} test/theseus/asset/bad-ghost-deployment.yaml \
#      ${DEBUG} \
#      --user-agent '.*' \
#      --test "test \$(curl -A 'Mozilla/4.0' --compressed --connect-timeout 5 \
#     --max-time 5  \"http://\${GATEWAY_URL}/productpage\" \
#     | grep '\bglyphicon-star\b' \
#     | grep --fixed-strings '<font color=\"red\">' \
#     | wc -l) -eq 1"; then
#
#      echo "Supposed to return non-zero"
#      exit 1
#    fi
#
#    success "Intentionally failing deploy: passed"
#  }

  success "test suite passed"
  trap - EXIT
}

wait_for_no_pods() {
  local POD="${1}"
  local TIMEOUT=30
  local COUNT=1
  while [[ $(kubectl get pods --all-namespaces -o name | grep -q -E "^pods/${POD}") ]]; do
    let COUNT=$((COUNT + 1))
    [[ "$COUNT" -gt "${TIMEOUT}" ]] && {
      echo "Timeout" >&2
      exit 1
    }
    sleep 1
  done
  echo "Wait complete in ${COUNT} seconds" >&2
  sleep 1
}

wait_for_ingress_route() {
  local URL="${1}"
  local COUNT=0
  local COUNT_TIMEOUT=50
  until [[ $(curl \
    --max-time 5 \
    -o /dev/null \
    -w "%{http_code}\n" \
    -s \
    "${URL}"
  ) == 200 ]]; do
    let COUNT=$((COUNT + 1))
    [[ "${COUNT}" -gt "${COUNT_TIMEOUT}" ]] && {
      echo "Timeout"
      kubectl get event
      exit 1
    }
    sleep $((5 * (COUNT + 10) / 10))
  done
}

hr() {
  printf '=%.0s' $(seq $(tput cols))
  if [[ -n "$*" ]]; then
    echo "$*" >&2
    hr
  fi
  echo
}

istio-inject() {
  if [[ $(kubectl config current-context | grep -E '^gke_' -c) -gt 0 ]]; then
    local RANGES=$(
      gcloud container clusters describe \
        $(kubectl config current-context \  | cut -d'_' -f 3- \  | awk -F_ '{print $2" --zone="$1}') \  | grep -e clusterIpv4Cidr -e servicesIpv4Cidr \  | cut -d' ' -f2 \  | xargs \  | tr ' ' ','
    )
  else
    local RANGES=10.0.0.1/24
  fi
  istioctl kube-inject --includeIPRanges="${RANGES}" \  -f - | sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g ; s/"imagePullPolicy":"Always"/"imagePullPolicy":"IfNotPresent"/g'
}

kpatch-ingress() {
  local TARGET="${1}"
  local HOST="${2}"
  local SERVICE_NAME="${3}"
  local SERVICE_PORT="${4:-80}"
  local URL_PATH=""
  if [[ -z "${TARGET:-}" || -z "${SERVICE_NAME:-}" || -z "${SERVICE_PORT:-}" ]]; then
    echo "Parameter missing" >&2
    return 1
  fi
  if [[ "${HOST:0:1}" == '/' ]]; then
    URL_PATH="${HOST}"
  fi
  if kubectl get ingress gateway -o yaml | ag --smart-case --passthru "host: ${HOST:-$}" >&2; then
    echo "Host ${HOST} already has an entry. Please resolve manually" >&2
    return 1
  fi
  if [[ -n "${URL_PATH}" ]]; then
    kubectl patch ingress "${TARGET}" --type='json' -p "$(
      echo "[{'op': 'add', 'path': '/spec/rules/1', 'value': {
      'http':{'paths':[{'path': '${URL_PATH}', 'backend':{'serviceName':'${SERVICE_NAME}','servicePort':${SERVICE_PORT}}}]}}}]" | tr "'" '"'
    )"
  else
    kubectl patch ingress "${TARGET}" --type='json' -p "[{\"op\": \"add\", \"path\": \"/spec/rules/1\", \"value\": {       \"host\": \"${HOST}\", \"http\":{\"paths\":[{\"backend\":{\"serviceName\":\"${SERVICE_NAME}\",\"servicePort\":${SERVICE_PORT}}}]}  } }]"
  fi
  kubectl get ingress "${TARGET}" -o yaml >&2
}

success() {
  [ "${@:-}" ] && RESPONSE="$@" || RESPONSE="Unknown Success"
  printf "$(log_message_prefix)${COLOUR_GREEN}%s${COLOUR_RESET}\n" "${RESPONSE}" | tee -a debug.log
} 1>&2

info() {
  [ "${@:-}" ] && INFO="$@" || INFO="Unknown Info"
  printf "$(log_message_prefix)${COLOUR_WHITE}%s${COLOUR_RESET}\n" "${INFO}" | tee -a debug.log
} 1>&2

warning() {
  [ "${@:-}" ] && ERROR="$@" || ERROR="Unknown Warning"
  printf "$(log_message_prefix)${COLOUR_RED}%s${COLOUR_RESET}\n" "${ERROR}" | tee -a debug.log
} 1>&2

error() {
  [ "${@:-}" ] && ERROR="$@" || ERROR="Unknown Error"
  printf "$(log_message_prefix)${COLOUR_RED}%s${COLOUR_RESET}\n" "${ERROR}" | tee -a debug.log
  exit 3
} 1>&2

log_message_prefix() {
  local TIMESTAMP="[$(date +'%Y-%m-%dT%H:%M:%S%z')]"
  local THIS_SCRIPT_SHORT=${THIS_SCRIPT/$DIR/.}
  tput bold 2>/dev/null
  echo -n "${TIMESTAMP} ${THIS_SCRIPT_SHORT}: "
}

main
