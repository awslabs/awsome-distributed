#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Tier-B: end-to-end Megatron-Core MoE A/B for the DeepEP token dispatcher.
#
# Runs the SAME training PyTorchJob TWICE per overlap mode, changing ONLY the MoE
# token dispatcher via the MOE_DISPATCHER env on the rendered manifest:
#
#   MOE_DISPATCHER=alltoall  -> moe_token_dispatcher_type="alltoall"   (NCCL all-to-all over EFA)
#   MOE_DISPATCHER=deepep    -> moe_token_dispatcher_type="flex",
#                               moe_flex_dispatcher_backend="deepep"    (UCCL EFA drop-in)
#
# conf/kimi_k2_sft.py (owned by another process) MUST honor that one-line env
# contract -- see benchmarks/README.md. This script does NOT edit the config or
# the manifest body; it renders the PyTorchJob template with envsubst (setting
# MOE_DISPATCHER / MOE_A2A_OVERLAP / TRAIN_ITERS), applies it, waits for the job
# to finish, pulls rank-0 logs, asserts the EFA provider line, and scrapes the
# iteration timers.
#
# CRITICAL CONFOUNDER CONTROL: every other knob is held IDENTICAL across the two
# arms -- model, data, parallelism (TP8/EP32/PP8/DP4), global batch, seq len,
# precision, image, FSx mounts, EFA env, AND the A2A/EP overlap flags
# (--overlap-moe-expert-parallel-comm, --delay-wgrad-compute). If the two arms
# differ in overlap, the A/B measures overlap, not the dispatcher. MOE_A2A_OVERLAP
# is set IDENTICALLY for both arms within a mode (so overlap never differs between
# alltoall and deepep). Megatron's 1F1B overlap hides up to ~93% of A2A latency,
# so the realistic (overlap=on) delta is MUCH smaller than the raw comm speedup --
# a small overlap=on delta is the CORRECT result, not a benchmark failure.
# OVERLAP=off additionally runs the overlap-OFF pair, which fully exposes the A2A
# and gives the dispatcher-isolation UPPER BOUND (never the deployment number).
#
# Megatron prints (training.py training_log):
#   - 'elapsed time per iteration (ms): X'        ALWAYS              (primary metric)
#   - 'throughput per GPU (TFLOP/s/GPU): X'        ONLY with --log-throughput
# tokens/sec is NOT a printed label (RL path only) and there is NO per-op
# dispatch/combine timer (NVTX/Nsight only). So we scrape iter-time + TFLOP/s and
# DERIVE tokens/s = GLOBAL_BATCH * SEQ_LEN / iter_time_s.
set -euo pipefail

# ----------------------------------------------------------------------------
# Config (override via env). Tier-B needs the full 256-GPU config -> 32 nodes,
# which is the cb-4ff6b84d block (active 2026-05-31T11:30Z .. 2026-06-01T11:30Z).
# ----------------------------------------------------------------------------
CTX="${CTX:-shared-usw2}"                 # kubectl context -> ml-clusters-shared-us-west-2
NAMESPACE="${NAMESPACE:-kimi-k2-bench}"
# 32-node block for the full TP8/EP32/PP8/DP4 = 256-GPU run.
CB_SHORT="${CB_SHORT:-4ff6b84d}"

