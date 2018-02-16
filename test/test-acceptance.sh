#!/usr/bin/env bash
#
# theseus acceptance tests
#
# Andrew Martin, 2017-09-28 14:00:31
# andy@control-plane.io
#
## Usage: %SCRIPT_NAME% [options] filename
##
## Options:
##
##   --debug                     More debug
##   -h --help                   Display this message
##

# exit on error or pipe failure
set -eo pipefail
# error on unset variable
set -o nounset
# error on clobber
set -o noclobber

set -x
# user defaults
DESCRIPTION="theseus acceptance tests"
DEBUG="${DEBUG:-0}"

echo "DEBUG $DEBUG"

# resolved directory and self
declare -r DIR=$(cd "$(dirname "$0")" && pwd)
declare -r THIS_SCRIPT="${DIR}/$(basename "$0")"

# required defaults
declare -a ARGUMENTS
EXPECTED_NUM_ARGUMENTS=0
ARGUMENTS=()
FILENAME=''
THIS_TEST=""

istio-routerule-delete ()
{
    local RULE_NAME="${1:-}";
    istioctl get routerules | tail -n +2 | awk "/^${RULE_NAME:-.}/{print \$1}" | sort | xargs --no-run-if-empty istioctl delete routerule -n default
}

main() {
  handle_arguments "$@"

  #  trap 'kubectl get event | tail -n 30' EXIT

  [[ "${DEBUG:-0}" == 1 ]] && set -x

  BIN="./theseus.sh"
  if [[ ! -f "${BIN}" ]]; then
    echo "not found from $(pwd)"
    exit 1
  fi

  if [[ "${DEBUG_FLAG:-}" != "" ]]; then
    BIN+=" --debug-file"
  fi

  APP="timeout --foreground --kill-after=15s 300s ${BIN}"
  DRY_RUN_DEFAULTS="test/theseus/asset/beefjerky-deployment-v1.yaml --dry-run"

  if [[ "${IS_MINIKUBE:-}" == "" ]]; then
    if kubectl config current-context | grep -qE '^gke_'; then
      IS_MINIKUBE=0
    else
      IS_MINIKUBE=1
    fi
  fi

  if [[ "${GATEWAY_URL:-}" == "" ]]; then
    if [[ "${IS_MINIKUBE}" == 1 ]]; then
      GATEWAY_URL=$(kubectl get pod \
        --namespace istio-system \
        -l istio=ingress \
        -o 'jsonpath={.items[0].status.hostIP}'):$(kubectl get svc \
          --namespace istio-system \
          istio-ingress \
          -o 'jsonpath={.spec.ports[0].nodePort}')
    else
      GATEWAY_URL=$(kubectl get ingress gateway \
        -o 'jsonpath={.status.loadBalancer.ingress[].ip}')
    fi
  fi
  set -x

  echo "Gateway URL: ${GATEWAY_URL}"

  # ---

  test "preemptively deploys bookinfo"
  {
    (
      set -x
      cd "${DIR}"/..
      PIDS=""
      local ISTIO_VERSION=$(find . -maxdepth 1 -name 'istio-*' -type d | sort --version-sort | head -n1)
      kubectl delete -f <(istioctl kube-inject -f "${DIR}"/theseus/asset/bookinfo.yaml) || true
      kubectl apply -f <(istioctl kube-inject -f "${DIR}"/theseus/asset/bookinfo-slim.yaml) || true

      #      kubectl delete deployment reviews-v2 & PIDS="${PIDS} $!"
      #      kubectl delete deployment reviews-v3 & PIDS="${PIDS} $!"

      istio-routerule-delete &
      PIDS="${PIDS} $!"

      wait_safe "${PIDS}"

      istioctl create -f test/theseus/asset/route-rule-all-v1.yaml

      try-slow-backoff "curl -s http://${GATEWAY_URL}/productpage | grep Reviewer1"

    )
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

  test "waits for root ingress to resolve"
  {
    wait_for_ingress_route http://${GATEWAY_URL}
    assert_success
  }

  test "waits for productpage ingress to resolve"
  {
    wait_for_ingress_route http://${GATEWAY_URL}/productpage
    assert_success
  }

  # ---

  TEST_V1="test \$(curl -A 'Mozilla/4.0' --compressed --connect-timeout 5 \
     --header 'cookie: raspberry' \
     --max-time 5  \"http://\${GATEWAY_URL}/productpage\" \
     | grep -Eo 'Reviewer1|\bglyphicon-star\b' \
     | wc -l) -ge 1"

  test "deploy reviews v1"
  {
    ${APP} test/theseus/asset/reviews-deployment-v1.yaml \
      ${DEBUG_FLAG} \
      --cookie raspberry \
      --test "${TEST_V1}"
    assert_success
  }

# ---

  TEST_V2="test \$(curl -A 'Mozilla/4.0' --compressed --connect-timeout 5 \
     --header 'cookie: user=andy' \
     --max-time 5  \"http://\${GATEWAY_URL}/productpage\" \
     | grep -o '\bglyphicon-star\b' \
     | wc -l) -ge 10"

  test "deploy reviews v2"
  {
    ${APP} test/theseus/asset/reviews-deployment-v2.yaml \
      ${DEBUG_FLAG} \
      --cookie "^(.*?;)?(user=andy)(;.*)?$" \
      --test "${TEST_V2}"
    assert_success
  }

  # ---

  TEST_V3="test \$(curl -A 'Mozilla/4.0' --compressed --connect-timeout 5 \
     --header 'cookie: user=awesomeberry' \
     --max-time 5  \"http://\${GATEWAY_URL}/productpage\" \
     | grep -E '\bglyphicon-star\b|<font color=\"red\">' \
     | wc -l) -eq 12"

    test "deploy reviews v3"
    {

      ${APP} test/theseus/asset/reviews-deployment-v3.yaml \
        ${DEBUG_FLAG} \
        --cookie "^(.*?;)?(user=awesomeberry)(;.*)?$" \
        --test "${TEST_V3}"

      assert_success
    }

  #  test "Intentionally failing deploy"
  #  {
  #
  #    # intentionally failing deployment (service starts, healthchecks, fails after 5s)
  #    if ${APP} test/theseus/asset/bad-ghost-deployment.yaml \
  #      ${DEBUG_FLAG} \
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
  #    assert_success
  #  }

  success "test suite passed"
  trap - EXIT

}

try-slow-backoff() {
  _TRY_LIMIT_SLEEP=1
  _TRY_LIMIT_BACKOFF=8
  try-limit 0 "${@}"
}

try-limit() {
  local LIMIT=$1
  local COUNT=1
  local RETURN_CODE
  shift
  echo "Limit ${LIMIT}, trying: $*" 1>&2
  until eval $(echo $@); do
    RETURN_CODE=$?
    printf "\n$(date): %s - " "$*" 1>&2
    let COUNT=COUNT+1
    if [[ "${_TRY_LIMIT_BACKOFF:-}" != "" ]]; then
      sleep $(((COUNT * _TRY_LIMIT_BACKOFF) / 10))
    else
      sleep ${_TRY_LIMIT_SLEEP:-0.3}
    fi
    if [[ $LIMIT -gt 0 && $COUNT -gt $LIMIT ]]; then
      echo "Failed after $COUNT iterations" 1>&2
      return 1
    fi
  done
  RETURN_CODE=$?
  echo "Completed after $COUNT iterations" 1>&2
  unset _TRY_LIMIT_SLEEP _TRY_LIMIT_BACKOFF
  return $RETURN_CODE
}

function assert_success() {
  if [[ $? -eq 0 ]]; then
    success "PASS: ${THIS_TEST}"
  else
    error "FAIL: ${THIS_TEST}"
  fi
}

function assert_failure() {
  if [[ $? -gt 0 ]]; then
    success "PASS: ${THIS_TEST}"
  else
    error "FAIL: ${THIS_TEST}"
  fi
}

test() {
  THIS_TEST="${1}"
  info "TEST: ${THIS_TEST}" | tee ../../debug.log
  if [[ -n "${2:-}" ]]; then
    "${2}"
  fi
}

handle_arguments() {
  [[ $# = 0 && ${EXPECTED_NUM_ARGUMENTS} -gt 0 ]] && usage

  parse_arguments "$@"
  validate_arguments "$@"

  cd "${DIR}" >&2
  [[ -n "${LOCAL_ISTIO:-}" ]] && ../local-istio.sh >&2
  cd "${DIR}/.." >&2
  if [[ "${DEBUG:-0}" == 1 ]]; then
    DEBUG_FLAG='--debug'
  else
    DEBUG_FLAG=''
  fi

}

parse_arguments() {
  while [ $# -gt 0 ]; do
    case $1 in
      -h | --help) usage ;;
      --debug)
        DEBUG=1
        set -xe
        ;;
      -d | --description)
        shift
        not_empty_or_usage "${1:-}"
        DESCRIPTION="$1"
        ;;
      -t | --type)
        shift
        not_empty_or_usage "${1:-}"
        case $1 in
          bash) FILETYPE=bash ;;
          *) usage "Template type '$1' not recognised" ;;
        esac
        ;;
      --)
        shift
        break
        ;;
      -*) usage "$1: unknown option" ;;
      *) ARGUMENTS+=("$1") ;;
    esac
    shift
  done
}

