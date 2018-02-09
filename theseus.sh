#!/usr/bin/env bash
#
# Continuous Deployment for Kubernetes with Istio
#
# Andrew Martin, 2017-06-04 11:13:05
# sublimino@gmail.com
#
## Usage: %SCRIPT_NAME% filename [options]
##
## filename                      The target deployment YAML
##
## Options:
##   --tag [tag value]           Value to pod to route to (.metadata.labels, required)
##   --tag-name [tag name]       New tag of service to deploy (from .metadata.labels, default: version)
##   --weight [weight %age]      Percentage of traffic to redirect to tag
##   --precedence [precedence]   Precedence (default: 10)
##   --name [rule name]          Rule name (default: `destination`-test-`tag`)
##
##   --header [http header]      HTTP header to route on
##   --regex [regex]             An inclusion regex to apply to the HTTP header
##   --cookie [regex]            Implies `--header cookie --regex [regex]`
##   --user-agent [regex]        Implies `--header user-agent --regex [regex]`
##
##   --test-url [URL]            URL to test deployment by `curl`-ing for status 200
##   --test [eval]               Script or command to eval to test deployment
##                               The environment variable GATEWAY_URL is available
##                               e.g. --test "curl --fail \${GATEWAY_URL}"
##
##   --backup                    Backup existing deployment
##   --undeploy [name]           Name of deployment to remove
##   --delete                    Remove existing deployment and route
##
##   --debug                     More debug
##   --debug-file                Debug to /tmp/debug
##   --dry-run                   Dry-run; only show what would be done
##   -h --help                   Display this message
##

# exit on error or pipe failure
set -e
set -o pipefail
# error on clobber
set -o noclobber

# user defaults
DRY_RUN=0
DEBUG=${DEBUG:-0}
[[ "${DEBUG}" == 1 ]] && set -x

# resolved directory and self
declare -r DIR=$(cd "$(dirname "$0")" && pwd)
declare -r THIS_SCRIPT="${DIR}/$(basename "$0")"
declare -r RESOLVED_DIR=$(dirname $(readlink -f "${THIS_SCRIPT}"))

# required defaults
declare -a ARGUMENTS
EXPECTED_NUM_ARGUMENTS=1
ARGUMENTS=()
DEPLOYMENT_JSON=''
ISTIOCTL='istioctl'
FILENAME=''
RULE_FILE=''
TIMEOUT_PID=''

MIN_ISTIO_VERSION="0.2.10"

check_kubernetes_version() {
  if ! local KUBERNETES_VERSION=$(kubectl version --short \
    | awk '/Server Version:/{ print $3 }'); then
    error "Failed to get k8s version"
  fi
  if ! check_version v1.7.0 ${KUBERNETES_VERSION}; then
    error "kubectl version must be v1.5.7 or greater"
  fi
}

check_istio_version() {
  if ! local ISTIO_VERSION=$(istioctl version \
    | awk '/^Version:/{ print $2 }'); then
    error "Failed to get istio version"
  fi
  if ! check_version ${MIN_ISTIO_VERSION} ${ISTIO_VERSION}; then
    error "istioctl version must be v${MIN_ISTIO_VERSION} or greater. '${ISTIO_VERSION}' found"
  fi
}

set_timeout() {
  local TIMEOUT_LENGTH=${TIMEOUT_LENGTH:-300}
  local PARENT_SHELL=${BASHPID}
  sleep ${TIMEOUT_LENGTH} && {
    warning "Timeout reached after ${TIMEOUT_LENGTH}s"
    kill -- -$(ps -o pgid= ${PARENT_SHELL} | grep -o '[0-9]*')
    #    kill -TERM -- -${PARENT_SHELL}
  } &

  TIMEOUT_PID=$!

  local SLEEP_LENGTH=${TIMEOUT_TEST_DELAY_LENGTH:-0}
  if [[ ${SLEEP_LENGTH} -gt 0 ]]; then
    warning "Timeout test delay invoked: ${SLEEP_LENGTH}"
    sleep ${SLEEP_LENGTH}
  fi
}