# ----------------------------------------------------------------------------
# Template placeholder values (EXPORTED below for envsubst). Canonical defaults
# match the main test-case manifest (kubernetes/manifests/kimi-k2-sft-pytorchjob.
# yaml-template): bare ${VAR} placeholders, image is ${REPO_URI}. Both arms MUST
# use the identical values (library-/shape-skew confounder); only MOE_DISPATCHER
# (and MOE_A2A_OVERLAP per mode, identical across arms) changes between arms.
# ----------------------------------------------------------------------------
# Pinned training image (NO 'latest' tag). conf/kimi_k2_sft.py + UCCL deep_ep are
# baked in here; both arms MUST use the identical image (library-skew confounder).
REPO_URI="${REPO_URI:-159553542841.dkr.ecr.us-west-2.amazonaws.com/megatron-bridge-uccl:nemo-25.11.01-uccl-0dc87eb}"
NUM_NODES="${NUM_NODES:-32}"             # 32x p6-b300.48xlarge = 256x B300
GPU_PER_NODE="${GPU_PER_NODE:-8}"        # nvidia.com/gpu per node
EFA_PER_NODE="${EFA_PER_NODE:-16}"       # vpc.amazonaws.com/efa per node (16x400G)
INSTANCE_TYPE="${INSTANCE_TYPE:-p6-b300.48xlarge}"
FSX_CLAIM="${FSX_CLAIM:-fsx-claim}"      # PVC for the FSx-for-Lustre fs at /fsx
TENSOR_PARALLEL="${TENSOR_PARALLEL:-8}"
EXPERT_PARALLEL="${EXPERT_PARALLEL:-32}"
PIPELINE_PARALLEL="${PIPELINE_PARALLEL:-8}"
DATA_PARALLEL="${DATA_PARALLEL:-4}"

# PyTorchJob manifest TEMPLATE (bare ${VAR} envsubst placeholders). Lives in
# this directory; this script renders it with `envsubst < template` after
# EXPORTing the full placeholder set (see run_arm) and applies the result.
# TODO(validate against image): confirm the template path + that it declares the
#   placeholder set below and nothing else the container needs at runtime.
TEMPLATE="${TEMPLATE:-$(dirname "$0")/kimi-k2-bench-pytorchjob.yaml-template}"

# Measurement window. The first WARMUP_ITERS measured iterations are DROPPED
# (iter-0 allocator/compile outlier; UCCL/DeepEP autotune SM counts on the first
# dispatch/combine calls). Report MEDIANS over the remaining MEASURE_ITERS.
WARMUP_ITERS="${WARMUP_ITERS:-20}"
MEASURE_ITERS="${MEASURE_ITERS:-50}"
TRAIN_ITERS="${TRAIN_ITERS:-$(( WARMUP_ITERS + MEASURE_ITERS ))}"

# Derivation inputs -- MUST match conf/kimi_k2_sft.py. Used only to DERIVE
# tokens/s from iter-time; they do not change what runs.
# TODO(validate against image): keep in sync with conf/kimi_k2_sft.py.
GLOBAL_BATCH="${GLOBAL_BATCH:-512}"       # TODO(validate against image)
SEQ_LEN="${SEQ_LEN:-4096}"               # TODO(validate against image)
WORLD_SIZE="${WORLD_SIZE:-256}"          # TP8*EP/... = 32 nodes x 8 B300 = 256 GPUs

# B300 BF16 dense peak (TFLOP/s/GPU) for the MFU = TFLOP/s/GPU / peak derivation
# (RESULTS.md [^mfu] footnote). Overridable; if unset/0 the MFU cells are "NA".
# TODO(validate against image): confirm the B300 BF16 peak to divide by.
B300_BF16_PEAK_TFLOPS="${B300_BF16_PEAK_TFLOPS:-0}"  # TODO(validate against image)

# Overlap mode: "on"=realistic deployment (overlap flags ON, both arms);
# "off"=dispatcher isolation (overlap OFF, both arms, upper-bound delta);
# "both"=run on then off. Within a mode BOTH arms use the same MOE_A2A_OVERLAP.
OVERLAP="${OVERLAP:-on}"

# Completion timeout for a single 256-GPU arm: image pull + NCCL/EFA init +
# (WARMUP+MEASURE) iters. Generous on purpose; do NOT shrink for a big run.
JOB_TIMEOUT="${JOB_TIMEOUT:-7200s}"
# Time to wait for the first pod to go Ready (scheduling + image pull on 32 nodes).
READY_TIMEOUT="${READY_TIMEOUT:-1800s}"

