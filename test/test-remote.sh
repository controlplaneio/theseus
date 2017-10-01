#!/usr/bin/env bash
# Andrew Martin, 2017-06-22 08:34:04
# sublimino@gmail.com

# exit on error or pipe failure
set -eo pipefail
# error on unset variable
set -o nounset
# error on clobber
set -o noclobber

set -x

# resolved directory and self
declare -r DIR=$(cd "$(dirname "$0")" && pwd)
declare -r THIS_SCRIPT="${DIR}/$(basename "$0")"

CLUSTER_NAME="test-theseus"
DEFAULT_PROJECT="binarysludge-20170716-2"
DEFAULT_ZONE="europe-west2-a"
PREEMPTIBLE="--preemptible"
CLUSTER_VERSION="1.7.5"

check_for_gcloud() {
  if ! command gcloud &>/dev/null; then
    source /dev/stdin < <(grep google-cloud-sdk ~/.bashrc)
  fi
}

check_for_service_account() {
  if [[ "${GCLOUD_AUTH_BASE64:-}" != '' ]]; then
    echo "${GCLOUD_AUTH_BASE64}" | base64 --decode | tee "${DIR}/account.json" >/dev/null
    gcloud auth activate-service-account --key-file "${DIR}/account.json"
  fi
}

check_for_project() {
  gcloud config get-value project
  if [[ $(gcloud config get-value project) == '' ]]; then
    export CLOUDSDK_CORE_PROJECT="${DEFAULT_PROJECT}"
  fi
  true
}

check_for_zone() {
  gcloud config get-value compute/zone
  if [[ $(gcloud config get-value compute/zone) == '' ]]; then
    export CLOUDSDK_COMPUTE_ZONE="${DEFAULT_ZONE}"
  fi
  true
}

check_for_kubectl_project() {
  local CURRENT_CONTEXT=$(kubectl config current-context)
  if ! echo "${CURRENT_CONTEXT}" | grep -E '^gke_'; then
    info "Current project is not on gke: '${CURRENT_CONTEXT}'"
    sleep 5
  fi
}

get_master_versions() {
  local MASTER_VERSIONS=$(gcloud container get-server-config --format json \
    | jq -r '.validMasterVersions []' \
    | tr '\n' ',')
  MASTER_VERSIONS="${MASTER_VERSIONS%,}"
  echo "${MASTER_VERSIONS}"
}

deploy_cluster() {
  local OUTPUT
  if ! OUTPUT=$( (yes || true) | gcloud container clusters create "${CLUSTER_NAME}" \
    --machine-type n1-highcpu-8 \
    --enable-autorepair \
    ${PREEMPTIBLE} \
    --cluster-version=${CLUSTER_VERSION} \
    --num-nodes 2 2>&1); then

    if echo "${OUTPUT}" | grep 'Version is invalid.' &>/dev/null; then
      local MASTER_VERSIONS=$(get_master_versions)
      error "Version ${CLUSTER_VERSION} is invalid. Master versions: ${MASTER_VERSIONS} - PLEASE UPGRADE"
    elif [[ -n "${CI:-}" ]] && echo "${OUTPUT}" | grep 'currently upgrading cluster' &>/dev/null; then
      local MASTER_VERSIONS=$(get_master_versions)
      warning "Cluster being upgraded from ${CLUSTER_VERSION}. Master versions: ${MASTER_VERSIONS} - PLEASE UPGRADE"
      warning "Waiting to try again"
      sleep 20
      deploy_cluster

      return 0
    elif [[ -n "${CI:-}" ]] && echo "${OUTPUT}" | grep 'already exists.' &>/dev/null; then
      warning "Cluster already exists. Deleting and redeploying"
      sleep 5

      delete_cluster
      deploy_cluster

      return 0
    elif [[ "${PREEMPTIBLE:-}" != "" ]]; then
      warning "Failed to create cluter. Re-attempting with PREEMPTIBLE disabled"
      PREEMPTIBLE=""
      deploy_cluster

      return 0
    fi

    if [[ "${PERSIST_CLUSTER:-}" != '1' ]]; then
      error "Failed to create cluster"
    fi
    info "Failed to create cluster, continuing as as PERSIST_CLUSTER is non-empty"
  fi

  gcloud container clusters get-credentials "${CLUSTER_NAME}"
}

delete_cluster() {
  local OUTPUT
  if ! OUTPUT=$( (yes || true) | gcloud container clusters delete "${CLUSTER_NAME}" 2>&1); then
    if echo "${OUTPUT}" | grep "Please wait and try again once it's done." &>/dev/null; then
      sleep 5
      delete_cluster
      return 0
    else
      error "Failed to delete cluster"
    fi
  fi
}

deploy_istio() {
  ../local-istio.sh
}

