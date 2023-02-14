#!/usr/bin/env bash

# Copyright 2022 The Pipeline Service Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

SCRIPT_DIR="$(
  cd "$(dirname "$0")" >/dev/null || exit 1
  pwd
)"

PROJECT_DIR="$(
  cd "$SCRIPT_DIR/../.." >/dev/null || exit 1
  pwd
)"
DEV_DIR="$PROJECT_DIR/developer/openshift"
GITOPS_DIR="$PROJECT_DIR/operator/gitops/argocd/pipeline-service"
COMPUTE_DIR="$PROJECT_DIR/operator/gitops/compute/pipeline-service-manager"

RESET_HARD="false"

usage() {
  printf "
Usage:
    %s [options]

Scrap local Pipeline-Service environment and free resources deployed by dev_setup.sh script.

Mandatory arguments:
    --work-dir WORK_DIR
        Location of the cluster files related to the environment.
        Kubeconfig files for compute clusters are expected in the subdirectory: credentials/kubeconfig/compute

Optional arguments:
    --reset-hard
        Aggressively remove operators deployed.
    -d, --debug
        Activate tracing/debug mode.
    -h, --help
        Display this message.

Example:
    %s --work-dir './tmp/tmp.435kjkdsf'
" "${0##*/}" "${0##*/}" >&2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --work-dir)
      shift
      WORK_DIR="$1"
      ;;
    --reset-hard)
      shift
      RESET_HARD="true"
      ;;
    -d | --debug)
      set -x
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      # End of arguments
      break
      ;;
    *)
      exit_error "Unknown argument: $1"
      ;;
    esac
    shift
  done
}

exit_error() {
    printf "[ERROR] %s" "$@" >&2
    usage
    exit 1
}


prechecks() {
    WORK_DIR=${WORK_DIR:-}
    if [[ -z "${WORK_DIR}" ]]; then
      printf "\n[ERROR] Missing parameter --work-dir" >&2
      exit 1
    fi
    KUBECONFIG="$WORK_DIR/credentials/kubeconfig/compute/compute.kubeconfig.base"
    if [ ! -f "$KUBECONFIG" ]; then
      printf "\n[ERROR] Couldn't find compute's kubeconfig." >&2
      printf "\nExpected compute's KUBECONFIG dir:'WORK_DIR/credentials/kubeconfig/compute/'"
      exit 1
    fi
    export KUBECONFIG="$KUBECONFIG"
}

uninstall_minio() {
    printf "\n  Uninstalling Minio:\n"
    # if argocd app get minio >/dev/null 2>&1; then
      # Remove any finalizers that might inhibit deletion
      if argocd app get minio >/dev/null 2>&1; then
          kubectl patch applications.argoproj.io -n openshift-gitops minio --type json --patch='[ { "op": "remove", "path": "/metadata/finalizers" } ]' >/dev/null 2>&1
      fi
      argocd app delete minio --yes

      # # Check if the Argo CD application have been indeed removed
      # if argocd app get minio >/dev/null 2>&1; then
      #     printf "\n[ERROR] Couldn't uninstall Minio Argo CD application." >&2
      #     exit 1
      # fi

      # kubectl delete tenant storage -n tekton-results
      # oc delete subscription minio-operator -n openshift-operators
      kubectl delete -k "$DEV_DIR/gitops/argocd/minio/tenant" 
      # --ignore-not-found=true
      kubectl delete -k "$DEV_DIR/gitops/argocd/minio/operator" 
      # --ignore-not-found=true

      printf "\n  Uninstalling Minio Operator:\n"
      minio_gitops_csv=$(kubectl get csv -n openshift-operators | grep -ie "minio-operator" | cut -d " " -f 1)
      if [[ -n "$minio_gitops_csv" ]]; then
        kubectl delete csv -n openshift-operators "$minio_gitops_csv"
      fi

      mapfile -t minio_crds < <(kubectl get crd -n openshift-operators | grep -iE "tenant" | cut -d " " -f 1)
      if [[ "${#minio_crds[@]}" -gt 0 ]]; then
        for crd in "${minio_crds[@]}"; do
          printf "\n    Delete crd %s\n" "$crd"
          kubectl delete crd "$crd"
        done
      fi

kubectl get crd tenant
sleep 60
      minio_operator=$(kubectl get operator | grep -ie "minio" | cut -d " " -f 1)
      if [[ -n "$minio_operator" ]]; then
        printf "\n    Delete operator cr %s\n" "$minio_operator"
        kubectl delete operator "$minio_operator"
      fi
      exit 1
    # fi
}

uninstall_pipeline_service() {
    printf "\n  Uninstalling Pipeline Service:\n"
    # Remove pipeline-service Argo CD application
    # if ! argocd app get pipeline-service >/dev/null 2>&1; then
    #   printf "\n[ERROR] Couldn't find the 'pipeline-service' application in argocd apps.\n" >&2
    #   exit 1
    # fi

    argocd app delete pipeline-service --yes
    # Remove any finalizers that might inhibit deletion
    if argocd app get pipeline-service >/dev/null 2>&1; then
        kubectl patch applications.argoproj.io -n openshift-gitops pipeline-service --type json --patch='[ { "op": "remove", "path": "/metadata/finalizers" } ]' >/dev/null 2>&1
    fi

    # Check if the Argo CD application have been indeed removed
    if argocd app get pipeline-service >/dev/null 2>&1; then
        printf "\n[ERROR] Couldn't uninstall Pipeline-Service Argo CD application." >&2
        exit 1
    fi

    # Remove pipeline-service-manager resources
    kubectl delete -k "$COMPUTE_DIR" --ignore-not-found=true

    printf "\nPipeline-Service Argo CD application has been successfully removed.\n"
}

