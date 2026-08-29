#!/usr/bin/env bash
# Copyright 2026 The Kubernetes Authors.
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
#
# Setup for the opa-remediation task. Runs from OUTSIDE the cluster during
# `tofu apply`, before the agent starts:
#   1. installs Kyverno (the Policy-as-Code engine),
#   2. applies two AUDIT-mode compliance policies (disallow-privileged,
#      require-resource-limits): audit so existing violations are *reported*, not
#      blocked,
#   3. deploys team workloads that violate those policies (live in the cluster),
#   4. seeds a local bare git repo (the GitOps source of truth) with the workload
#      manifests for the agent to remediate.
#
# Nothing here tells the agent what is wrong. It must scan the policy reports and
# discover the violations itself.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
INFRA_PROVIDER="${INFRA_PROVIDER:-kind}"

if [[ "${INFRA_PROVIDER}" == "gcp" ]]; then
  echo "==> Fetching GKE credentials for cluster ${CLUSTER_NAME:?} in project ${PROJECT_ID:?} (${LOCATION:?})"
  gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone "${LOCATION}" --project "${PROJECT_ID}"
fi

REPO_NAME="${REPO_NAME:?REPO_NAME is required}"
# Fixed default, not ${TMPDIR:-/tmp}: TMPDIR is randomized per-user on macOS,
# but this path is echoed verbatim into the task prompt (see task.yaml),
# which must resolve to the same string on every process that reads it.
# Override the root, never the full path, via DEVOPS_BENCH_SCRATCH_ROOT.
SCRATCH_ROOT="${DEVOPS_BENCH_SCRATCH_ROOT:-/tmp/devops-bench}"