main() {
  # TODO: this doesn't work as a system-wide binary
  cd "${RESOLVED_DIR}"

  handle_arguments "$@"

  #  set_timeout

  check_kubernetes_version
  check_istio_version

  if [[ -n "${BACKUP_TARGET:-}" ]]; then
    backup_resource
  fi

  # TODO: merge autoscaler with rollout monitor
  check_for_autoscaler

  if [[ "${IS_DELETE:-}" == 1 ]]; then
    delete_route_and_deployment
    exit 0
  fi

  RULE_FILE=$(mktemp /tmp/$$-XXXXXX.tmp)
  if [[ -n "${RULE_PRECEDENCE:-}" ]]; then
    generate_route_yaml "${RULE_FILE}"
  else
    # TODO: hack. Check for highest precedence and set higher
    local USER_RULE_PRECEDENCE="${RULE_PRECEDENCE}"
    local HIGHEST_PRECEDENCE=$(get_highest_precedence)
    RULE_PRECEDENCE=$((HIGHEST_PRECEDENCE + 1))
    generate_route_yaml "${RULE_FILE}"
    RULE_PRECEDENCE="${USER_RULE_PRECEDENCE}"
  fi

  trap 'rollback' EXIT

  deploy_resource "${FILENAME}"

  if ! wait_for_deployment "${FILENAME}"; then
    warning "Deployment failed, rolling back"
    rollback
    error "Deployment failed"
  fi

  deploy_rule_safe "${RULE_FILE}"

  if ! test_resource; then
    warning "Test failed, rolling back"
    rollback
    error "Deployment failed"
  fi

  deploy_rule_full_rollout

  if ! test_resource; then
    warning "Test failed during full rollout, rolling back"
    rollback
    error "Deployment failed"
  fi

  undeploy_previous_deployment

  trap - EXIT

  undeploy_deployment

  success "Deployment of ${FILENAME} succeeded in ${SECONDS}s"
  exit 0
}

deploy_rule_full_rollout() {
  local DEPLOYMENT_NAME
  local ROLL_OUT_RULE_FILE

  ROLL_OUT_RULE_FILE=$(mktemp /tmp/$$-XXXXXX.tmp)
  DEPLOYMENT_NAME=$(get_name_from_resource "${FILENAME}")

  info "Updating route rule for 100% traffic to ${DEPLOYMENT_NAME}"

  # TODO: hack to save updating the previous rule's precedence
  local HIGHEST_PRECEDENCE
  HIGHEST_PRECEDENCE=$(get_highest_precedence)
  RULE_PRECEDENCE=$((HIGHEST_PRECEDENCE + 1))

  generate_route_yaml_full_rollout "${ROLL_OUT_RULE_FILE}"
  deploy_rule_safe "${ROLL_OUT_RULE_FILE}"
}

rollback() {
  trap - EXIT
  warning "Performing rollback"
  warning "Jobs: $(jobs)"
#  warning "Debubg: $(ps fauxwww)"
  if [[ -n "${TIMEOUT_PID:-}" ]] && pgrep "${TIMEOUT_PID}"; then
    kill "${TIMEOUT_PID}"
  fi
  delete_route_and_deployment
  warning "Rollback complete"
  cat "${DIR}"/debug.log
  exit 1
}

backup_resource() {
  if [[ -n "${BACKUP_TARGET:-}" ]]; then
    info "Backing up ${BACKUP_TARGET}"
    BACKUP_DIR=~/.config/theseus
    BACKUP_FILE="${BACKUP_DIR}/${BACKUP_TARGET}.yaml"
    if [[ -f "${BACKUP_FILE}" ]]; then
      error "File '${BACKUP_FILE}' already exists"
    fi
    if [[ ! -d "${BACKUP_DIR}" ]]; then
      mkdir -p "${BACKUP_DIR}"
    fi
    if [[ "${DRY_RUN:-}" == 1 ]]; then
      touch "${BACKUP_FILE}"
    elif kubectl get deployments "${BACKUP_TARGET}" 2>/dev/null; then
      kubectl get deployment --export -o yaml "${BACKUP_TARGET}" >"${BACKUP_FILE}"
    else
      error "Backup target '$BACKUP_TARGET' not found"
    fi
  fi
}

check_for_autoscaler() {
  local DEPLOYMENT_NAME=$(get_name_from_resource "${FILENAME}")
  if [[ "${DRY_RUN:-}" == 0 ]] && kubectl get horizontalpodautoscaler "${DEPLOYMENT_NAME}" 2>/dev/null; then
    error "horizontalpodautoscaler active"
  fi
}

