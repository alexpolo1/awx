#!/usr/bin/env bash
set -euo pipefail

# cleanup.sh
# Stops port-forward and optionally deletes the awx namespace and CRs.

PORTF_PID_FILE=/tmp/awx-pf.pid
NAMESPACE=awx

if [ -f "$PORTF_PID_FILE" ]; then
  PID=$(cat $PORTF_PID_FILE)
  echo "Killing port-forward PID $PID"
  kill $PID 2>/dev/null || true
  rm -f $PORTF_PID_FILE
  rm -f /tmp/awx-port-forward.log || true
else
  echo "No port-forward PID file present"
fi

read -p "Delete the AWX namespace and all AWX resources? [y/N]: " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  echo "Deleting namespace $NAMESPACE"
  kubectl delete ns $NAMESPACE --wait=true || true
  echo "Note: CRDs are not deleted automatically. Remove them manually if desired."
fi

echo "Cleanup complete."
