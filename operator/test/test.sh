#!/usr/bin/env bash

#quit if exit status of any cmd is a non-zero value
set -o errexit
set -o nounset
set -o pipefail

usage() {
  echo "
Usage:
    $0 [options]

Run Pipeline Service tests on the cluster referenced by KUBECONFIG.

Optional arguments:
    -k, --kubeconfig KUBECONFIG
        kubeconfig to the cluster to test.
        The current context will be used.
        Default value: \$KUBECONFIG
    -t, --test TEST
        Name of the test to be executed. Can be repeated to run multiple tests.
        Must be one of: chains, pipelines, results.
        Default: Run all tests.
    -d, --debug
        Activate tracing/debug mode.
    -h, --help
        Display this message.

Example:
    $0 --kubeconfig mykubeconfig.yaml --test chains --test pipelines
"
}

parse_args() {
  KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
  TEST_LIST=()
  while [[ $# -gt 0 ]]; do
    case $1 in
    -k | --kubeconfig)
      shift
      KUBECONFIG="$1"
      ;;
    -t | --test)
      shift
      TEST_LIST+=("$1")
      ;;
    -d | --debug)
      DEBUG="--debug"
      set -x
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
    esac
    shift
  done
  DEBUG="${DEBUG:-}"
  if [ "${#TEST_LIST[@]}" = "0" ]; then
    TEST_LIST=( "chains" "pipelines" "results" )
  fi
}

init() {
  SCRIPT_DIR=$(
    cd "$(dirname "$0")" >/dev/null
    pwd
  )
  export KUBECONFIG
  NAMESPACE="plnsvc-tests"
  RESULTS_SA="tekton-results-tests"
}

setup_test() {
  echo "[Setup]"
  if ! kubectl get namespace $NAMESPACE > /dev/null 2>&1; then
    echo -n "  - Create namespace '$NAMESPACE': "
    kubectl create namespace "$NAMESPACE" >/dev/null
  fi
  # Wait for pipelines to set up all the components
  while [ "$(kubectl get serviceaccounts -n "$NAMESPACE" | grep -cE "^pipeline ")" != "1" ]; do
    echo -n "."
    sleep 2
  done
  echo "OK"
}

wait_for_pipeline() {
  kubectl wait --for=condition=succeeded "$1" -n "$2" --timeout 60s >/dev/null
}

test_chains() {
  kubectl apply -k "$SCRIPT_DIR/manifests/test/tekton-chains" -n "$NAMESPACE" >/dev/null

  # Trigger the pipeline
  echo -n "  - Run pipeline: "
  image_src="quay.io/aptible/alpine:latest"
  image_name="$(basename "$image_src")"
  image_dst="image-registry.openshift-image-registry.svc:5000/$NAMESPACE/$image_name"
  pipeline_name="$(
    tkn -n "$NAMESPACE" pipeline start simple-copy \
      --param image-src="$image_src" \
      --param image-dst="$image_dst" \
      --workspace name=shared,pvc,claimName="tekton-build" |
      head -1 | sed "s:.* ::"
  )"
  wait_for_pipeline "pipelineruns/$pipeline_name" "$NAMESPACE"
  echo "OK"

  echo -n "  - Pipeline signed: "
  signed="$(kubectl get pipelineruns -n "$NAMESPACE" "$pipeline_name" -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}')"
  retry_timer=0
  polling_interval=2
  until [ -n "$signed" ] || [ "$retry_timer" -ge 30 ]; do
    echo -n "."
    sleep $polling_interval
    retry_timer=$((retry_timer + polling_interval))
    signed="$(kubectl get pipelineruns -n "$NAMESPACE" "$pipeline_name" -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}')"
  done
  if [ "$signed" = "true" ]; then
    echo "OK"
  else
    echo "Failed"
    echo "[ERROR] Unsigned pipeline ($pipeline_name)" >&2
    exit 1
  fi

  echo -n "  - Image signed: "
  signed="$(kubectl get -n "$NAMESPACE" imagestreamtags | grep -cE ":sha256-[0-9a-f]*\.att|:sha256-[0-9a-f]*\.sig" || true)"
  # No need to reset $retry_timer
  until [ "$signed" = "2" ] || [ "$retry_timer" -ge 30 ]; do
    echo -n "."
    sleep $polling_interval
    retry_timer=$((retry_timer + polling_interval))
    signed="$(kubectl get -n "$NAMESPACE" imagestreamtags | grep -cE ":sha256-[0-9a-f]*\.att|:sha256-[0-9a-f]*\.sig" || true)"
  done
  if [ "$signed" = "2" ]; then
    echo "OK"
  else
    echo "Failed"
    echo "[ERROR] Unsigned image" >&2
    exit 1
  fi

  echo -n "  - Public key: "
  pipeline_name=$(kubectl create -f "$SCRIPT_DIR/manifests/test/tekton-chains/public-key.yaml" -n "$NAMESPACE" | cut -d' ' -f1)
  wait_for_pipeline "$pipeline_name" "$NAMESPACE"
  if [ "$(kubectl get "$pipeline_name" -n "$NAMESPACE" \
    -o 'jsonpath={.status.conditions[0].reason}')" = "Succeeded" ]; then
    echo "OK"
  else
    echo "Failed"
    echo "[ERROR] Public key is not accessible" >&2
    exit 1
  fi
  echo
}

