#!/usr/bin/env bash

load '../bin/bats-support/load'
load '../bin/bats-assert/load'

APP="timeout --foreground --kill-after=15s 300s ./../../../theseus"
DRY_RUN_DEFAULTS="test/theseus/asset/beefjerky-deployment-v1.yaml --dry-run"

declare -r DIR=$(cd "$(dirname "$0")" && pwd)
cd "${DIR}" >&2
[[ -n "${LOCAL_ISTIO:-}" ]] && ../local-istio.sh >&2
cd "${DIR}/.." >&2
[[ -n "${DEBUG:-}" ]] && DEBUG='--debug' || DEBUG=''
trap 'kubectl get event | tail -n 30' EXIT

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
