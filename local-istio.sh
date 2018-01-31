#!/bin/bash

set -eux -o pipefail

# resolved directory and self
declare -r DIR=$(cd "$(dirname "$0")" && pwd)
declare -r THIS_SCRIPT="${DIR}/$(basename "$0")"

cd "${DIR}"

ISTIO_DIR=$(find . -maxdepth 1 -type d -regex './istio-[0-9\.]+' | sort --version-sort | tail -n 1)
ISTIOCTL="${DIR}/${ISTIO_DIR}/bin/istioctl"

# this is for cleanup.sh
if ! which istioctl &>/dev/null; then
  export PATH="${PATH}:$(pwd)/${ISTIO_DIR}/bin"
fi

main() {
  LB_COUNT_TIMEOUT=15
  INGRESS_COUNT_TIMEOUT=30

  if kubectl config current-context | grep -E '^gke_'; then
    IS_MINIKUBE=0

    echo "Deploying to $(kubectl config current-context)"
    check_is_test_cluster

    check_is_gcloud_quota_ok

  else

    IS_MINIKUBE=1
    INGRESS_COUNT_TIMEOUT=50

    echo "Cleaning minikube and redeploying"
    [[ $(minikube status --format '{{.MinikubeStatus}}') == 'Running' ]] || minikube start

    sleep 5

    MINIKUBE_IMAGES=$(minikube ssh docker images | tail -n +2)
    if [[ $(echo "${MINIKUBE_IMAGES}" | grep istio --count) -lt 5 ]]; then
      for IMAGE in $(docker images | awk '/istio/{print $1}'); do
        if ! echo "${MINIKUBE_IMAGES}" | grep -q "${IMAGE}"; then
          minikube-import "${IMAGE}"
        fi
      done
    fi
  fi

  cleanup_istio

  # TODO(ajm): programmatically infer user
  echo 'Creating temporary clusterrolebinding - remove when supported by istio'
  kubectl create clusterrolebinding my-admin-access --clusterrole cluster-admin --user sublimino@gmail.com || true
  kubectl create clusterrolebinding my-admin-access-1 --clusterrole cluster-admin --user minikube || true
  kubectl create clusterrolebinding my-admin-access-2 --clusterrole cluster-admin --user k8s-deploy-bot@binarysludge-20170716-2.iam.gserviceaccount.com || true

  echo "deploying istio from ${ISTIO_DIR}"
  # cat "${ISTIO_DIR}"/install/kubernetes/istio.yaml | update_pull_policy | kubectl create -f -
  kubectl apply -f "${ISTIO_DIR}"/install/kubernetes/istio-auth.yaml

  # TODO(ajm): probably not needed since 0.2.4?
  # echo "generating TLS secrets"
  # (yes '' || true) | openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /tmp/tls.key -out /tmp/tls.crt
  # kubectl -n istio-system delete secret ingress-certs || true
  # kubectl -n istio-system create secret tls ingress-certs --key /tmp/tls.key --cert /tmp/tls.crt

  sleep 30

  kubectl get service -n istio-system

  istio_apply "${ISTIO_DIR}"/samples/bookinfo/kube/bookinfo.yaml

  sleep 3

  export GATEWAY_URL

  if [[ "${IS_MINIKUBE}" == 1 ]]; then
    GATEWAY_URL=$(kubectl get po \
      --namespace istio-system \
      -l istio=ingress \
      -o 'jsonpath={.items[0].status.hostIP}'):$(kubectl get svc \
        --namespace istio-system \
        istio-ingress \
        -o 'jsonpath={.spec.ports[0].nodePort}')
  else
    GATEWAY_URL=$(kubectl get ingress gateway \
      -o 'jsonpath={.status.loadBalancer.ingress[].ip}')
    wait_for_ingress_ip
  fi

  [[ -n ${GATEWAY_URL} ]]

  wait_for_productpage

  sleep 10

  if command xdg-open &>/dev/null; then
    xdg-open "http://${GATEWAY_URL}/productpage"
  fi

  sleep 5

  echo "Deleting reviews service and deployments"
  kubectl delete -f test/theseus/asset || true

  sleep 3

  echo "Deploying service and v1"
  ROUTE_RULES="${ISTIO_DIR}"/samples/bookinfo/kube/route-rule-all-v1.yaml
  for RULE in $(awk '/name:/{ print $2 }' "${ROUTE_RULES}"); do
    if [[ $(${ISTIOCTL} get routerule "${RULE}") != 'No resources found.' ]]; then
      ${ISTIOCTL} delete routerule "${RULE}"
    fi
  done

  ${ISTIOCTL} create -f "${ROUTE_RULES}"

  istio_apply test/theseus/asset/reviews-service.yaml
  istio_apply test/theseus/asset/reviews-deployment-v1.yaml

  if false; then
    kubectl apply --namespace kube-system -f \
      "https://cloud.weave.works/k8s/scope.yaml?k8s-version=$(kubectl version | base64 | tr -d '\n')" || true
    kubectl port-forward -n kube-system "$(kubectl get -n kube-system pod \
      --selector=weave-scope-component=app -o jsonpath='{.items..metadata.name}')" 4040 &
    disown $! || true
  fi
}