# Benchmark outputs -> /fsx/kimi-k2/bench (canonical layout). The sibling
# 0.comm-microbench.sh writes Tier-A under /fsx/kimi-k2/bench/tier-a-<ts>; this
# Tier-B script writes under /fsx/kimi-k2/bench/tier-b/<ts>. Same /fsx/kimi-k2/bench root.
OUTDIR="${OUTDIR:-/fsx/kimi-k2/bench/tier-b}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS="${RESULTS:-$(dirname "$0")/RESULTS.md}"
RUNDIR="${OUTDIR}/${TS}"
mkdir -p "$RUNDIR" 2>/dev/null || true

# EFA provider assertion string emitted by aws-ofi-nccl. NOTE: aws-ofi-nccl only
# prints this at NCCL INFO level -- if the job runs NCCL_DEBUG=WARN the line never
# appears and EVERY run would be wrongly discarded. The template/config MUST set
# NCCL_DEBUG=INFO (NCCL_DEBUG_SUBSYS=INIT,NET keeps the 256-GPU log readable).
# TODO(validate against image): confirm the manifest/config sets NCCL_DEBUG=INFO.
EFA_ASSERT="${EFA_ASSERT:-NET/OFI Selected Provider is efa}"

# The COMPLETE placeholder set the template exposes (exported per-arm below, then
# rendered with bare `envsubst < template`). The template contains NO literal
# runtime $VAR refs -- torchrun's rendezvous env (RANK/WORLD_SIZE/MASTER_ADDR/...)
# is injected by the operator and read by the in-image entrypoint, never written
# in the manifest body -- so a bare envsubst is safe. This MUST match the
# template's placeholder set exactly.
SUBST_VARS='${JOB_NAME} ${REPO_URI} ${NUM_NODES} ${GPU_PER_NODE} ${EFA_PER_NODE} ${INSTANCE_TYPE} ${FSX_CLAIM} ${TENSOR_PARALLEL} ${EXPERT_PARALLEL} ${PIPELINE_PARALLEL} ${DATA_PARALLEL} ${MOE_DISPATCHER} ${MOE_A2A_OVERLAP} ${TRAIN_ITERS}'

echo "== Tier-B end-to-end dispatcher A/B =="
echo "   ctx=$CTX ns=$NAMESPACE cb=$CB_SHORT image=$REPO_URI"
echo "   template=$TEMPLATE"
echo "   parallelism: TP$TENSOR_PARALLEL/EP$EXPERT_PARALLEL/PP$PIPELINE_PARALLEL/DP$DATA_PARALLEL (world=$WORLD_SIZE)"
echo "   iters: warmup(dropped)=$WARMUP_ITERS measure=$MEASURE_ITERS train=$TRAIN_ITERS overlap=$OVERLAP"
echo "   out=$RUNDIR  results=$RESULTS"
echo

[ -f "$TEMPLATE" ] || { echo "FATAL: PyTorchJob template not found: $TEMPLATE" >&2; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "FATAL: envsubst not found (install gettext-base)" >&2; exit 1; }

# Sanity: the 32-node block must be active. Print a verification hint.
echo "   NOTE: cb-$CB_SHORT (cr-04be19500f13f4a35) is active 2026-05-31T11:30Z..2026-06-01T11:30Z."
echo "   Verify nodes Ready before launching:"
echo "     kubectl --context $CTX get nodes -l capacity-reservation=$CB_SHORT"
echo

