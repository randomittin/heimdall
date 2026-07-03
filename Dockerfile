# Heimdall Control Plane — Cloud Run container image.
#
# Spec: heimdall-cp-deploy-and-diagnostics-spec.md §A1 (Containerize).
# The control plane is a thin bash CLI (bin/heimdall-control-plane) over a
# stdlib-HTTP python engine (bin/lib/cp_*.py). It authenticates every request
# with Ed25519 PKI (cp_auth.py), so the image installs the `cryptography`
# backend; without it the server still serves but PKI identity degrades — in
# production we require it, hence it is a hard dependency here.
#
# Cloud Run contract:
#   - Cloud Run injects PORT (8080). The CMD passes --host 0.0.0.0 --port $PORT
#     so the server binds the container's external interface (cp_server.serve
#     reads HOST/PORT and binds (host, port) via stdlib http.server).
#   - The filesystem is ephemeral. State lives under $HEIMDALL_HOME/control-plane/;
#     we point HEIMDALL_HOME at a writable path. Durable cross-instance state
#     (Firestore) is the A2 adapter — a separate deliverable — and is wired via
#     env at deploy time; this image provides a writable local path so the
#     server boots cleanly on a scale-to-zero instance regardless.
#   - TLS is terminated by Cloud Run (HTTPS automatic). Never expose this image
#     on plain HTTP outside Cloud Run — see deploy/cloud-run/README.md.
#
# Base image pinned by minor (3.12 line, slim).
FROM python:3.12-slim

# Bash is required: heimdall-control-plane is a bash CLI. The slim base ships
# dash as /bin/sh but not bash, so install it explicitly. No recommends, clean
# the apt lists in the same layer to keep the image lean and secret-free.
RUN apt-get update \
    && apt-get install --no-install-recommends -y bash \
    && rm -rf /var/lib/apt/lists/*

# Install the control-plane runtime deps. cryptography provides the Ed25519
# backend cp_auth.py prefers; google-cloud-firestore is the durable Cloud Run
# state backend (HEIMDALL_STATE_BACKEND=firestore selects it — cp_state.get_backend
# lazily imports cp_state_firestore.FirestoreBackend, which imports
# google.cloud.firestore). Without this pin the backend factory raises
# BackendUnavailable every cp_boot tick. google-cloud-run is the durable EXECUTION
# path: CloudRunJobRunner.dispatch (cp_jobrunner) runs the long job via the Cloud Run
# Jobs REST API (google.cloud.run_v2.JobsClient.run_job) over the runtime SA's ADC.
# This image has NO gcloud SDK on purpose — without run_v2 the prod dispatch returns
# {dispatched: False} and the job stays queued forever. Inlined here (one layer, no
# deploy/ COPY) so a .dockerignore exclusion of deploy/ cannot silently drop a dep. The
# pins MUST match deploy/requirements-firestore.txt (the source of truth: firestore
# 2.16.1, run 0.10.19). Pinned for reproducible builds.
RUN pip install --no-cache-dir "cryptography==42.0.8" "google-cloud-firestore==2.16.1" "google-cloud-run==0.10.19" "google-cloud-secret-manager==2.20.2"

# Build-time dependency guard: import the deps the runtime needs at BUILD time so a
# missing/incompatible pin FAILS THE BUILD here (cheapest place to catch it) instead
# of shipping an image that raises BackendUnavailable on every cp_boot tick (firestore)
# or returns {dispatched: False} on every prod job dispatch (run_v2) at runtime.
RUN python -c "import google.cloud.firestore, google.cloud.run_v2, google.cloud.secretmanager, cryptography; print("deps OK")"

# Non-root runtime user (Cloud Run best practice; least privilege).
RUN groupadd --system heimdall \
    && useradd --system --gid heimdall --home-dir /app --no-create-home heimdall

WORKDIR /app

# Copy only what the control plane needs: the bin/ CLIs and the bin/lib/ engine.
# .dockerignore keeps .git, worktrees, tests, and fixtures out of the context.
COPY bin/ /app/bin/

# Make the CLIs invocable by name and place writable state under /app/state,
# owned by the runtime user (the ephemeral, per-instance scratch path).
RUN chmod -R a+rx /app/bin \
    && mkdir -p /app/state \
    && chown -R heimdall:heimdall /app/state

ENV PATH="/app/bin:${PATH}" \
    HEIMDALL_HOME="/app/state" \
    PORT="8080" \
    PYTHONDONTWRITEBYTECODE="1" \
    PYTHONUNBUFFERED="1"

USER heimdall

EXPOSE 8080

# Bind the container's external interface on the Cloud-Run-injected PORT.
# serve reads --host/--port; 0.0.0.0 makes it reachable by the Cloud Run proxy.
CMD ["sh", "-c", "exec heimdall-control-plane serve --host 0.0.0.0 --port \"${PORT:-8080}\" --home \"${HEIMDALL_HOME:-/app/state}\""]