istio_apply() {
  local RESOURCE="${1}"
  kubectl apply -f <(${ISTIOCTL} kube-inject -f "${RESOURCE}" \
    | update_pull_policy)
}

update_pull_policy() {
  # sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g ; s/"imagePullPolicy":"Always"/"imagePullPolicy":"IfNotPresent"/g'
  cat
}

wait_for_productpage() {
  COUNT=0
  until [[ $(curl \
    --max-time 5 \
    -o /dev/null \
    -w "%{http_code}\n" \
    -s \
    "http://${GATEWAY_URL}/productpage"
  ) == 200 ]]; do
    let COUNT=$((COUNT + 1))
    [[ "${COUNT}" -gt "${INGRESS_COUNT_TIMEOUT}" ]] && {
      echo "Timeout"
      kubectl get event
      exit 1
    }
    sleep $((5 * (COUNT + 10) / 10))
  done

}

minikube-import() {
  local IMAGE=${1:-busybox:latest}
  local IMAGE_ESCAPED=$(echo "${IMAGE}" | sed 's#/#\\/#g')
  local MINIKUBE_ENV=$(minikube docker-env)
  echo "Importing ${IMAGE} to minikube"
  (
    unset DOCKER_TLS_VERIFY DOCKER_HOST DOCKER_CERT_PATH DOCKER_API_VERSION
    docker save "${IMAGE}"
  ) | pv --width=98 --size $(
    docker images --format "{{.Repository}}:{{.Tag}} {{.Size}}" | awk "/${IMAGE_ESCAPED}/{print \$2}" | head -n1 | sed -E 's/[^0-9]*//g ; s/(.*)/\1m/'
  ) | (
    source /dev/stdin < <(echo "${MINIKUBE_ENV}")
    docker load
  )
}

wait_for_ingress_ip() {
  COUNT=0
  until [[ -n ${GATEWAY_URL} ]]; do
    let COUNT=$((COUNT + 1))
    [[ "${COUNT}" -gt "${LB_COUNT_TIMEOUT}" ]] && {
      echo "Timeout getting ingress IP. This could be a quota issue."
      echo "Dumping events then enumerating quotas"
      kubectl get event
      gcloud-quota-check
      printf '\n\n'
      exit 1
    }
    sleep $((5 * (COUNT + 10) / 10))
    GATEWAY_URL=$(kubectl get ingress gateway -o 'jsonpath={.status.loadBalancer.ingress[].ip}')
  done
}

check_is_gcloud_quota_ok() {
  local QUOTA_OUTPUT=$(gcloud-quota-check)

  if echo "${QUOTA_OUTPUT}" | grep -q 'metric'; then
    echo "Quota exceed tolerances. Failing"
    echo "${QUOTA_OUTPUT}"
    printf '\n\n\n'
    exit 1
  fi
}

gcloud-quota-check() {
  for REGION in $(gcloud compute regions list --format="value(name)" | grep "europe-west2"); do
    echo ${REGION}
    gcloud compute regions describe "${REGION}" --format json \
      | jq '.quotas[] | select(.limit > 0) | select(.usage >= (.limit * 0.8)) | .'
  done
}

check_is_test_cluster() {
  if ! kubectl config current-context | grep -E '^gke_binarysludge-20[0-9\-]{6,}_europe-west.-._test'; then
    if ! kubectl config current-context | grep -E '^gke_weave-demo-20[0-9\-]{6,}_europe-west.-._test'; then
      echo "ERROR! Not a test cluster!"
      exit 1
    fi
  fi
}

cleanup_istio() {
  PIDS=()
  kubectl delete -f "${ISTIO_DIR}"/install/kubernetes/istio-auth.yaml || true &
  PIDS+=($!)
  kubectl delete -f "${ISTIO_DIR}"/install/kubernetes/istio.yaml || true &
  PIDS+=($!)
  "${ISTIO_DIR}"/samples/bookinfo/kube/cleanup.sh &
  PIDS+=($!)
  kubectl get crd -o 'jsonpath={.items[*].metadata.name}' | grep config\.istio\.io | xargs kubectl delete crd || true &
  PIDS+=($!)

  wait-safe "${PIDS[@]}"

  wait_for_no_pods istio

  sleep 10
}

wait_for_no_pods() {
  local POD="${1}"
  local TIMEOUT=30
  local COUNT=1
  while [[ $(kubectl get pods --all-namespaces -o name | grep -E "^pods/${POD}" --count) != 0 ]]; do
    let COUNT=$((COUNT + 1))
    [[ "$COUNT" -gt "${TIMEOUT}" ]] && {
      echo "Timeout"
      exit 1
    }
    sleep 1
  done
  echo "Wait complete in ${COUNT} seconds" >&2
  sleep 1
}

wait-safe() {
  local PIDS="${1}"
  for JOB in ${PIDS}; do
    wait "${JOB}"
  done
}

main
