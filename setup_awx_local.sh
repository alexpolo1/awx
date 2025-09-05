#!/usr/bin/env bash
set -euo pipefail

# setup_awx_local.sh
# Minimal, idempotent script to deploy awx-operator and an AWX instance on Minikube.
# Usage: ./setup_awx_local.sh [--port PORT] [--nodeport NODEPORT] [--repo-root PATH]

PORT=8082
NODEPORT=30081
AWX_NAMESPACE=awx
REPO_ROOT="$(pwd)"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --nodeport) NODEPORT="$2"; shift 2 ;;
    --namespace) AWX_NAMESPACE="$2"; shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
  --dry-run) DRY_RUN=1; shift 1 ;;
    -h|--help) echo "Usage: $0 [--port PORT] [--nodeport NODEPORT] [--namespace NAMESPACE] [--repo-root PATH]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo "Running AWX local setup"
echo "Port-forward local port: ${PORT} -> service:80 (bind 0.0.0.0)"
echo "AWX NodePort to request: ${NODEPORT}"

if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  echo "DRY RUN: cluster operations will be skipped"
fi

# prerequisites
for cmd in kubectl minikube curl ss ip; do
  if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
    # skip checking cluster commands in dry-run mode
    break
  fi
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "Missing prerequisite: $cmd"; exit 1
  fi
done

# start minikube if needed
if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  echo "DRY RUN: skipping cluster start/check"
else
  if ! kubectl get nodes >/dev/null 2>&1; then
    echo "No Kubernetes cluster detected. Starting minikube..."
    minikube start
  fi
fi

# ensure namespace
kubectl get ns ${AWX_NAMESPACE} >/dev/null 2>&1 || kubectl create ns ${AWX_NAMESPACE}

# apply CRDs and operator manager from the awx-operator repo
if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  echo "DRY RUN: would apply CRDs and manager from ${REPO_ROOT}/config"
else
  if [ -d "${REPO_ROOT}/config/crd" ]; then
    kubectl apply -k "${REPO_ROOT}/config/crd"
  fi
  if [ -d "${REPO_ROOT}/config/rbac" ]; then
    kubectl apply -k "${REPO_ROOT}/config/rbac"
  fi
  if [ -d "${REPO_ROOT}/config/manager" ]; then
    kubectl apply -k "${REPO_ROOT}/config/manager" -n ${AWX_NAMESPACE} || true
  fi
fi

# create leader-election RBAC if missing
cat <<'EOF' | (
  if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
    cat >/dev/null
  else
    kubectl apply -n ${AWX_NAMESPACE} -f -
  fi
)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: awx-operator-leader-election
rules:
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get","create","update","patch","delete","watch","list"]
EOF

if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  echo "DRY RUN: would ensure rolebinding awx-operator-leader-election in ${AWX_NAMESPACE}"
else
  kubectl get rolebinding awx-operator-leader-election -n ${AWX_NAMESPACE} >/dev/null 2>&1 || cat <<'EOF' | kubectl apply -n ${AWX_NAMESPACE} -f -
EOF
fi

if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  :
else
  cat <<'EOF' | kubectl apply -n ${AWX_NAMESPACE} -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: awx-operator-leader-election
subjects:
- kind: ServiceAccount
  name: controller-manager
roleRef:
  kind: Role
  name: awx-operator-leader-election
  apiGroup: rbac.authorization.k8s.io
EOF
fi
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: awx-operator-leader-election
subjects:
- kind: ServiceAccount
  name: controller-manager
roleRef:
  kind: Role
  name: awx-operator-leader-election
  apiGroup: rbac.authorization.k8s.io
EOF

# wait for operator deployment to be available
echo "Waiting for controller-manager deployment to be available..."
if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  echo "DRY RUN: skipping wait for controller-manager"
else
  kubectl -n ${AWX_NAMESPACE} wait --for=condition=available deployment/controller-manager --timeout=180s || true
fi

# Create corrected AWX CR yaml in /tmp and apply
TMP_CR=/tmp/awx-cr-generated.yaml
cat > ${TMP_CR} <<EOF
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: ${AWX_NAMESPACE}
spec:
  service_type: NodePort
  ingress_type: none
  hostname: awx.local
  nodeport_port: ${NODEPORT}
  no_log: false
  create_preload_data: true
  replicas: 1
EOF

echo "Applying AWX CR from ${TMP_CR}"
if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  echo "DRY RUN: would apply ${TMP_CR}"
else
  kubectl apply -f ${TMP_CR}
fi

# force reconcile
if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  echo "DRY RUN: would annotate AWX CR to force reconcile"
else
  kubectl -n ${AWX_NAMESPACE} annotate awx awx awx-operator-refresh=$(date +%s) --overwrite || true
fi

# wait for awx-web pod readiness (give it a long timeout because migrations run)
echo "Waiting for awx-web pod to become ready (this may take several minutes)..."
if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  echo "DRY RUN: skipping wait for awx-web readiness"
else
  kubectl -n ${AWX_NAMESPACE} wait --for=condition=ready pod -l app.kubernetes.io/name=awx-web --timeout=900s || true
fi

# choose a free local port and start port-forward bound to 0.0.0.0
for p in ${PORT} $(seq 18080 18090); do
  ss -ltn | awk '{print $4}' | grep -q ":$p$" || { LISTEN_PORT=$p; break; }
done
if [ -z "${LISTEN_PORT:-}" ]; then echo "No free port found to bind port-forward"; exit 1; fi
if [ "${DRY_RUN}" = "1" ] || [ "${SKIP_CLUSTER:-0}" = "1" ]; then
  echo "DRY RUN: would start port-forward: host-port ${LISTEN_PORT} -> awx-service:80"
else
  kubectl -n ${AWX_NAMESPACE} port-forward --address 0.0.0.0 svc/awx-service ${LISTEN_PORT}:80 &>/tmp/awx-port-forward.log & echo $! > /tmp/awx-pf.pid
fi
sleep 1
echo "Port-forward started: host-port ${LISTEN_PORT} -> awx-service:80"

# print access info
HOST_IPS=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | tr '\n' ' ')
echo "Open AWX in your browser using one of these URLs (from another machine on your LAN):"
for ip in ${HOST_IPS}; do
  echo "  http://${ip}:${LISTEN_PORT}"
done
echo "Or use the Minikube VM NodePort (may not be routable from other LAN hosts):"
echo "  http://$(minikube ip):${NODEPORT}"

# show admin password
echo "Admin credentials (user: admin). Retrieve password with this command on the host:"
echo "  kubectl -n ${AWX_NAMESPACE} get secret awx-admin-password -o jsonpath='{.data.password}' | base64 -d"

echo "Setup finished. Monitor operator logs with: kubectl -n ${AWX_NAMESPACE} logs deployment/controller-manager -c awx-manager --follow"