validate_arguments() {
  [[ $EXPECTED_NUM_ARGUMENTS -gt 0 && -z ${FILETYPE:-} ]] && usage "Filetype required"

  check_number_of_expected_arguments

  [[ ${#ARGUMENTS[@]} -gt 0 ]] && FILENAME=${ARGUMENTS[0]} || true
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

# helper functions

usage() {
  [ "$*" ] && echo "${THIS_SCRIPT}: ${COLOUR_RED}$*${COLOUR_RESET}" && echo
  sed -n '/^##/,/^$/s/^## \{0,1\}//p' "${THIS_SCRIPT}" | sed "s/%SCRIPT_NAME%/$(basename "${THIS_SCRIPT}")/g"
  exit 2
} 2>/dev/null

success() {
  [ "${*:-}" ] && RESPONSE="$*" || RESPONSE="Unknown Success"
  printf "%s\n" "$(log_message_prefix)${COLOUR_GREEN}${RESPONSE}${COLOUR_RESET}"
} 1>&2

info() {
  [ "${*:-}" ] && INFO="$*" || INFO="Unknown Info"
  printf "%s\n" "$(log_message_prefix)${COLOUR_WHITE}${INFO}${COLOUR_RESET}"
} 1>&2

warning() {
  [ "${*:-}" ] && ERROR="$*" || ERROR="Unknown Warning"
  printf "%s\n" "$(log_message_prefix)${COLOUR_RED}${ERROR}${COLOUR_RESET}"
} 1>&2

error() {
  [ "${*:-}" ] && ERROR="$*" || ERROR="Unknown Error"
  printf "%s\n" "$(log_message_prefix)${COLOUR_RED}${ERROR}${COLOUR_RESET}"
  exit 3
} 1>&2

error_env_var() {
  error "${1} environment variable required"
}

log_message_prefix() {
  local TIMESTAMP="[$(date +'%Y-%m-%dT%H:%M:%S%z')]"
  local THIS_SCRIPT_SHORT=${THIS_SCRIPT/$DIR/.}
  tput bold 2>/dev/null
  echo -n "${TIMESTAMP} ${THIS_SCRIPT_SHORT}: "
}

is_empty() {
  [[ -z ${1-} ]] && return 0 || return 1
}

not_empty_or_usage() {
  is_empty ${1-} && usage "Non-empty value required" || return 0
}

check_number_of_expected_arguments() {
  [[ ${EXPECTED_NUM_ARGUMENTS} != ${#ARGUMENTS[@]} ]] && {
    ARGUMENTS_STRING="argument"
    [[ ${EXPECTED_NUM_ARGUMENTS} > 1 ]] && ARGUMENTS_STRING="${ARGUMENTS_STRING}"s
    usage "${EXPECTED_NUM_ARGUMENTS} ${ARGUMENTS_STRING} expected, ${#ARGUMENTS[@]} found"
  }
  return 0
}

hr() {
  printf '=%.0s' $(seq $(tput cols))
  echo
}

wait_safe() {
  local PIDS="${1}"
  for JOB in ${PIDS}; do
    wait "${JOB}"
  done
}

# colours
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

# invocation

main "$@"