is_rule_deployed() {
  local RULE_NAME="${1:-}"
  is_not_empty_or_null "${RULE_NAME}"
  [[ $(${ISTIOCTL} get routerule "${RULE_NAME}" 2>/dev/null) != 'No resources found.' ]]
}

delete_route_and_deployment() {
  local DEPLOYMENT_NAME=$(get_name_from_resource "${FILENAME}")
  info "Deleting rule and deployment for ${DEPLOYMENT_NAME}"

  check_for_autoscaler

  if [[ "${DRY_RUN:-}" == 0 ]] && is_rule_deployed "${RULE_NAME}"; then
    ${ISTIOCTL} --namespace "${NAMESPACE}" delete routerule "${RULE_NAME}"
  fi

  if [[ -z "${DEPLOYMENT_NAME:-}" ]]; then
    error "No deployment found in '${FILENAME}'"
  elif [[ "${DRY_RUN:-}" == 0 ]] && kubectl get deployments "${DEPLOYMENT_NAME}" 2>/dev/null; then
    kubectl delete --namespace "${NAMESPACE}" -f "${FILENAME}"
    success "${FILENAME} deleted"
  else
    warning "Deployment '${DEPLOYMENT_NAME}' from '${FILENAME}' not found in cluster"
  fi
}

generate_route_yaml() {
  local TEMP_FILE="${1}"
  local IS_FULL_ROLLOUT="${2:-0}"
  local RULE_NAME="${3:-${RULE_NAME}}"
  local ROUTE_YAML=""

  info "Generating route yaml in ${TEMP_FILE}"
  ROUTE_YAML=$(generate_route_rule "${IS_FULL_ROLLOUT}")

  echo "${ROUTE_YAML}" >>"${TEMP_FILE}"

  info "Route YAML:"
  info "${ROUTE_YAML}"
}

generate_route_yaml_full_rollout() {
  local TEMP_FILE="${1}"

  generate_route_yaml "${TEMP_FILE}" 1 "${SELECTOR_APP}-${TAG}"
}

undeploy_previous_deployment() {
  # TODO: remote route rules and previous deployment
  :
}

undeploy_deployment() {
  if [[ -n "${UNDEPLOY_TARGET:-}" ]]; then
    local RESULT=''
    if [[ -f "${UNDEPLOY_TARGET}" ]]; then
      info "Undeploying file ${UNDEPLOY_TARGET}"
      RESULT=$(kubectl delete -f "${UNDEPLOY_TARGET}" 2>&1) || warning "Undeploy failed: ${RESULT}"
    elif [[ $(echo "${UNDEPLOY_TARGET}" | wc -l) -eq 1 ]]; then
      info "Undeploying deployment ${UNDEPLOY_TARGET}"
      RESULT=$(kubectl delete deployment "${UNDEPLOY_TARGET}" 2>&1) || warning "Undeploy failed: ${RESULT}"
    else
      info "Undeploying STDIN"
      RESULT=$(echo "${UNDEPLOY_TARGET}" | kubectl delete -f - 2>&1) || warning "Undeploy failed: ${RESULT}"
    fi
  fi

  # TODO: wait_for_undeployment
}

deploy_rule_safe() {
  local COUNT=0
  local MAX_ATTEMPTS=3
  local RULE_DEPLOYED=0

  while [[ "${RULE_DEPLOYED}" == 0 ]] && [[ "${COUNT}" -lt "${MAX_ATTEMPTS}" ]]; do
    COUNT=$((COUNT + 1))
    if deploy_rule "${@}"; then
      RULE_DEPLOYED=1
    else
      warning "Deploy rule failed attempt ${COUNT} of ${MAX_ATTEMPTS}"
      sleep $((COUNT * 3))
    fi
  done

  if [[ "${RULE_DEPLOYED}" != 1 ]]; then
    error "deploy_rule_safe failed"
  fi
}