_debug_time() {
  echo "${BASH_SOURCE[0]} running for ${SECONDS}s ($((SECONDS / 60)) minutes)^[[0m" >&2
}

check_for_istioctl() {
  # this is for cleanup.sh
  if ! which istioctl &>/dev/null; then
    local ISTIO_DIR=$(cd .. && find . -maxdepth 1 -type d -regex './istio-[0-9\.]+' | sort -g | tail -n 1)
    export PATH="${PATH}:$(pwd)/../${ISTIO_DIR}/bin"

    if ! which istioctl &>/dev/null; then
      error "istioctl not found"
    fi
  fi
}

main() {

  cd "${DIR}"

  check_for_istioctl

  _debug_time

  check_for_gcloud
  check_for_service_account
  check_for_project
  check_for_zone
  check_for_kubectl_project

  _debug_time

  trap cleanup EXIT

  deploy_cluster

  _debug_time

  deploy_istio

  _debug_time

  #   ./test-theseus.sh

  _debug_time

  DEBUG=0 ./test-acceptance.sh

  _debug_time

  success "Tests passed"1
}

cleanup() {

  if [[ -n "${CI_JOB_ID:-}" ]]; then
    local DEBUG_LOG_NAME="../debug-${CI_JOB_ID}.log"
    printf "" | tee "${DEBUG_LOG_NAME}"
    cat ../debug.log | sed '/^    /d' >>"${DEBUG_LOG_NAME}"
  fi

  # set +x
  # exit on error or pipe failure
  set +eo pipefail
  # error on unset variable
  set +o nounset
  # error on clobber
  set +o noclobber

  if [[ "${PERSIST_CLUSTER:-}" != '1' ]]; then
    delete_cluster

    gcloud compute firewall-rules list --filter "TARGET_TAGS : gke-${CLUSTER_NAME}-" \
      | awk "/gke-${CLUSTER_NAME}-/{print \$1}" \
      | sort -u \
      | xargs --no-run-if-empty -I{} bash -c "(yes || true) | gcloud compute firewall-rules delete {}"

    gcloud compute routes list \
      | awk "/^gke-test-theseus/{print \$1}" \
      | sort -u \
      | xargs --no-run-if-empty -n1 -I{} bash -c "(yes || true) | gcloud compute routes delete"

    cleanup_target_pools

    #    wait_safe
  fi

  rm -rf ${DIR}/account.json
}

cleanup_target_pools() {
  # clean LB artefacts
  while read TARGET_POOL_FULL; do
    [[ -z "${TARGET_POOL_FULL:-}" ]] && continue
    TARGET_POOL="${TARGET_POOL_FULL/ */}"

    DEL=0
    if ! gcloud compute target-pools describe ${TARGET_POOL_FULL}; then
      DEL=1
    elif gcloud compute target-pools describe ${TARGET_POOL_FULL} \
      | grep --color=auto "gke-${CLUSTER_NAME}"; then
      DEL=1
    fi

    if [[ "${DEL}" == 1 ]]; then
      echo "DELETING ${TARGET_POOL} and associated forwarding rules"
      while read LINE; do
        gcloud compute forwarding-rules delete $LINE
      done < <(gcloud compute forwarding-rules list \
        | awk "/${TARGET_POOL}/{print \$1\" --region=\"\$2}")

      (yes || true) | gcloud compute target-pools delete ${TARGET_POOL_FULL}
    fi
  done < <(gcloud compute target-pools list \
    | tail -n +2 \
    | awk '{print $1" --region="$2}' \
    | sort -u)

  # delete unused global IPs
  gcloud compute addresses list \
    --filter="status!=IN_USE" \
    --format=json \
    | jq -r '.[].name' \
    | xargs --no-run-if-empty -n1 \
      gcloud compute addresses delete --global
}

# helper functions
success() {
  [ "${@:-}" ] && RESPONSE="$@" || RESPONSE="Unknown Success"
  printf "$(log_message_prefix)${COLOUR_GREEN}${RESPONSE}${COLOUR_RESET}\n\n"
} 1>&2

info() {
  [ "${@:-}" ] && INFO="$@" || INFO="Unknown Info"
  printf "$(log_message_prefix)${COLOUR_WHITE}${INFO}${COLOUR_RESET}\n\n"
} 1>&2

warning() {
  [ "${@:-}" ] && ERROR="$@" || ERROR="Unknown Warning"
  printf "$(log_message_prefix)${COLOUR_RED}${ERROR}${COLOUR_RESET}\n\n"
} 1>&2

error() {
  [ "${@:-}" ] && ERROR="$@" || ERROR="Unknown Error"
  printf "$(log_message_prefix)${COLOUR_RED}${ERROR}${COLOUR_RESET}\n\n"
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