uninstall_operators_and_controllers(){
    printf "\n  Uninstalling Openshift-GitOps Operator:\n"
    kubectl delete -k "$DEV_DIR/operators/openshift-gitops" --ignore-not-found=true
    openshift_gitops_csv=$(kubectl get csv -n openshift-operators | grep -ie "openshift-gitops-operator" | cut -d " " -f 1)
    if [[ -n "$openshift_gitops_csv" ]]; then
      kubectl delete csv -n openshift-operators "$openshift_gitops_csv"
    fi
    mapfile -t argo_crds < <(kubectl get crd | grep -iE "argoproj.io|gitopsservices" | cut -d " " -f 1)
    if [[ "${#argo_crds[@]}" -gt 0 ]]; then
      for crd in "${argo_crds[@]}"; do
        kubectl delete crd "$crd" &
        kubectl patch crd "$crd" --type json --patch='[ { "op": "remove", "path": "/metadata/finalizers" } ]' >/dev/null 2>&1
        wait
      done
    fi
    gitops_operator=$(kubectl get operator | grep -ie "gitops-operator" | cut -d " " -f 1)
    if [[ -n "$gitops_operator" ]]; then
      kubectl delete operator "$gitops_operator"
    fi
    # delete instance of the gitops!!! instead of that.
    oc delete project openshift-gitops 

    printf "\n  Uninstalling PAC:\n"
    kubectl delete -k "$GITOPS_DIR/pipelines-as-code" --ignore-not-found=true
    pac_ns=$(kubectl get ns | grep -ie "pipelines-as-code" | cut -d " " -f 1)
    if [[ -n "$pac_ns" ]]; then
      kubectl delete ns "$pac_ns"
    fi

    printf "\n  Uninstalling tekton-chains:\n"
    kubectl delete -k "$GITOPS_DIR/tekton-chains" --ignore-not-found=true
    tkn_chains_ns=$(kubectl get ns | grep -ie "tekton-chains" | cut -d " " -f 1)
    if [[ -n "$pac_ns" ]]; then
      kubectl delete ns "$tkn_chains_ns"
    fi

    printf "\n  Uninstalling tekton-results:\n"
    kubectl delete -k "$GITOPS_DIR/tekton-results/base" --ignore-not-found=true
    tkn_results_ns=$(kubectl get ns | grep -ie "tekton-results" | cut -d " " -f 1)
    if [[ -n "$pac_ns" ]]; then
      kubectl delete ns "$tkn_results_ns"
    fi
}

is_hard_reset_enabled() {
  if [ "$(echo "$RESET_HARD" | tr "[:upper:]" "[:lower:]")" == "true" ] || [ "$RESET_HARD" == "1" ]; then
    echo "true"
  else
    echo "false"
  fi
}

uninstallOpenshiftPipelinesOLMPart() {
    printf "\n  Uninstalling Openshift-Pipelines Operator:\n"
    # We start with deleting tektonconfig so that the 'tekton.dev' CRs are removed gracefully by it.
    kubectl delete tektonconfig config --ignore-not-found=true
    kubectl delete -k "$GITOPS_DIR/openshift-pipelines" --ignore-not-found=true
    openshift_pipelines_csv=$(kubectl get csv -n openshift-operators | grep -ie "openshift-pipelines-operator" | cut -d " " -f 1)
    if [[ -n "$openshift_pipelines_csv" ]]; then
      kubectl delete csv -n openshift-operators "$openshift_pipelines_csv"
    fi
    mapfile -t tekton_crds < <(kubectl get crd | grep -ie "tekton.dev" | cut -d " " -f 1)
    if [[ "${#tekton_crds[@]}" -gt 0 ]]; then
      for crd in "${tekton_crds[@]}"; do
        kubectl delete crd "$crd" &
        kubectl patch crd "$crd" --type json --patch='[ { "op": "remove", "path": "/metadata/finalizers" } ]' >/dev/null 2>&1
        wait
      done
    fi
    openshift_pipelines_operator=$(kubectl get operator | grep -ie "openshift-pipelines-operator" | cut -d " " -f 1)
    if [[ -n "$openshift_pipelines_operator" ]]; then
      kubectl delete operator "$openshift_pipelines_operator"
    fi

    # Checks if the operator are uninstalled successfully
    mapfile -t operators < <(kubectl get operators | grep -iE "openshift-pipelines-operator" | cut -d " " -f 1)
    if (( ${#operators[@]} >= 1 )); then
        printf "\n[ERROR] Couldn't uninstall all Operators, please try removing them manually." >&2
        exit 1
    fi
}

check_if_operators_and_controllers_removed() {
    # Checks if the operators are uninstalled successfully
    mapfile -t operators < <(kubectl get operators | grep -iE "openshift-gitops-operator" | cut -d " " -f 1)
    if (( ${#operators[@]} >= 1 )); then
        printf "\n[ERROR] Couldn't uninstall all Operators, please try removing them manually." >&2
        exit 1
    fi

    # Checks if the operators are uninstalled successfully
    mapfile -t controllers < <(kubectl get ns | grep -iE "tekton-results|tekton-chains|pipelines-as-code" | cut -d " " -f 1)
    if (( ${#controllers[@]} >= 1 )); then
        printf "\n[ERROR] Couldn't remove all Controllers, please try removing them manually." >&2
        exit 1
    fi

    printf "\nAll the operators and controllers are successfully uninstalled.\n"
}

main(){
    parse_args "$@"
    prechecks
    uninstall_minio
    uninstall_pipeline_service

    if [ "$(is_hard_reset_enabled)" == "true" ]; then
      uninstall_operators_and_controllers
      check_if_operators_and_controllers_removed
    fi

    uninstallOpenshiftPipelinesOLMPart
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    main "$@"
fi