deploy_rule() {
  local RULE_FILE="${1}"
  local COMMAND=""
  local FULL_COMMAND=""
  local SLEEP=10

  if [[ "${DRY_RUN:-}" == 1 ]]; then
    COMMAND='echo'
  fi

  is_not_empty_or_null "${RULE_NAME-}" || error "Rule name not populated: ${NAME}"

  info "Rule contents:"
  info "$(cat "${RULE_FILE}")"

  local OUTPUT
  if is_rule_deployed "${RULE_NAME}"; then
    info "Replacing rule ${RULE_NAME}"
    FULL_COMMAND="${COMMAND} ${ISTIOCTL} replace --namespace "${NAMESPACE}" -f "${RULE_FILE}""
    if ! OUTPUT=$(${FULL_COMMAND}); then
      warning "Deploy replace rule failed: ${OUTPUT}"
      return 1
    fi
  else
    info "Creating rule ${RULE_NAME}"
    FULL_COMMAND="${COMMAND} ${ISTIOCTL} create --namespace "${NAMESPACE}" -f "${RULE_FILE}""
    if ! OUTPUT=$(${FULL_COMMAND}); then
      warning "Deploy create rule failed: ${OUTPUT}"
      return 1
    fi
  fi

  success "$(printf "%s" "${OUTPUT}" | tr '\n' ',')"

  # TODO: get all rules, then those just deployed
  #  ${ISTIOCTL} get routerules -o yaml

  if [[ "${DRY_RUN:-}" == 1 ]]; then
    SLEEP=0
  fi

  success "Rule '${RULE_NAME}' created. Sleeping ${SLEEP}s for propagation"
  sleep "${SLEEP}"
}

wait_for_deployment() {
  local COUNT=0
  local READY_COUNT=0
  local SUCCESS_COUNT=15
  local COUNT_DELAY=0.2
  local STATE
  local NAME
  local REPLICA_COUNT

  if ! NAME=$(get_name_from_resource "${FILENAME}"); then
    error "Could not find name in ${FILENAME}"
  fi
  is_not_empty_or_null "${NAME-}" || error "Resource name not populated: ${NAME}"

  if ! REPLICA_COUNT=$(get_replica_count_from_resource "${FILENAME}"); then
    error "Could not get replica count"
  fi
  is_not_empty_or_null "${REPLICA_COUNT-}" || error "Replica count not populated: ${REPLICA_COUNT}"

  info "Waiting for available replicas on deployment ${NAME} for ready count of ${SUCCESS_COUNT}"
  until [[ "${READY_COUNT}" -gt "${SUCCESS_COUNT}" ]] || [[ "${DRY_RUN}" == 1 ]]; do
    COUNT=$((COUNT + 1))
    local DEPLOYMENT_STATE=$(kubectl get deployment "${NAME}" -o json)
    STATE="$(echo "${DEPLOYMENT_STATE}" | jq -r '.status | "\(.conditions[].status) \(.availableReplicas) \(.unavailableReplicas)"')"

    if [[ ${READY_COUNT} == 1 ]] || [[ (${READY_COUNT} -gt 0 && $((READY_COUNT % 5)) == 0) ]]; then
      info "Ready count: ${READY_COUNT}"
    fi

    if [[ "${STATE}" == "True ${REPLICA_COUNT} null" ]]; then
      READY_COUNT=$((READY_COUNT + 1))
    elif [[ "$READY_COUNT" -gt 1 ]]; then
      warning "Deployment went from ready to not-ready, failing"
      return 1
    elif [[ "${COUNT}" -gt 50 ]]; then
      warning "Deployment failed to be ready with replica count ${REPLICA_COUNT} and no unavailable replicas. Was: ${STATE}"
      warning "$(kubectl get deployment "${NAME}")"
      warning "$(kubectl describe deployment "${NAME}")"
      return 1
    fi
    sleep "${COUNT_DELAY}"
  done

  success "Deployment ${NAME} is ready"
}