# Validate the root itself, not just containment under it: an unvalidated
# root makes every safe_remove containment check below vacuous (e.g.
# DEVOPS_BENCH_SCRATCH_ROOT=/ would make safe_remove willing to touch any
# absolute path, since everything resolves "under" /). A relative override
# is rejected outright rather than silently resolved against whatever
# directory this script happens to be invoked from. Validation runs against
# a resolved copy, never SCRATCH_ROOT itself: SCRATCH_ROOT stays the literal
# value so REPO_PATH still matches the literal path baked into the task
# prompt even when /tmp is itself a symlink (e.g. to /private/tmp on macOS).
if [[ "${SCRATCH_ROOT}" != /* ]]; then
  echo "ERROR: DEVOPS_BENCH_SCRATCH_ROOT must be an absolute path, got '${SCRATCH_ROOT}'" >&2
  exit 1
fi
mkdir -p "${SCRATCH_ROOT}"
_resolved_scratch_root="$(cd "${SCRATCH_ROOT}" && pwd -P)"
_resolved_home="$(cd "${HOME}" && pwd -P)"
_scratch_root_stripped="${_resolved_scratch_root#/}"
if [[ -z "${_scratch_root_stripped}" ]]; then
  _scratch_root_depth=0
else
  IFS='/' read -r -a _scratch_root_parts <<< "${_scratch_root_stripped}"
  _scratch_root_depth=${#_scratch_root_parts[@]}
fi
if [[ "${_scratch_root_depth}" -lt 2 ]]; then
  echo "ERROR: DEVOPS_BENCH_SCRATCH_ROOT must resolve at least two levels below the filesystem root, got '${SCRATCH_ROOT}' (resolved: '${_resolved_scratch_root}')" >&2
  exit 1
fi
if [[ "${_resolved_scratch_root}" == "${_resolved_home}" ]]; then
  echo "ERROR: DEVOPS_BENCH_SCRATCH_ROOT must not resolve to the home directory, got '${SCRATCH_ROOT}'" >&2
  exit 1
fi

REPO_PATH="${SCRATCH_ROOT}/${REPO_NAME}"
MANIFESTS_DIR="${MANIFESTS_DIR:?MANIFESTS_DIR is required}"
MANIFESTS_DIR="$(cd "${MANIFESTS_DIR}" && pwd)"
KYVERNO_VERSION="${KYVERNO_VERSION:-v1.12.7}"

# Mint-don't-guard: rather than sanitizing an arbitrary caller-supplied path,
# only ever delete a path this script minted under its own scratch root, and
# assert that invariant immediately before deleting it.
safe_remove() {
  local target="$1"
  local root="$2"
  local target_parent target_base resolved_root resolved_parent resolved_target

  # Reject a top-level symlink explicitly rather than relying on rm's own
  # non-follow default for its argument: that default is an implementation
  # detail of rm, not an assertion this script makes, and the resolution
  # below only canonicalizes target's parent, never target itself.
  if [[ -L "${target}" ]]; then
    echo "ERROR: safe_remove: ${target} is a symlink; refusing to remove it" >&2
    exit 1
  fi

  resolved_root="$(cd "${root}" && pwd -P)"
  target_parent="$(dirname -- "${target}")"
  target_base="$(basename -- "${target}")"
  if ! resolved_parent="$(cd "${target_parent}" 2>/dev/null && pwd -P)"; then
    echo "ERROR: safe_remove: parent directory of ${target} does not exist" >&2
    exit 1
  fi
  resolved_target="${resolved_parent}/${target_base}"

  if [[ "${resolved_target}/" != "${resolved_root}/"* ]]; then
    echo "ERROR: safe_remove: ${target} is not under the scratch root ${root}" >&2
    exit 1
  fi
  # Safety-load-bearing, not cosmetic: resolved_target above is built by
  # string-concatenating the resolved parent with the literal basename
  # (target may not exist yet, so it cannot be cd'd into directly), so a
  # basename of ".." would satisfy the prefix check above as a string while
  # actually resolving outside the root. Requiring a *.git suffix is what
  # rules that out, since ".." can never end in ".git".
  if [[ "${target_base}" != *.git ]]; then
    echo "ERROR: safe_remove: ${target} does not look like a minted GitOps repo (*.git)" >&2
    exit 1
  fi
  if [[ "${resolved_target}" == "${resolved_root}" || "${resolved_target}" == "${HOME}" || "${resolved_target}" == "/" ]]; then
    echo "ERROR: safe_remove: refusing to remove ${target}, it resolves to a root, not a minted leaf" >&2
    exit 1
  fi

  rm -rf -- "${resolved_target}"
}

echo "==> Waiting for Kubernetes API server to be reachable..."
api_ready=false
for attempt in $(seq 1 24); do
  if kubectl get ns default &>/dev/null; then
    api_ready=true
    break
  fi
  echo "    API server unreachable (attempt ${attempt}), retrying in 5s..."
  sleep 5
done
if [ "${api_ready}" != true ]; then
  echo "ERROR: Kubernetes API server failed to become reachable" >&2
  exit 1
fi

echo "==> Installing Kyverno ${KYVERNO_VERSION}..."
# Server-side apply: the Kyverno CRDs are large and exceed the client-side
# last-applied annotation limit.
kubectl apply --server-side -f \
  "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"

echo "==> Waiting for the ClusterPolicy CRD to be established..."
kubectl wait --for=condition=established --timeout=120s crd/clusterpolicies.kyverno.io

echo "==> Waiting for Kyverno to be ready..."
kyverno_ready=false
for attempt in $(seq 1 12); do
  if kubectl -n kyverno wait --for=condition=Available deploy --all --timeout=60s; then
    kyverno_ready=true
    break
  fi
  echo "    Waiting for Kyverno deployments, attempt ${attempt} failed, retrying in 5s..."
  sleep 5
done
if [ "${kyverno_ready}" != true ]; then
  echo "ERROR: Kyverno deployments failed to become ready" >&2
  exit 1
fi

echo "==> Removing Kyverno's built-in report cleanup CronJobs..."
# Kyverno v1.12.7 pins bitnami/kubectl:1.28.5 for these cleanup CronJobs, and
# that image was discontinued upstream, so the pods sit in ImagePullBackOff
# forever. They only trim report volume at scale, are not needed for a short
# benchmark run, and upstream removed them entirely in 1.13. Delete both the
# schedules and any jobs/pods they may have already spawned.
kubectl delete cronjob -n kyverno --all --ignore-not-found
kubectl delete job -n kyverno --all --ignore-not-found

echo "==> Applying compliance policies (audit mode)..."
# The Kyverno admission webhook (mutate-policy.kyverno.svc) can take several seconds
# to start serving *after* its deployment reports Available, so a plain apply can fail
# with "failed calling webhook ... context deadline exceeded". Retry to ride it out.
policy_applied=false
for attempt in $(seq 1 12); do
  if kubectl apply -f "${MANIFESTS_DIR}/policies/"; then
    policy_applied=true
    break
  fi
  echo "    policy apply attempt ${attempt} failed (Kyverno webhook not ready yet), retrying in 5s..."
  sleep 5
done
if [ "${policy_applied}" != true ]; then
  echo "ERROR: Kyverno policies failed to apply after retries" >&2
  exit 1
fi

echo "==> Deploying team workloads (some violate the policies)..."
kubectl apply -f "${MANIFESTS_DIR}/workloads/"

echo "==> Waiting for Kyverno's background scan to populate PolicyReports..."
# Ensures the compliance signal exists before the agent starts, so it can't scan
# an empty report set and wrongly conclude the cluster is already compliant.
# A single failing result is not enough: the background scan populates reports
# incrementally, so succeeding on the first violation seen risks starting the
# agent while some of the four seeded workloads (cache, payments, web, worker)
# still have no report at all, which would let it wrongly conclude they are
# already compliant. Wait until failing results collectively name the exact
# four (policy, resource) pairs seeded, not just the four resource names: a
# resource name flagged by the wrong policy must not read as ready.
# Prints the still-missing "policy/resource" pairs, one per line, and exits
# non-zero if the cluster could not be queried at all. Empty output means ready.
_missing_report_pairs() {
  kubectl get policyreport -A -o json 2>/dev/null \
    | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(2)
pairs = set()
for it in data.get("items", []):
    scope = it.get("scope") or {}
    for r in it.get("results", []):
        if r.get("result") != "fail":
            continue
        policy = r.get("policy")
        listed = r.get("resources") or []
        if listed:
            for res in listed:
                if res.get("name"):
                    pairs.add((policy, res["name"]))
        # Kyverno 1.12 emits one PolicyReport per subject and names that subject
        # in the report'"'"'s top-level scope, with no per-result resources list.
        # Match on the Deployment-scoped reports: the ReplicaSet and Pod reports
        # for the same workload carry generated names that never equal the four
        # seeded ones.
        elif scope.get("kind") == "Deployment" and scope.get("name"):
            pairs.add((policy, scope["name"]))
required = {
    ("disallow-privileged-containers", "cache"),
    ("disallow-privileged-containers", "payments"),
    ("require-resource-limits", "web"),
    ("require-resource-limits", "worker"),
}
for policy, name in sorted(required - pairs):
    print(f"{policy}/{name}")
'
}

# A cold kind cluster whose API server is still settling routinely needs longer
# than the 180s this used to allow, so the ceiling is 600s. But a scan that has
# genuinely stalled should not burn the whole budget: if the missing set stops
# shrinking for STALL_ATTEMPTS polls we fail early, and either way the error
# names the pairs that never arrived rather than just "not all of them".
POLL_INTERVAL=5
MAX_ATTEMPTS=120 # 120 * 5s = 600s
STALL_ATTEMPTS=18 # 18 * 5s = 90s with no new pair

reports_ready=false
missing=""
seen_any_response=false
prev_missing=""
stalled=0

for _ in $(seq 1 "${MAX_ATTEMPTS}"); do
  if missing="$(_missing_report_pairs)"; then
    if [ -z "${missing}" ]; then
      echo "    PolicyReports populated with violations for all seeded workloads."
      reports_ready=true
      break
    fi
    if [ "${seen_any_response}" = true ] && [ "${missing}" = "${prev_missing}" ]; then
      stalled=$((stalled + 1))
    else
      stalled=0
    fi
    seen_any_response=true
    prev_missing="${missing}"
    if [ "${stalled}" -ge "${STALL_ATTEMPTS}" ]; then
      echo "ERROR: Kyverno background scan stalled — no new PolicyReport results in $((STALL_ATTEMPTS * POLL_INTERVAL))s." >&2
      break
    fi
  fi
  sleep "${POLL_INTERVAL}"
done

if [ "${reports_ready}" != true ]; then
  if [ "${seen_any_response}" = true ]; then
    echo "ERROR: PolicyReports incomplete; still missing (policy/resource):" >&2
    echo "${missing}" | sed 's/^/  /' >&2
  else
    echo "ERROR: could not read PolicyReports from the cluster at all." >&2
  fi
  exit 1
fi

echo "==> Seeding GitOps repo at ${REPO_PATH}..."
safe_remove "${REPO_PATH}" "${SCRATCH_ROOT}"
git init --bare "${REPO_PATH}"
WORK="$(mktemp -d)"
(
  cd "${WORK}"
  git init -q
  git config user.email "platform@example.com"
  git config user.name "Platform"
  mkdir -p workloads
  cp "${MANIFESTS_DIR}"/workloads/*.yaml workloads/
  git add .
  git -c commit.gpgsign=false commit -q -m "Add team workload manifests"
  git branch -M main
  git remote add origin "${REPO_PATH}"
  git -c safe.bareRepository=all push -q origin main
)
rm -rf "${WORK}"
# Point the bare repo's HEAD at main so a plain `git clone` checks it out.
git -c safe.bareRepository=all -C "${REPO_PATH}" symbolic-ref HEAD refs/heads/main


echo "==> Setup complete."
echo "    Kyverno is auditing; violations will surface in PolicyReports:"
echo "      kubectl get policyreport,clusterpolicyreport -A"
echo "    Workload manifests (GitOps source of truth): git clone ${REPO_PATH}"
