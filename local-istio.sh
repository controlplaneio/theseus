#!/bin/bash

set -eux -o pipefail

# resolved directory and self
declare -r DIR=$(cd "$(dirname "$0")" && pwd)
declare -r THIS_SCRIPT="${DIR}/$(basename "$0")"

cd "${DIR}"

ISTIO_DIR=$(find . -maxdepth 1 -type d -regex './istio-[release-]*.*' \
  | sort --version-sort \
  | tail -n 1)
ISTIOCTL="${DIR}/${ISTIO_DIR}/bin/istioctl"

# this is for cleanup.sh
export PATH="${PATH}:$(pwd)/${ISTIO_DIR}/bin"
DEFAULT_ZONE="${DEFAULT_ZONE:-europe-west2-a}"

main() {
  LB_COUNT_TIMEOUT=75
  INGRESS_COUNT_TIMEOUT=75

  preflight_checks

  cleanup_istio
  cleanup_rolebindings

  deploy_istio_system
  deploy_bookinfo
  deploy_addons

  poll_until_available

  browser_open_productpage
}

preflight_checks() {
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

    minikube_docker_load
  fi
}

minikube_docker_load() {
  MINIKUBE_IMAGES=$(minikube ssh docker images | tail -n +2)
  if [[ $(echo "${MINIKUBE_IMAGES}" | grep istio --count) -lt 5 ]]; then
    for IMAGE in $(docker images | awk '/istio/{print $1}'); do
      if ! echo "${MINIKUBE_IMAGES}" | grep -q "${IMAGE}"; then
        minikube-import "${IMAGE}"
      fi
    done
  fi
}

cleanup_istio() {
  local PIDS=()
  kubectl delete -f "${ISTIO_DIR}"/install/kubernetes/istio-demo-auth.yaml || true &
  PIDS+=($!)
  kubectl delete -f "${ISTIO_DIR}"/install/kubernetes/istio-demo.yaml || true &
  PIDS+=($!)
  "${ISTIO_DIR}"/samples/bookinfo/kube/cleanup.sh &
  PIDS+=($!)
  kubectl get crd -o 'jsonpath={.items[*].metadata.name}' | grep config\.istio\.io | xargs --no-run-if-empty kubectl delete crd || true &
  PIDS+=($!)

  kubectl delete namespace istio-system || true &
  PIDS+=($!)


  helm template "${ISTIO_DIR}"/install/kubernetes/helm/istio --name istio --namespace istio-system \
  | kubectl delete -f - || true &
  PIDS+=($!)
  kubectl -n istio-system delete job --all || true &
  PIDS+=($!)
  kubectl delete -f "${ISTIO_DIR}"/install/kubernetes/helm/istio/templates/crds.yaml -n istio-system || true &
  PIDS+=($!)


  wait-safe "${PIDS[@]}"

  sleep 10

  wait_for_no_pods istio
  wait_for_no_namespaces istio-system
}

check_for_zone() {
  gcloud config get-value compute/zone
  if [[ $(gcloud config get-value compute/zone) == '' ]]; then
    export CLOUDSDK_COMPUTE_ZONE="${DEFAULT_ZONE}"
  fi
  true
}

cleanup_rolebindings() {
  local PIDS=()

  # TODO(ajm): programmatically infer user
  echo 'Creating temporary clusterrolebinding - remove when supported by istio'
  kubectl delete clusterrolebinding "cluster-admin-$(whoami)" || true
  PIDS+=($!)

  check_for_zone

  kubectl create clusterrolebinding "cluster-admin-$(whoami)" \
    --clusterrole=cluster-admin \
    --user="$(gcloud config get-value core/account)"
  PIDS+=($!)

  kubectl delete clusterrolebinding admin-access || true &
  PIDS+=($!)
  kubectl delete clusterrolebinding admin-access-1 || true &
  PIDS+=($!)
  kubectl delete clusterrolebinding admin-access-2 || true &
  PIDS+=($!)
  kubectl delete clusterrolebinding admin-access-3 || true &
  PIDS+=($!)

  kubectl create clusterrolebinding admin-access --clusterrole cluster-admin --user sublimino@gmail.com || true &
  PIDS+=($!)
  kubectl create clusterrolebinding admin-access-1 --clusterrole cluster-admin --user minikube || true &
  PIDS+=($!)
  kubectl create clusterrolebinding admin-access-2 --clusterrole cluster-admin --user k8s-deploy-bot@binarysludge-20170716-2.iam.gserviceaccount.com || true &
  PIDS+=($!)
  kubectl create clusterrolebinding admin-access-3 --clusterrole cluster-admin --user system:serviceaccount:istio-system:default || true &
  PIDS+=($!)

  PIDS+=($!)

  wait-safe "${PIDS[@]}"


}

deploy_istio_system() {
  echo "deploying istio-system from ${ISTIO_DIR}"

  until kubectl create namespace istio-system; do
    printf .
    sleep 1
  done

  kubectl label namespace default \
    istio-injection=enabled \
    --overwrite

  kubectl apply -f "${ISTIO_DIR}"/install/kubernetes/helm/istio/templates/crds.yaml
  kubectl apply -f "${ISTIO_DIR}"/install/kubernetes/helm/istio/charts/certmanager/templates/crds.yaml


  local HELM=0

  if [[ "${HELM:-}" == 1 ]]; then

    helm template "${ISTIO_DIR}"/install/kubernetes/helm/istio \
      --name istio \
      --namespace istio-system \
      \
        --set security.enabled=true \
        --set ingress.enabled=true \
        --set gateways.istio-ingressgateway.enabled=true \
        --set gateways.istio-egressgateway.enabled=true \
        --set galley.enabled=true \
        --set sidecarInjectorWebhook.enabled=true \
        --set mixer.enabled=true \
        --set prometheus.enabled=true \
        --set global.proxy.envoyStatsd.enabled=true \
        --set pilot.sidecar=true \
      \
      | update_pull_policy \
      | kubectl apply -f -

  else
    kubectl apply -f "${ISTIO_DIR}"/install/kubernetes/istio-demo-auth.yaml
  fi

  sleep 5

  kubectl get service -n istio-system
}