deploy_resource() {
  local DEPLOYMENT_FILE="${1}"
  local RESOURCE_YAML

  info "Deploying ${DEPLOYMENT_FILE}"

  #TODO: allow bypass for this function

  if is_gke; then
    RANGES=$(gcloud container clusters describe \
      $(kubectl config current-context \
        | cut -d'_' -f 3- \
        | awk -F_ '{print $2" --zone="$1}') \
      | grep -e clusterIpv4Cidr -e servicesIpv4Cidr \
      | cut -d' ' -f2 \
      | xargs \
      | tr ' ' ',')
  else
    RANGES=10.0.0.1/24
  fi

  info "Deploying resource with sidecar bypass IP ranges: ${RANGES//,/ }"

  if ! RESOURCE_YAML=$(
    ${ISTIOCTL} kube-inject --namespace "${NAMESPACE}" \
      -f "${DEPLOYMENT_FILE}" \
      --includeIPRanges="${RANGES}" \
      | sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g ; s/"imagePullPolicy":"Always"/"imagePullPolicy":"IfNotPresent"/g'
  ); then
    error "Failed to inject istio sidecar"
  fi

  local OUTPUT

  if [[ "${DRY_RUN:-}" == 1 ]]; then
    info "RESOURCE_YAML:"
    echo "$RESOURCE_YAML"
    OUTPUT="Faked deployment"
  else
    local
    if ! OUTPUT=$(echo "${RESOURCE_YAML}" | kubectl apply -f -); then
      error "Deploy resource failed: ${OUTPUT}"
    fi
  fi

  while read LINE; do
    success "${LINE}"
  done <<<"${OUTPUT}"
}

is_gke() {
  if [[ $(kubectl config current-context | grep -E '^gke_' -c) -gt 0 ]]; then
    return 0
  fi
  return 1
}

get_gateway_url() {
  # TODO(0.2.4): fix as per https://github.com/istio/issues/issues/67
  local GATEWAY_URL=$(kubectl get po -l istio=ingress -o 'jsonpath={.items[0].status.hostIP}'):$(kubectl get svc istio-ingress -o 'jsonpath={.spec.ports[0].nodePort}')

  if [[ -z "${GATEWAY_URL:-}" ]] || is_gke; then
    info "GKE detected, getting gateway ingress IP"
    GATEWAY_URL=$(kubectl get ingress gateway -o 'jsonpath={.status.loadBalancer.ingress[].ip}')
    COUNT=0

    until [[ -n ${GATEWAY_URL} ]]; do
      let COUNT=$((COUNT + 1))
      [[ "$COUNT" -gt 100 ]] && {
        error "Timeout getting gateway URL"
      }
      sleep 5
      GATEWAY_URL=$(kubectl get ingress gateway -o 'jsonpath={.status.loadBalancer.ingress[].ip}')
    done
  fi

  info "Gateway URL is: '${GATEWAY_URL}'"
  echo "${GATEWAY_URL}"
}

wait_for_url() {
  local URL="${1}"
  local START_SECONDS="${SECONDS}"
  local TIMEOUT=100
  local DELAY=3
  local DURATION=0
  local COUNT=0

  local CURL_COMMAND="curl -v -o /dev/null -s \
    -w '%{http_code}' \
    --header '${HTTP_HEADER}: ${HTTP_HEADER_REGEX}' \
    ${URL}"

  info "Waiting for ${URL} to return 200 via ${CURL_COMMAND}"

  until [[ $(curl -o /dev/null -s \
    -w '%{http_code}' \
    --header "${HTTP_HEADER}: ${HTTP_HEADER_REGEX}" \
    ${URL}) == 200 ]]; do

    let DURATION=$((SECONDS - START_SECONDS))
    let COUNT=$((COUNT + 1))
    [[ "$COUNT" -gt "${TIMEOUT}" ]] && {
      # TODO: show failed curl headers here
      error "Timed out after ${DURATION}s waiting for ${URL} to return 200"
      exit 1
    }
    warning "Waiting for ${URL} to return 200 for ${DURATION}s/$((DELAY * TIMEOUT))s..."
    sleep "${DELAY}"
  done
  success "Got 200 from ${URL}"
}

