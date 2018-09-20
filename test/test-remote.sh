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

CLUSTER_NAME="${CLUSTER_NAME:-test-theseus}"
DEFAULT_PROJECT="${DEFAULT_PROJECT:-controlplane-dev-2}"
DEFAULT_ZONE="${DEFAULT_ZONE:-europe-west2-a}"
PREEMPTIBLE="${PREEMPTIBLE:- --preemptible}"
NUM_NODES="5"
MACHINE_TYPE="n1-highcpu-16"

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
  local CLUSTER_VERSION=$(gcloud container get-server-config | grep 'validMasterVersions:' -A 1 | awk '/^- /{print $2}')
  if ! OUTPUT=$( (yes || true) \
    | gcloud container clusters create "${CLUSTER_NAME}" \
    \
    --machine-type ${MACHINE_TYPE} \
    --num-nodes ${NUM_NODES} \
    --cluster-version=${CLUSTER_VERSION} \
    \
    ${PREEMPTIBLE} \
    \
    --maintenance-window=04:42
    --enable-network-policy \
    --no-enable-legacy-authorization \
    \
    --enable-autoscaling \
    --max-nodes=$((NUM_NODES * 2)) \
    \
    --enable-master-authorized-networks \
    --master-authorized-networks=0.0.0.0/0 \
    \
    2>&1); then

    if echo "${OUTPUT}" | grep -E 'Version [0-9\.\"]+ is invalid.' &>/dev/null; then
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

  kubectl get clusterrolebinding cluster-admin-binding || kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole cluster-admin --user "$(gcloud config get-value account)"

  gcloud beta container clusters update "${CLUSTER_NAME}" --monitoring-service monitoring.googleapis.com
  kubectl create -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter.yaml || true

  # add kubernetes admin to gcloud default service account
  local PROJECT_NAME PROJECT_ID GKE_DEFAULT_SERVICE_ACCOUNT
  PROJECT_NAME=$(gcloud config get-value project)
  PROJECT_ID=$(gcloud projects list | awk "/${PROJECT_NAME}/{print \$3}")
  GKE_DEFAULT_SERVICE_ACCOUNT="${PROJECT_ID}-compute@developer.gserviceaccount.com"

  gcloud projects \
    add-iam-policy-binding \
    ${PROJECT_NAME} \
      --member serviceAccount:${GKE_DEFAULT_SERVICE_ACCOUNT} \
      --role roles/container.clusterAdmin

  gcloud projects \
    add-iam-policy-binding \
    ${PROJECT_NAME} \
      --member serviceAccount:${GKE_DEFAULT_SERVICE_ACCOUNT} \
      --role roles/container.admin
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

  success "Tests passed"
}

cleanup() {

  if [[ -n "${CI_JOB_ID:-}" ]]; then
    local DEBUG_LOG_NAME="${DIR}/../debug-${CI_JOB_ID}.log"
    printf "" | tee "${DEBUG_LOG_NAME}"
    cat "${DIR}"/../debug.log | sed '/^    /d' >>"${DEBUG_LOG_NAME}" || true
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
      | awk "/^gke-${CLUSTER_NAME}/{print \$1}" \
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