# Ensure the namespace and the etcd rendezvous Service exist BEFORE any arm runs.
# The Worker-only bench PyTorchJob uses rdzvBackend=etcd / rdzvHost=etcd (TorchElastic),
# so a Service named `etcd` (port 2379) must be reachable in the namespace or the 32
# workers hang with nothing to rendezvous against. This mirrors the etcd Service+
# Deployment shipped in the main test case manifest and is idempotent (safe to re-run).
ensure_etcd() {
  kubectl --context "$CTX" get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || kubectl --context "$CTX" create namespace "$NAMESPACE"
  kubectl --context "$CTX" -n "$NAMESPACE" apply -f - <<'ETCD_YAML'
apiVersion: v1
kind: Service
metadata:
  name: etcd
spec:
  ports:
    - name: etcd-client-port
      port: 2379
      protocol: TCP
      targetPort: 2379
  selector:
    app: etcd
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: etcd
  name: etcd
spec:
  replicas: 1
  selector:
    matchLabels:
      app: etcd
  template:
    metadata:
      labels:
        app: etcd
    spec:
      containers:
        - name: etcd
          command: ["/usr/local/bin/etcd"]
          args:
            - "--data-dir"
            - "/var/lib/etcd"
            - "--enable-v2"
            - "--listen-client-urls"
            - "http://0.0.0.0:2379"
            - "--advertise-client-urls"
            - "http://0.0.0.0:2379"
            - "--initial-cluster-state"
            - "new"
          image: registry.k8s.io/etcd:3.4.13-0
          ports:
            - containerPort: 2379
              name: client
              protocol: TCP
            - containerPort: 2380
              name: server
              protocol: TCP
      restartPolicy: Always
ETCD_YAML
  kubectl --context "$CTX" -n "$NAMESPACE" rollout status deploy/etcd --timeout=120s
}
ensure_etcd
echo