test_resource() {
  if [[ "${DRY_RUN:-}" == 1 ]]; then
    return 0
  fi
  local MAX_ATTEMPTS=10
  local START_SECONDS="${SECONDS}"
  local DURATION=0
  export GATEWAY_URL=$(get_gateway_url)
  [[ -n "${GATEWAY_URL}" ]]

  if [[ -z "${TEST_EVAL:-}" ]]; then
    TEST_EVAL="wait_for_url ${TEST_URL:-${GATEWAY_URL}}"
  fi

  info "Test command is: ${TEST_EVAL:-}"

  local INTERPOLATED_TEST_EVAL=$(
    envsubst <<EOF
${TEST_EVAL:-}
EOF
  )
  success "Interpolated test command is: ${INTERPOLATED_TEST_EVAL}"

  for BACKOFF in $(seq 1 ${MAX_ATTEMPTS}); do
    sleep $((3 * BACKOFF))
    info "Running test command ${BACKOFF}/${MAX_ATTEMPTS}"
    local RESULT=$(eval "${TEST_EVAL:-}")
    local STATUS_CODE=$?
    if [[ "$STATUS_CODE" -eq 0 ]]; then
      break
    fi
    info "Test command failed ${BACKOFF}/${MAX_ATTEMPTS}"
    info "Result: ${RESULT}"
  done

  unset GATEWAY_URL
  let DURATION='SECONDS - START_SECONDS' || true
  if [[ "${STATUS_CODE}" == 0 ]]; then
    success "Test succeeded in ${DURATION}s on attempt ${BACKOFF}/${MAX_ATTEMPTS}"
  else
    warning "Test failed in ${DURATION}s after ${BACKOFF} attempts"
  fi
  return "${STATUS_CODE}"
}

validate_arguments() {
  FILENAME="${ARGUMENTS[0]:-}"

  [[ -z "${FILENAME:-}" ]] && error "Filename required"
  [[ ! -f "${FILENAME:-}" ]] && error "File ${FILENAME} not found"

  [[ -n "${HTTP_HEADER_REGEX:-}" && -z "${HTTP_HEADER:-}" ]] && error "--header required with --regex"

  if [[ -n "${BACKUP_TARGET:-}" ]]; then
    [[ "${BACKUP_TARGET:0:1}" == "-" ]] && error "Invalid backup target: '${BACKUP_TARGET}'"
  fi

  SELECTOR_APP=$(get_key_from_resource "${FILENAME}" '.spec.template.metadata.labels.app')
  if ! is_not_empty_or_null "${SELECTOR_APP:-}"; then
    error "Selector not found in ${FILENAME}"
  fi
  TAG_NAME="${TAG_NAME:-version}"

  if [[ -z "${TAG:-}" ]]; then
    TAG=$(get_key_from_resource "${FILENAME}" ".spec.template.metadata.labels.${TAG_NAME}")
  fi

  if [[ -z "${RULE_NAME:-}" ]]; then
    RULE_NAME="${SELECTOR_APP}-${TAG}"
  fi

  if [[ "${IS_DELETE:-}" != 1 && -z "${HTTP_HEADER:-}" ]]; then
    usage "An HTTP_HEADER value (--header & --regex, or --cookie) is required to route canary-test traffic."
  fi

  RULE_PRECEDENCE="${RULE_PRECEDENCE:-}"

  NAMESPACE='default'

  DESTINATION="${SELECTOR_APP}"

  check_number_of_expected_arguments
}

get_deployment_json() {
  if [[ -z "${DEPLOYMENT_JSON:-}" ]]; then
    DEPLOYMENT_JSON=$(kubectl convert -f "${FILENAME}" --local=true -o json 2>/dev/null)
  fi
  if [[ -z "${DEPLOYMENT_JSON:-}" ]]; then
    error "Deployment JSON for ${FILENAME} is empty"
  fi
  echo "${DEPLOYMENT_JSON}"
}

get_matching_route_rules() {
  local ROUTE_NAME="${1}"
  info "Getting matching route rules for ${ROUTE_NAME}"
  for RULE in $(${ISTIOCTL} get routerules | awk "/^${ROUTE_NAME}-/{print \$1}" | sort); do
    echo '---'
    info "Found rule: ${RULE}"
    ${ISTIOCTL} get routerules "${RULE}" -o yaml
  done
}

get_highest_precedence() {
  local HIGHEST_PRECEDENCE=$(get_matching_route_rules "${SELECTOR_APP}" \
    | awk '/precedence:/{print $2}' \
    | sort --numeric \
    | tail -n 1)
  echo "${HIGHEST_PRECEDENCE}"
}

