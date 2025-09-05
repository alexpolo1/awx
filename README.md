# awx

AWX Local Setup for Minikube

This folder provides an automated script and instructions to deploy the awx-operator and a single-node AWX instance locally using Minikube + kubectl.

Files
- `setup_awx_local.sh` — idempotent installer script. Run from inside the `awx-operator` repo (it expects the repo files like `config/` and `awx.yml` to be present in the parent folder).
- `cleanup.sh` — stops port-forward and optionally deletes the `awx` namespace and CRs.
- `README_GIT_PUSH.md` — instructions to create a new remote repo and push this directory to your git host.

Quickstart
1. From the `awx-operator` repo root, copy or open this folder:

```bash
cd /home/alex/awx-operator
ls -la awx-local-setup
```

2. Make scripts executable and run the installer:

```bash
chmod +x awx-local-setup/setup_awx_local.sh awx-local-setup/cleanup.sh
./awx-local-setup/setup_awx_local.sh --port 8082
```

3. Open AWX in your browser at the host IP and port printed by the script, or use the NodePort on the Minikube VM.

Notes
- The script is intended for local development/testing only. For production, use official operator docs.
- The script tries to be idempotent and safe. It does not delete CRDs or secrets automatically.