# Track the currently-running job so a trap can clean it up on early exit.
CUR_JOB=""
cleanup() {
  if [ -n "$CUR_JOB" ]; then
    kubectl --context "$CTX" -n "$NAMESPACE" delete pytorchjob "$CUR_JOB" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
    CUR_JOB=""
  fi
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------------
# run_arm <dispatcher> <overlap_mode> -> renders+applies the PyTorchJob with the
#   per-arm env, waits for completion, pulls rank-0 logs to a file, then deletes
#   the job. Echoes the absolute log path on stdout (LAST line) for the caller.
# ----------------------------------------------------------------------------
run_arm() {
  local dispatcher="$1" overlap_mode="$2"
  local arm="${dispatcher}-overlap-${overlap_mode}"
  # MOE_A2A_OVERLAP gates the overlap flags inside conf/kimi_k2_sft.py, which
  # treats overlap as ON iff the value == "on". Both arms in a mode get the SAME
  # value -> overlap is constant across alltoall vs deepep.
  # TODO(validate against image): confirm conf/kimi_k2_sft.py honors MOE_DISPATCHER
  #   + MOE_A2A_OVERLAP {on,off}, that --log-throughput is set, and that
  #   --overlap-moe-expert-parallel-comm is compatible with BOTH dispatchers in
  #   this Megatron version. If overlap is dispatcher-incompatible, the clean
  #   comparison is overlap=off on BOTH arms (do not let overlap differ).
  local overlap_env="$overlap_mode"   # literal "on" / "off"

  # Per-arm UNIQUE job name. The template renders metadata.name: ${JOB_NAME}, so
  # the wait/log/cleanup below all reference this SAME name. k8s names: lowercase,
  # <=63 chars. Job-name suffix uses the literal on/off overlap value.
  local job="kimi-k2-bench-${dispatcher}-${overlap_env}"
  local log="${RUNDIR}/${arm}.log"
  local manifest="${RUNDIR}/${arm}.yaml"
  echo "---- arm: ${arm}  (job=${job}) ----" >&2

  # Render the template with bare envsubst: EXPORT the full placeholder set, then
  # `envsubst < template`. The template has no literal runtime $VAR refs, so a
  # bare envsubst is safe (and required -- the template uses bare ${VAR}, no :-).
  export JOB_NAME="$job" REPO_URI="$REPO_URI" NUM_NODES="$NUM_NODES" \
    GPU_PER_NODE="$GPU_PER_NODE" EFA_PER_NODE="$EFA_PER_NODE" \
    INSTANCE_TYPE="$INSTANCE_TYPE" FSX_CLAIM="$FSX_CLAIM" \
    TENSOR_PARALLEL="$TENSOR_PARALLEL" EXPERT_PARALLEL="$EXPERT_PARALLEL" \
    PIPELINE_PARALLEL="$PIPELINE_PARALLEL" DATA_PARALLEL="$DATA_PARALLEL" \
    MOE_DISPATCHER="$dispatcher" MOE_A2A_OVERLAP="$overlap_env" TRAIN_ITERS="$TRAIN_ITERS"
  envsubst < "$TEMPLATE" > "$manifest"

  # Fresh start: drop any stale job of this exact name, then apply.
  kubectl --context "$CTX" -n "$NAMESPACE" delete pytorchjob "$job" \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
  CUR_JOB="$job"
  kubectl --context "$CTX" -n "$NAMESPACE" apply -f "$manifest"

  # Wait for the rank-0 Worker pod to go Ready (scheduling + image pull on 32
  # nodes). Worker-only topology (no Master): rank 0 is Worker index 0.
  echo "   waiting for ${arm} worker-0 pod Ready (<= ${READY_TIMEOUT})..." >&2
  kubectl --context "$CTX" -n "$NAMESPACE" wait --for=condition=Ready pod \
    -l "training.kubeflow.org/job-name=${job},training.kubeflow.org/replica-type=worker,training.kubeflow.org/replica-index=0" \
    --timeout="$READY_TIMEOUT" >&2 || echo "   (Ready wait timed out/failed; continuing to completion wait)" >&2

  # Wait for the PyTorchJob to Succeed. kubeflow training-operator sets a
  # status.conditions entry of type 'Succeeded' (status True) on completion.
  # TODO(cite): kubeflow/training-operator PyTorchJob conditions
  #   (Created/Running/Succeeded/Failed) --
  #   https://www.kubeflow.org/docs/components/trainer/legacy-v1/user-guides/pytorch/
  #   Confirm `kubectl wait --for=condition=Succeeded pytorchjob/...` is honored
  #   by the operator version on this cluster (it is version-dependent on CRDs).
  echo "   waiting for ${arm} to finish ${TRAIN_ITERS} iters (<= ${JOB_TIMEOUT})..." >&2
  kubectl --context "$CTX" -n "$NAMESPACE" wait --for=condition=Succeeded \
    "pytorchjob/${job}" --timeout="$JOB_TIMEOUT" >&2 \
    || echo "   (Succeeded wait timed out/failed; pulling whatever logs exist)" >&2

  # Pull rank-0 logs to file (non-follow; the job has already finished). Worker-0
  # is the rank-0 pod where Megatron's training_log() prints. Equivalent direct
  # form: kubectl -n "$NAMESPACE" logs "${job}-worker-0".
  kubectl --context "$CTX" -n "$NAMESPACE" logs \
    -l "training.kubeflow.org/job-name=${job},training.kubeflow.org/replica-type=worker,training.kubeflow.org/replica-index=0" \
    --tail=-1 > "$log" 2>/dev/null || true

  # Explicit cleanup of this arm before the next one is launched.
  kubectl --context "$CTX" -n "$NAMESPACE" delete pytorchjob "$job" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  CUR_JOB=""

  echo "   log -> $log" >&2
  echo "$log"
}

# ----------------------------------------------------------------------------
# assert_efa <log> -> 0 if the EFA provider line is present (valid run), else 1.
# Socket-fallback => discard the run (confounder control). Does NOT trip set -e.
# ----------------------------------------------------------------------------
assert_efa() {
  local log="$1"
  if grep -q "$EFA_ASSERT" "$log" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ----------------------------------------------------------------------------
# scrape_arm <log> -> "median_iter_ms median_tflops median_tokens_s n_kept"
# Drops first WARMUP_ITERS measured lines; medians over the rest.
# tokens/s is DERIVED (not a Megatron label).
# ----------------------------------------------------------------------------
scrape_arm() {
  local log="$1"
  python3 - "$log" "$WARMUP_ITERS" "$GLOBAL_BATCH" "$SEQ_LEN" <<'PY'
import re, sys, statistics
log, warmup, gbs, seq = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
iter_ms, tflops = [], []
# Megatron training_log lines, e.g.:
#  "... elapsed time per iteration (ms): 1234.5 | ... | throughput per GPU (TFLOP/s/GPU): 678.9 | ..."
re_ms = re.compile(r"elapsed time per iteration \(ms\):\s*([0-9.]+)")
re_tf = re.compile(r"throughput per GPU \(TFLOP/s/GPU\):\s*([0-9.]+)")
try:
    for line in open(log, errors="ignore"):
        m = re_ms.search(line)
        if m: iter_ms.append(float(m.group(1)))
        t = re_tf.search(line)
        if t: tflops.append(float(t.group(1)))
except FileNotFoundError:
    pass
# Drop warmup (iter-0 outlier + UCCL/DeepEP autotune on first calls).
iter_ms = iter_ms[warmup:]
tflops  = tflops[warmup:]
if not iter_ms:
    print("NA NA NA 0"); sys.exit(0)
med_ms = statistics.median(iter_ms)
med_tf = statistics.median(tflops) if tflops else float("nan")
# Derived tokens/s = global_batch * seq_len / iter_time_s  (NOT a Megatron label).
med_tok = gbs * seq / (med_ms / 1000.0)
tf_str = f"{med_tf:.1f}" if med_tf == med_tf else "NA"
print(f"{med_ms:.1f} {tf_str} {med_tok:.0f} {len(iter_ms)}")
PY
}

emit_row() {
  # $1=mode  $2=alltoall_stats  $3=deepep_stats  $4=alltoall_valid(0/1)  $5=deepep_valid(0/1)
  # Appends FOUR rows per mode matching the RESULTS.md Tier-B schema exactly:
  #   overlap | metric | alltoall | deepep | delta
  # for metrics: elapsed time per iteration (ms), throughput per GPU (TFLOP/s/GPU),
  # MFU, derived tokens/s. The `overlap` column carries the bare mode (on/off).
  local mode="$1" a_stats="$2" d_stats="$3" a_ok="$4" d_ok="$5"
  local a_ms a_tf a_tok a_n d_ms d_tf d_tok d_n
  read -r a_ms a_tf a_tok a_n <<<"$a_stats"
  read -r d_ms d_tf d_tok d_n <<<"$d_stats"

  # MFU = TFLOP/s/GPU / B300 BF16 peak (NA if peak unset or tflops missing).
  local a_mfu="NA" d_mfu="NA"
  if [ "$a_ok" -eq 1 ] && [ "$a_tf" != "NA" ]; then
    a_mfu="$(python3 -c "p=$B300_BF16_PEAK_TFLOPS; print('NA' if p<=0 else f'{($a_tf/p)*100:.1f}%')")"
  fi
  if [ "$d_ok" -eq 1 ] && [ "$d_tf" != "NA" ]; then
    d_mfu="$(python3 -c "p=$B300_BF16_PEAK_TFLOPS; print('NA' if p<=0 else f'{($d_tf/p)*100:.1f}%')")"
  fi

  # delta = (alltoall_iter_ms / deepep_iter_ms) - 1, i.e. iter-time speedup of deepep.
  local delta="NA"
  if [ "$a_ok" -eq 1 ] && [ "$d_ok" -eq 1 ] && [ "$a_ms" != "NA" ] && [ "$d_ms" != "NA" ]; then
    delta="$(python3 -c "print(f'{(($a_ms/$d_ms)-1)*100:+.1f}%')")"
  fi

  # If either arm is EFA-invalid (socket-fallback), mark its cells discarded.
  [ "$a_ok" -eq 0 ] && { a_ms="DISCARDED(socket-fallback)"; a_tf="DISCARDED"; a_mfu="DISCARDED"; a_tok="DISCARDED"; }
  [ "$d_ok" -eq 0 ] && { d_ms="DISCARDED(socket-fallback)"; d_tf="DISCARDED"; d_mfu="DISCARDED"; d_tok="DISCARDED"; }

  {
    echo "| ${mode} | elapsed time per iteration (ms) | ${a_ms} (n=${a_n}) | ${d_ms} (n=${d_n}) | ${delta} |"
    echo "| ${mode} | throughput per GPU (TFLOP/s/GPU) | ${a_tf} | ${d_tf} | — |"
    echo "| ${mode} | MFU | ${a_mfu} | ${d_mfu} | — |"
    echo "| ${mode} | derived tokens/s | ${a_tok} | ${d_tok} | — |"
  } >> "$RESULTS"
  # Echo the per-mode iter-time delta to the console too.
  echo "  delta (overlap=${mode}, deepep vs alltoall iter-time): ${delta}" >&2
}

run_mode() {
  local mode="$1"
  local a_log d_log a_ok=1 d_ok=1 a_stats d_stats

  a_log="$(run_arm alltoall "$mode")"
  d_log="$(run_arm deepep   "$mode")"

  # Confounder control: assert EFA on each arm; socket-fallback => discard.
  if assert_efa "$a_log"; then echo "  EFA provider OK: alltoall-overlap-${mode}" >&2
  else a_ok=0; echo "  WARNING: '$EFA_ASSERT' NOT found in $a_log -> alltoall arm DISCARDED (socket-fallback or NCCL_DEBUG<INFO)" >&2; fi
  if assert_efa "$d_log"; then echo "  EFA provider OK: deepep-overlap-${mode}" >&2
  else d_ok=0; echo "  WARNING: '$EFA_ASSERT' NOT found in $d_log -> deepep arm DISCARDED (socket-fallback or NCCL_DEBUG<INFO)" >&2; fi

  a_stats="$(scrape_arm "$a_log")"
  d_stats="$(scrape_arm "$d_log")"

  echo
  echo "==== Tier-B result (overlap=${mode}) ===="
  echo "  alltoall (NCCL/EFA) : iter_ms tflops tok_s n = ${a_stats}  valid=${a_ok}"
  echo "  deepep   (UCCL/EFA) : iter_ms tflops tok_s n = ${d_stats}  valid=${d_ok}"
  emit_row "$mode" "$a_stats" "$d_stats" "$a_ok" "$d_ok"
}

# RESULTS.md header for this run. The table schema (overlap | metric | alltoall |
# deepep | delta) and the four metric labels below MUST match the Tier-B table in
# RESULTS.md exactly so appended rows slot into the documented schema.
{
  echo ""
  echo "### Tier-B run ${TS}  (TP${TENSOR_PARALLEL}/EP${EXPERT_PARALLEL}/PP${PIPELINE_PARALLEL}/DP${DATA_PARALLEL}, world=${WORLD_SIZE}, cb-${CB_SHORT})"
  echo "_warmup dropped=${WARMUP_ITERS}, measured=${MEASURE_ITERS}, image nemo-25.11.01-uccl-0dc87eb_"
  echo "_delta = (alltoall_iter_ms / deepep_iter_ms) - 1 ; overlap=on is the deployment number, overlap=off is the isolation upper bound_"
  echo ""
  echo "| overlap | metric | alltoall | deepep | delta |"
  echo "|---------|--------|----------|--------|-------|"
} >> "$RESULTS"

case "$OVERLAP" in
  on)   run_mode on ;;
  off)  run_mode off ;;
  both) run_mode on; run_mode off ;;
  *) echo "OVERLAP must be on|off|both" >&2; exit 2 ;;
esac

echo
echo "Appended results to: $RESULTS"
echo "Rendered manifests + per-arm logs in: $RUNDIR"
echo
echo "Interpretation reminder:"
echo "  - overlap=on  is the realistic deployment delta (small; A2A mostly hidden behind compute)."
echo "  - overlap=off isolates the dispatcher (upper bound; A2A fully exposed)."
echo "  - The honest end-to-end number is overlap=on. Report both; NEVER present"
echo "    overlap=off as the deployment speedup."
echo
echo "Template placeholder contract (the consumed template exposes EXACTLY this bare"
echo "\${VAR} set, all EXPORTed before \`envsubst < template\`; the operator-injected"
echo "torchrun rendezvous env is read by the in-image entrypoint, not the manifest):"
echo "  ${SUBST_VARS}"