generate_route_rule() {

  local IS_FULL_ROLLOUT="${1:-0}"
  local RULE_NAME="${2:-${RULE_NAME}}"
  local MATCH_RULE=''
  local WEIGHT=''

  info "Generating route rule for full rollout with precedence ${RULE_PRECEDENCE}"

  if [[ "${IS_FULL_ROLLOUT:-}" == 1 ]]; then
    WEIGHT="weight: 100"
  else
    read -r -d '' MATCH_RULE <<-EOF
  match:
    request:
      headers:
        ${HTTP_HEADER}:
          regex: "${HTTP_HEADER_REGEX}"
EOF
  fi

  cat <<-EOF
apiVersion: config.istio.io/v1alpha2
kind: RouteRule
metadata:
  name: ${RULE_NAME}
  namespace: ${NAMESPACE}
spec:
  destination:
    name: ${DESTINATION}
  precedence: ${RULE_PRECEDENCE}
  ${MATCH_RULE}
  route:
  - labels:
      version: ${TAG}
    ${WEIGHT}
EOF

}

is_multi_document_resource() {
  local FILE="${1}"
  [[ -f "${FILE}" ]] || error "File ${FILE} not found"
  local JSON=$(kubectl convert -f "${FILE}" --local=true -o json 2>/dev/null)
  echo "${JSON}" | is_multi_document_json
}

is_multi_document_json() {
  [[ $(jq -r '.kind') == 'List' ]]
}

get_key_from_resource() {
  local FILE="${1}"
  local SELECTOR="${2}"
  local RESOURCE_TYPE="${3:-Deployment}"
  info "Querying resource ${FILE} for ${SELECTOR}"
  local JSON=$(kubectl convert -f "${FILE}" --local=true -o json 2>/dev/null)
  local RESULT
  if echo "${JSON}" | is_multi_document_json; then
    local DOCUMENT_SELECTOR=".items[] | select(.kind == \"${RESOURCE_TYPE}\")"
    local DOCUMENT_COUNT=$(echo "${JSON}" | jq -r "${DOCUMENT_SELECTOR} | .kind" | wc -l)

    if [[ "${DOCUMENT_COUNT}" != 1 ]]; then
      error "Ambiguous document: must provide exactly 1 ${RESOURCE_TYPE}s, ${DOCUMENT_COUNT} found."
    fi
    JSON=$(echo "${JSON}" | jq -r "${DOCUMENT_SELECTOR}")
  fi

  RESULT=$(echo "${JSON}" | jq -r "${SELECTOR}")
  is_not_empty_or_null "${RESULT-}" || error 'No key found'
  info "${SELECTOR}: ${RESULT}"
  echo "${RESULT}"
}

get_name_from_resource() {
  local FILE="${1}"
  get_key_from_resource "${FILE}" .metadata.name
}

get_replica_count_from_resource() {
  local FILE="${1}"
  get_key_from_resource "${FILE}" .spec.replicas
}

handle_arguments() {
  [[ $# = 0 && ${EXPECTED_NUM_ARGUMENTS} -gt 0 ]] && usage

  parse_arguments "$@"
  validate_arguments "$@"
}

parse_arguments() {
  while [ $# -gt 0 ]; do
    case $1 in
      --tag)
        shift
        not_empty_or_usage "${1:-}"
        TAG="$1"
        ;;
      --tag-name)
        shift
        not_empty_or_usage "${1:-}"
        TAG_NAME="$1"
        ;;
      --weight)
        shift
        not_empty_or_usage "${1:-}"
        ROUTE_WEIGHT="$1"
        ;;
      --precedence)
        shift
        not_empty_or_usage "${1:-}"
        RULE_PRECEDENCE="$1"
        ;;
      --name)
        shift
        not_empty_or_usage "${1:-}"
        RULE_NAME="$1"
        ;;
      --header)
        shift
        not_empty_or_usage "${1:-}"
        HTTP_HEADER="$1"
        ;;
      --regex)
        shift
        not_empty_or_usage "${1:-}"
        HTTP_HEADER_REGEX="$1"
        ;;
      --cookie)
        shift
        not_empty_or_usage "${1:-}"
        HTTP_HEADER="cookie"
        HTTP_HEADER_REGEX="$1"
        ;;
      --user-agent)
        shift
        not_empty_or_usage "${1:-}"
        HTTP_HEADER="user-agent"
        HTTP_HEADER_REGEX="$1"
        ;;
      --test)
        shift
        not_empty_or_usage "${1:-}"
        TEST_EVAL="$1"
        ;;
      --test-url)
        shift
        not_empty_or_usage "${1:-}"
        TEST_URL="$1"
        ;;
      --delete)
        IS_DELETE="1"
        ;;
      --backup)
        shift
        not_empty_or_usage "${1:-}"
        BACKUP_TARGET="$1"
        ;;
      --undeploy)
        shift
        not_empty_or_usage "${1:-}"
        UNDEPLOY_TARGET="$1"
        ;;
      --timeout)
        shift
        not_empty_or_usage "${1:-}"
        TIMEOUT_LENGTH="$1"
        ;;
      --timeout-test-delay)
        shift
        not_empty_or_usage "${1:-}"
        TIMEOUT_TEST_DELAY_LENGTH="$1"
        ;;
      -n | --dry-run) DRY_RUN=1 ;;
      -h | --help) usage ;;
      --debug)
        DEBUG=1
        set -xe
        ;;
      --debug-file)
        DEBUG=1
        set -xe
          # exec 2> >(tee --ignore-interrupts /tmp/debug >/dev/null)
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