test_pipelines() {
  echo -n "  - Run pipeline: "
  if ! kubectl get -n "$NAMESPACE" serviceaccount default >/dev/null 2>&1; then
    kubectl create -n "$NAMESPACE" serviceaccount default
  fi
  BASE_URL="https://raw.githubusercontent.com/tektoncd/pipeline/v0.32.0"
  manifest="pipelineruns/using_context_variables.yaml"
  # change ubuntu image to ubi to avoid dockerhub registry pull limit
  pipeline_name=$(
    curl --fail --silent "$BASE_URL/examples/v1beta1/$manifest" |
      sed 's|ubuntu|registry.access.redhat.com/ubi9/ubi-minimal:latest|' |
      sed '/serviceAccountName/d' |
      kubectl create -n "$NAMESPACE" -f - | cut -d" " -f1
  )
  wait_for_pipeline "$pipeline_name" "$NAMESPACE"
  echo "OK"
}

test_results() {
  test_pipelines
  echo -n "  - Results in database: "

  # Service Account to test tekton-results
  if ! kubectl get serviceaccount "$RESULTS_SA" -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl create serviceaccount "$RESULTS_SA" -n "$NAMESPACE"
    echo -n "."
  fi
  # Grant required privileges to the Service Account
  if ! kubectl get rolebinding tekton-results-tests -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl create rolebinding tekton-results-tests -n "$NAMESPACE" --clusterrole=tekton-results-readonly --serviceaccount="$NAMESPACE":"$RESULTS_SA"
    echo -n "."
  fi

  # download the API Server certificate locally and configure gRPC.
  kubectl get secrets tekton-results-tls -n tekton-results --template='{{index .data "tls.crt"}}' | base64 -d >/tmp/results.crt
  export GRPC_DEFAULT_SSL_ROOTS_FILE_PATH=/tmp/results.crt

  RESULT_UID=$(kubectl get "$pipeline_name" -n "$NAMESPACE" -o yaml | yq .metadata.uid)

  # This is required to pass shellcheck due to the single quotes in the GetResult name parameter.
  QUERY="name: \"$NAMESPACE/results/$RESULT_UID\""

  # Proxies the remote Service to localhost.
  timeout 10 kubectl port-forward -n tekton-results service/tekton-results-api-service 50051 >/dev/null &

  RECORD_CMD=(
    "grpc_cli"
    "call"
    "--channel_creds_type=ssl"
    "--ssl_target=tekton-results-api-service.tekton-results.svc.cluster.local"
    "--call_creds=access_token=$(kubectl get secrets -n "$NAMESPACE" -o jsonpath="{.items[?(@.metadata.annotations['kubernetes\.io/service-account\.name']==\"$RESULTS_SA\")].data.token}" | cut -d ' ' -f 2 | base64 --decode)"
    "localhost:50051"
    "tekton.results.v1alpha2.Results.GetResult"
    "$QUERY")
  RECORD_RESULT=$("${RECORD_CMD[@]}")

  if [[ $RECORD_RESULT == *$RESULT_UID* ]]; then
    echo "OK"
  else
    echo "Failed"
    echo "[ERROR] Unable to retrieve record $RESULT_UID from pipeline run $pipeline_name" >&2
    exit 1
  fi
  echo
}

main() {
  parse_args "$@"
  init
  setup_test
  for case in "${TEST_LIST[@]}"; do
    case $case in
    chains | pipelines | results)
      echo "[$case]"
      test_"$case"
      echo
      ;;
    *)
      echo "Incorrect case name '[$case]'"
      usage
      exit 1
      ;;
    esac
  done
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
  main "$@"
fi