deploy_bookinfo() {
  echo "deploying bookinfo resources"
#  istio_apply "${DIR}"/test/theseus/asset/bookinfo.yaml

  istio_apply "${ISTIO_DIR}"/samples/bookinfo/platform/kube/bookinfo.yaml
  istio_apply "${ISTIO_DIR}"/samples/bookinfo/networking/bookinfo-gateway.yaml

  # TODO: confirm these are correct

  echo "deploying bookinfo destination rules"
  kubectl delete -f "${ISTIO_DIR}"/samples/bookinfo/networking/destination-rule-all-mtls.yaml || true
  sleep 2
  kubectl create -f "${ISTIO_DIR}"/samples/bookinfo/networking/destination-rule-all-mtls.yaml

  kubectl create -f "${ISTIO_DIR}"/samples/bookinfo/networking/virtual-service-all-v1.yaml

  sleep 3
}

deploy_addons() {
  return 0

  if [[ "${IS_MINIKUBE}" == 0 ]]; then

    echo "Applying addons"

    kubectl apply -f "${ISTIO_DIR}"/install/kubernetes/addons/prometheus.yaml
    kubectl apply -f "${ISTIO_DIR}"/install/kubernetes/addons/grafana.yaml

    if false; then
      kubectl apply --namespace kube-system -f \
        "https://cloud.weave.works/k8s/scope.yaml?k8s-version=$(kubectl version | base64 | tr -d '\n')" || true
      kubectl port-forward -n kube-system "$(kubectl get -n kube-system pod \
        --selector=weave-scope-component=app -o jsonpath='{.items..metadata.name}')" 4040 &
      disown $! || true
    fi
  fi
}

get_gateway_url() {
  export GATEWAY_URL

  if [[ "${IS_MINIKUBE}" == 1 ]]; then
    GATEWAY_URL=$(kubectl get pod \
      --namespace istio-system \
      -l istio=ingress \
      -o 'jsonpath={.items[0].status.hostIP}'):$(kubectl get svc \
        --namespace istio-system \
        istio-ingress \
        -o 'jsonpath={.spec.ports[0].nodePort}')
  else
    GATEWAY_URL=$(kubectl \
      -n istio-system \
      get service istio-ingressgateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    wait_for_ingress_ip
  fi

  [[ -n ${GATEWAY_URL} ]]
}

poll_until_available() {
  get_gateway_url

  wait_for_productpage

  sleep 2
}

browser_open_productpage() {
  if command -v xdg-open &>/dev/null; then
    xdg-open "http://${GATEWAY_URL}/productpage"
  fi
}

istio_apply() {
  local RESOURCE="${1}"
  kubectl apply -f <(${ISTIOCTL} kube-inject -f "${RESOURCE}" \
    | update_pull_policy)
}

update_pull_policy() {
  sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g ; s/"imagePullPolicy":"Always"/"imagePullPolicy":"IfNotPresent"/g'
}

wait_for_productpage() {
  local COUNT=0
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
    get_gateway_url
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
    if ! kubectl config current-context | grep -E '^gke_weave-demo-.*_europe-west.-._test'; then
      if ! kubectl config current-context | grep -E '^gke_controlplane-dev-.*_europe-west.-._test'; then
        echo "ERROR! Not a test cluster!"
        exit 1
      fi
    fi
  fi
}


wait_for_no_pods() {
  wait_for_no_resource pods "${1}"
}

wait_for_no_namespaces() {
  wait_for_no_resource namespace "${1}" 120
}

wait_for_no_resource() {
  local RESOURCE_TYPE="${1%s}s"
  local RESOURCE_INSTANCE_NAME="${2}"
  local TIMEOUT="${3:-60}"
  local COUNT=1
  local ALL_NAMESPACES_FLAG="--all-namespaces"
  if [[ "${RESOURCE_TYPE}" =~ ^namespaces?$ ]]; then
    ALL_NAMESPACES_FLAG=""
  fi
  while [[ $(kubectl get "${RESOURCE_TYPE}" ${ALL_NAMESPACES_FLAG} -o name \
    | grep -E "^${RESOURCE_TYPE}/${RESOURCE_INSTANCE_NAME}" --count) != 0 ]]; do

    let COUNT=$((COUNT + 1))
    [[ "$COUNT" -gt "${TIMEOUT}" ]] && {
      echo "Timeout waiting for no '${RESOURCE_TYPE}' matching '${RESOURCE_INSTANCE_NAME}'" >&2
      exit 1
    }
    sleep 1
  done
  echo "Wait for '${RESOURCE_TYPE}' matching '${RESOURCE_INSTANCE_NAME}' complete in ${COUNT} seconds" >&2
  sleep 3
}

wait-safe() {
  local PIDS="${1}"
  for JOB in ${PIDS}; do
    wait "${JOB}"
  done
}

main