# helper functions

usage() {
  [ "$*" ] && echo "${THIS_SCRIPT}: ${COLOUR_RED}$*${COLOUR_RESET}" && echo
  sed -n '/^##/,/^$/s/^## \{0,1\}//p' "${THIS_SCRIPT}" | sed "s/%SCRIPT_NAME%/$(basename ${THIS_SCRIPT})/g"
  exit 2
} 2>/dev/null

success() {
  [ "${@:-}" ] && RESPONSE="$@" || RESPONSE="Unknown Success"
  printf "$(log_message_prefix)${COLOUR_GREEN}%s${COLOUR_RESET}\n" "${RESPONSE}" | tee -a "${DIR}"/debug.log
} 1>&2

info() {
  [ "${@:-}" ] && INFO="$@" || INFO="Unknown Info"
  printf "$(log_message_prefix)${COLOUR_WHITE}%s${COLOUR_RESET}\n" "${INFO}" | tee -a "${DIR}"/debug.log
} 1>&2

warning() {
  [ "${@:-}" ] && ERROR="$@" || ERROR="Unknown Warning"
  printf "$(log_message_prefix)${COLOUR_RED}%s${COLOUR_RESET}\n" "${ERROR}" | tee -a "${DIR}"/debug.log
} 1>&2

error() {
  [ "${@:-}" ] && ERROR="$@" || ERROR="Unknown Error"
  printf "$(log_message_prefix)${COLOUR_RED}%s${COLOUR_RESET}\n" "${ERROR}" | tee -a "${DIR}"/debug.log
  exit 3
} 1>&2

error_env_var() {
  error "${1} environment variable required. Use --slurp-credentials if local"
}

log_message_prefix() {
  local TIMESTAMP="[$(date +'%Y-%m-%dT%H:%M:%S:%3N%z')]"
  local THIS_SCRIPT_SHORT=${THIS_SCRIPT/$DIR/.}
  tput bold 2>/dev/null
  echo -n "${TIMESTAMP} ${THIS_SCRIPT_SHORT}: "
}

is_not_empty_or_null() {
  [[ -z ${1-} ]] && return 1
  [[ "${1}" == 'null' ]] && return 1
  return 0
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

wait-safe() {
  local PIDS="${1}"
  for JOB in ${PIDS}; do
    wait "${JOB}"
  done
}

# TODO: beware prefixed v on v1.2.3
check_version() {
  local MIN_VERSION="${1#v}"
  local ACTUAL_VERSION="${2#v}"
  local LOWEST_VERSION=$(
    {
      echo $MIN_VERSION
      echo $ACTUAL_VERSION
    } \
      | sort --version-sort \
      | head -n1
  )
  [[ "${LOWEST_VERSION}" == "${MIN_VERSION}" ]]
}

is_sourced() {
  [[ "${BASH_SOURCE[0]}" != "${0}" ]]
}

# invocation

if ! is_sourced; then
  # error on unset variable
  set -o nounset

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

  echo | tee -a "${DIR}"/debug.log
  success "Starting theseus" &>/dev/null

  main "$@"
fi
