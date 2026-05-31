#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Tier-A: model-free communication microbenchmark for the DeepEP-vs-NCCL A/B.
#
# Two measurements, both runnable on the CURRENTLY-ACTIVE 8-node B300 block
# (cb-142bf8f5 / cr-02dc459aadea76871) — the 32-node block (cb-4ff6b84d) is not
# bookable until 2026-05-31T11:30Z, and Tier-A does not need all 32 nodes. EP=32
# = 4 nodes = the target EP degree:
#
#   (A) WITH-DeepEP path  : UCCL ep/bench/test_internode.py (NORMAL/training
#       kernels) -> dispatch+combine bandwidth (GB/s, RDMA over EFA) and latency
#       (us) at the Kimi-K2 MoE shape. This is the EFA-native drop-in that
#       Megatron loads as the `deep_ep` module on AWS.
#   (B) WITHOUT-DeepEP path (indicative baseline): nccl-tests alltoall_perf swept
#       ~4 KB .. 1 GB -> busbw (GB/s). This is the collective the Megatron
#       `alltoall` token dispatcher rides over EFA via aws-ofi-nccl.
#
# IMPORTANT — this is an INDICATIVE comparison, not apples-to-apples:
#   - alltoall_perf is a uniform fixed-size all-to-all; UCCL test_internode.py is
#     the MoE token-routing dispatch/combine pattern (variable per-rank, FP8
#     dispatch + BF16 combine, permute/unpermute). The two stress the fabric
#     differently. Read the result as "order-of-magnitude EFA headroom for the
#     token-dispatch pattern", NOT as a clean dispatcher delta. The clean
#     dispatcher delta is Tier-B (1.run-ab-dispatcher.sh).
#   - We use the NORMAL kernels (test_internode.py). We do NOT use
#     test_low_latency.py: that is the inference/decode path (128 tokens), not
#     training. We also OMIT --test-ll-compatibility (see launcher note below):
#     it injects a SEPARATE low-latency phase at LL shapes (16 tokens / hidden
#     5120) and we want pure NORMAL-kernel numbers at the 4096-token MoE shape.
#
# Reference EFA numbers to expect (UCCL's OWN measurements, NOT B300 — there is
# NO published B300 number; treat UCCL B200 as the proxy):
#   - UCCL B200 + EFAv4 8x400G, EP32 normal kernels: dispatch ~53 GB/s (2072 us),
#     combine ~57 GB/s (3724 us).
#     (github.com/uccl-project/uccl/blob/0dc87eb3/ep/README.md, Tier-1)
#   - UCCL H200 + EFAv3 16x200G, EP32: dispatch 54 GB/s / combine 43 GB/s.
#   Target is B300 + 16x400G EFAv4 (6.4 Tbps/node, 2x the per-GPU BW of those
#   testbeds) — ~50-57 GB/s per GPU is near single-400G-NIC line rate; the second
#   NIC/GPU on p6-b300 is unmodelled by any published number.
#
# DeepEP's own README tables (153/158 GB/s NVLink, ~59 GB/s EP32 internode) are
# H800 + ConnectX-7 INFINIBAND, NOT EFA. Stock DeepEP cannot run on EFA at all
# (NVSHMEM/IBGDA-bound). Never cite those as an EFA expectation.
#
# CONFOUNDER GUARD: every rank must log "NET/OFI Selected Provider is efa"
# (an aws-ofi-nccl INFO line). If it is absent the run fell back to TCP/sockets
# and is DISCARDED. That is why the UCCL arm runs NCCL_DEBUG=INFO (the nccl-tests
# arm already does) — at WARN level the provider line never prints.
set -euo pipefail

# ----------------------------------------------------------------------------
# Config (override via env). Tier-A targets the ACTIVE 8-node block.
# ----------------------------------------------------------------------------
CTX="${CTX:-shared-usw2}"
NAMESPACE="${NAMESPACE:-kimi-k2-bench}"
# Active 8-node block today (2026-05-30). Switch to 4ff6b84d after 2026-05-31.
CB_SHORT="${CB_SHORT:-142bf8f5}"
# EP=32 needs 4 nodes (32 ranks / 8 GPU). The 8-node block covers EP up to 64.
NNODES="${NNODES:-4}"
GPUS_PER_NODE="${GPUS_PER_NODE:-8}"
EP_SIZE="${EP_SIZE:-32}"           # 32 ranks = 4 nodes = target EP degree
EFA_PER_NODE="${EFA_PER_NODE:-16}" # p6-b300.48xlarge advertises vpc.amazonaws.com/efa: 16

# Test-case image (UCCL EFA drop-in baked in). NO "latest" tags.
IMAGE="${IMAGE:-159553542841.dkr.ecr.us-west-2.amazonaws.com/megatron-bridge-uccl:nemo-25.11.01-uccl-0dc87eb}"
# nccl-tests image already published and used by workloads/nccl-tests/nccl-tests-cb-b300.yaml.
NCCL_TESTS_IMAGE="${NCCL_TESTS_IMAGE:-159553542841.dkr.ecr.us-west-2.amazonaws.com/nccl-tests:cuda12.8.1-efa1.42.0-ofiv1.16.0-ncclv2.27.5-1-testsv2.16.4}"

# MoE shape — Kimi-K2 / DeepSeek-V3-class (hidden 7168, top-8 routed).
# NOTE: Kimi-K2 has 384 routed experts (README default is 256). 384/EP32 = 12
# experts/rank. hidden + topk match DSV3; expert count does NOT — set it
# explicitly so the microbench reflects the target routing fan-out.
NUM_TOKENS="${NUM_TOKENS:-4096}"   # training/normal-kernel batch (per DSV3 pretrain)
HIDDEN="${HIDDEN:-7168}"
NUM_TOPK="${NUM_TOPK:-8}"
NUM_EXPERTS="${NUM_EXPERTS:-384}"  # Kimi-K2 routed expert count

# nccl-tests alltoall_perf sweep. ~4 KB ≈ per-token granularity floor (7 KB FP8
# token bracket); 1 GB = bulk-packed per-rank buffer ceiling (Megatron's alltoall
# packs tokens into contiguous per-rank buffers before the collective).
NCCL_MINBYTES="${NCCL_MINBYTES:-4K}"
NCCL_MAXBYTES="${NCCL_MAXBYTES:-1G}"
NCCL_STEPFACTOR="${NCCL_STEPFACTOR:-2}"
NCCL_ITERS="${NCCL_ITERS:-50}"

# Outputs: parsed side-by-side -> /fsx/kimi-k2/bench/tier-a-<ts>.txt (canonical
# bench dir per the spec). Raw per-arm logs land beside it under a timestamp dir.
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="${OUTDIR:-/fsx/kimi-k2/bench}"
RUNDIR="${RUNDIR:-${OUTDIR}/tier-a-${TS}}"
SUMMARY="${SUMMARY:-${OUTDIR}/tier-a-${TS}.txt}"
mkdir -p "$RUNDIR" 2>/dev/null || true
mkdir -p "$OUTDIR" 2>/dev/null || true

UCCL_JOB="megatron-bridge-uccl-epbench-${TS}"
NCCL_JOB="kimi-k2-nccl-a2a-${TS}"
UCCL_LOG="${RUNDIR}/uccl-ep-internode.log"
NCCL_LOG="${RUNDIR}/nccl-alltoall.log"
NP=$(( NNODES * GPUS_PER_NODE ))

# Path to the UCCL EP bench inside the image.
# TODO(validate against image): confirm the bench path. Assumed
#   /opt/uccl/ep/bench/test_internode.py per
#   github.com/uccl-project/uccl/blob/0dc87eb3/ep/README.md . Confirm with:
#     kubectl --context "$CTX" -n "$NAMESPACE" exec <pod> -- \
#       sh -lc 'ls -l /opt/uccl/ep/bench/test_internode.py || python -c "import uccl"'
UCCL_BENCH_PATH="${UCCL_BENCH_PATH:-/opt/uccl/ep/bench/test_internode.py}"  # TODO(validate against image)

echo "== Tier-A comm microbench =="
echo "   ctx=$CTX ns=$NAMESPACE cb=$CB_SHORT nodes=$NNODES ep=$EP_SIZE np=$NP"
echo "   moe shape: tokens=$NUM_TOKENS hidden=$HIDDEN topk=$NUM_TOPK experts=$NUM_EXPERTS"
echo "   uccl arm : PyTorchJob + torchrun  ($UCCL_BENCH_PATH, NORMAL kernels)"
echo "   nccl arm : MPIJob + mpirun        (alltoall_perf $NCCL_MINBYTES..$NCCL_MAXBYTES)"
echo "   raw logs : $RUNDIR"
echo "   summary  : $SUMMARY"
echo

# ----------------------------------------------------------------------------
# Scheduling block for the CB MNG (matches modules/cb-node-group and
# workloads/nccl-tests/nccl-tests-cb-b300.yaml): taints/labels
# nvidia.com/gpu=true, workload=bench, capacity-reservation=<short>.
# Rendered into the worker pod specs via heredoc indentation. IFS= keeps the
# leading indentation of the FIRST line (bare `read` strips it, breaking YAML).
# ----------------------------------------------------------------------------
IFS= read -r -d '' POD_SCHED <<YAML || true
          nodeSelector:
            capacity-reservation: "${CB_SHORT}"
            workload: bench
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
            - key: workload
              operator: Equal
              value: bench
              effect: NoSchedule
            - key: capacity-reservation
              operator: Equal
              value: "${CB_SHORT}"
              effect: NoSchedule
YAML

# ----------------------------------------------------------------------------
# (A) UCCL ep/bench dispatch+combine over EFA (WITH-DeepEP path).
#
# test_internode.py is a TORCHRUN program: it reads WORLD_SIZE, LOCAL_WORLD_SIZE,
# LOCAL_RANK, RANK, MASTER_ADDR, MASTER_PORT from the environment and calls
# dist.init_process_group via torchrun rendezvous (it does NOT spawn its own
# ranks — --num-processes is only validated). So it must be launched under
# torchrun, NOT bare mpirun -np. We use a kubeflow PyTorchJob, which injects the
# rendezvous env the operator computes (WORLD_SIZE = replicas, MASTER_ADDR/PORT,
# RANK = node rank), and run `torchrun` in each pod.
#   Verified launch form (github.com/uccl-project/uccl/blob/0dc87eb3/ep/README.md):
#     torchrun --nnodes=4 --nproc_per_node=8 --node_rank=<r> \
#       --master_addr=<ip> --master_port=12355 \
#       bench/test_internode.py --num-tokens=4096 --hidden=7168 \
#       --num-topk=8 --num-experts=288 [--test-ll-compatibility]
#   We OMIT --test-ll-compatibility (README shows it) on purpose: per the
#   argparse it sets ll_num_tokens=16/ll_hidden=5120 and runs an EXTRA
#   low-latency compatibility phase — a confounder for a clean NORMAL-kernel
#   measurement. Omitting leaves the 4096-token normal numbers intact.
#   # TODO(validate against image): some UCCL builds may *require*
#   --test-ll-compatibility to exercise the normal+LL path; if the script errors
#   without it, re-add and parse only the [tuning] Best dispatch/combine lines.
#   source: github.com/uccl-project/uccl/blob/0dc87eb3/ep/bench/test_internode.py
#
# It prints, per dispatch and per combine (verified against the source):
#   '[tuning] SMs ..., transmit: X us, notify: X us, BW: X GB/s (RDMA), Y GB/s (NVL)'
#   '[tuning] Best dispatch (FP8/BF16): ... transmit: X us, ... BW: X GB/s (RDMA), ...'
#   '[tuning] Best combine: ... transmit: X us, ... BW: X GB/s (RDMA), ...'
#
# TODO(validate against image): the operator-injected env var names below
# (RANK as node_rank, MASTER_ADDR, MASTER_PORT) are the training-operator v1
# convention; confirm they match the operator version on this cluster. If RANK
# is a GLOBAL process rank rather than a node rank, drop --node_rank and let
# torchrun derive it from the rendezvous (--rdzv-* + MASTER_ADDR).
#   source: kubeflow.org/docs/components/trainer/legacy-v1/user-guides/pytorch/
# ----------------------------------------------------------------------------
echo "== (A) UCCL ep/bench dispatch+combine over EFA (normal/training kernels) =="
# Single-line torchrun command. \${RANK}/\${MASTER_ADDR}/\${MASTER_PORT} stay as
# RUNTIME shell vars (operator-injected); the rest interpolate now. Built as one
# line on purpose: backslash-newline inside an unquoted heredoc is a line
# continuation that EATS the backslash, mangling a multi-line command.
TORCHRUN_CMD="torchrun --nnodes=${NNODES} --nproc_per_node=${GPUS_PER_NODE} --node_rank=\${RANK} --master_addr=\${MASTER_ADDR} --master_port=\${MASTER_PORT} ${UCCL_BENCH_PATH} --num-tokens=${NUM_TOKENS} --hidden=${HIDDEN} --num-topk=${NUM_TOPK} --num-experts=${NUM_EXPERTS}"
cat <<YAML | kubectl --context "$CTX" apply -f -
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: ${UCCL_JOB}
  namespace: ${NAMESPACE}
spec:
  runPolicy:
    cleanPodPolicy: Running
  nprocPerNode: "${GPUS_PER_NODE}"
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
${POD_SCHED}
          containers:
            - name: pytorch
              image: ${IMAGE}
              imagePullPolicy: IfNotPresent
              command: ["bash", "-lc", "${TORCHRUN_CMD}"]
              env:
                - name: FI_PROVIDER
                  value: efa
                - name: FI_EFA_FORK_SAFE
                  value: "1"
                - name: NCCL_DEBUG          # INFO so the EFA provider line prints
                  value: INFO
              resources:
                limits:
                  nvidia.com/gpu: ${GPUS_PER_NODE}
                  vpc.amazonaws.com/efa: ${EFA_PER_NODE}
                requests:
                  nvidia.com/gpu: ${GPUS_PER_NODE}
                  vpc.amazonaws.com/efa: ${EFA_PER_NODE}
              volumeMounts:
                - name: shmem
                  mountPath: /dev/shm
          volumes:
            - name: shmem
              hostPath:
                path: /dev/shm
    Worker:
      replicas: $(( NNODES - 1 ))
      restartPolicy: OnFailure
      template:
        spec:
${POD_SCHED}
          containers:
            - name: pytorch
              image: ${IMAGE}
              imagePullPolicy: IfNotPresent
              command: ["bash", "-lc", "${TORCHRUN_CMD}"]
              env:
                - name: FI_PROVIDER
                  value: efa
                - name: FI_EFA_FORK_SAFE
                  value: "1"
                - name: NCCL_DEBUG
                  value: INFO
              resources:
                limits:
                  nvidia.com/gpu: ${GPUS_PER_NODE}
                  vpc.amazonaws.com/efa: ${EFA_PER_NODE}
                requests:
                  nvidia.com/gpu: ${GPUS_PER_NODE}
                  vpc.amazonaws.com/efa: ${EFA_PER_NODE}
              volumeMounts:
                - name: shmem
                  mountPath: /dev/shm
          volumes:
            - name: shmem
              hostPath:
                path: /dev/shm
YAML

echo "   waiting for UCCL master pod Ready..."
kubectl --context "$CTX" -n "$NAMESPACE" wait --for=condition=Ready pod \
  -l "training.kubeflow.org/job-name=${UCCL_JOB},training.kubeflow.org/replica-type=master" \
  --timeout=900s || true

# Stream the master rank-0 log (where the [tuning] Best lines print).
kubectl --context "$CTX" -n "$NAMESPACE" logs -f \
  -l "training.kubeflow.org/job-name=${UCCL_JOB},training.kubeflow.org/replica-type=master" \
  --tail=-1 | tee "$UCCL_LOG" || true

# ----------------------------------------------------------------------------
# (B) nccl-tests alltoall_perf over EFA (WITHOUT-DeepEP baseline, indicative).
#
# Launched as an MPIJob/mpirun (it is an mpirun collective, not a torchrun
# program). The launcher env + LD_LIBRARY_PATH/PATH block mirror
# workloads/nccl-tests/nccl-tests-cb-b300.yaml exactly.
#
# alltoall_perf flags (verified github.com/NVIDIA/nccl-tests README):
#   -b minbytes  -e maxbytes  -f stepfactor  -g gpus/thread  -c check  -n iters
# ----------------------------------------------------------------------------
echo "== (B) nccl-tests alltoall_perf over EFA (indicative baseline) =="
cat <<YAML | kubectl --context "$CTX" apply -f -
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: ${NCCL_JOB}
  namespace: ${NAMESPACE}
spec:
  runPolicy:
    cleanPodPolicy: Running
    backoffLimit: 6
  slotsPerWorker: ${GPUS_PER_NODE}
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: launcher
              image: ${NCCL_TESTS_IMAGE}
              imagePullPolicy: IfNotPresent
              env:
                - name: PATH
                  value: \$PATH:/opt/amazon/efa/bin:/usr/bin
                - name: LD_LIBRARY_PATH
                  value: /opt/amazon/openmpi/lib:/opt/nccl/build/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib/x86_64-linux-gnu:/usr/local/nvidia/lib:\$LD_LIBRARY_PATH
              command:
                - /opt/amazon/openmpi/bin/mpirun
                - --allow-run-as-root
                - --tag-output
                - -np
                - "${NP}"
                - -N
                - "${GPUS_PER_NODE}"
                - --bind-to
                - none
                - -x
                - PATH
                - -x
                - LD_LIBRARY_PATH
                - -x
                - FI_PROVIDER=efa
                - -x
                - FI_EFA_FORK_SAFE=1
                - -x
                - NCCL_DEBUG=INFO
                - /opt/nccl-tests/build/alltoall_perf
                - -b
                - "${NCCL_MINBYTES}"
                - -e
                - "${NCCL_MAXBYTES}"
                - -f
                - "${NCCL_STEPFACTOR}"
                - -g
                - "1"
                - -c
                - "1"
                - -n
                - "${NCCL_ITERS}"
    Worker:
      replicas: ${NNODES}
      template:
        spec:
${POD_SCHED}
          containers:
            - name: worker
              image: ${NCCL_TESTS_IMAGE}
              imagePullPolicy: IfNotPresent
              resources:
                limits:
                  nvidia.com/gpu: ${GPUS_PER_NODE}
                  vpc.amazonaws.com/efa: ${EFA_PER_NODE}
                requests:
                  nvidia.com/gpu: ${GPUS_PER_NODE}
                  vpc.amazonaws.com/efa: ${EFA_PER_NODE}
              volumeMounts:
                - name: shmem
                  mountPath: /dev/shm
          volumes:
            - name: shmem
              hostPath:
                path: /dev/shm
YAML

echo "   waiting for nccl-tests launcher Ready..."
kubectl --context "$CTX" -n "$NAMESPACE" wait --for=condition=Ready pod \
  -l "training.kubeflow.org/job-name=${NCCL_JOB},training.kubeflow.org/job-role=launcher" \
  --timeout=900s || true

kubectl --context "$CTX" -n "$NAMESPACE" logs -f \
  -l "training.kubeflow.org/job-name=${NCCL_JOB},training.kubeflow.org/job-role=launcher" \
  --tail=-1 | tee "$NCCL_LOG" || true

# ----------------------------------------------------------------------------
# CONFOUNDER GUARD — assert EFA provider on BOTH arms, else DISCARD the run.
# "NET/OFI Selected Provider is efa" is an aws-ofi-nccl INFO line; both arms run
# NCCL_DEBUG=INFO so it prints when the process group inits through aws-ofi-nccl.
# TODO(validate against image): this confirms the PROCESS-GROUP init chose EFA,
# not that UCCL's native EP transport did. If UCCL emits its own EFA-confirmation
# string for the EP datapath, assert that too — its exact text is unverified.
#   source: github.com/aws/aws-ofi-nccl (provider-selection log line)
# ----------------------------------------------------------------------------
EFA_RE="NET/OFI Selected Provider is efa"
uccl_efa=$(grep -cE "$EFA_RE" "$UCCL_LOG" 2>/dev/null || true)
nccl_efa=$(grep -cE "$EFA_RE" "$NCCL_LOG" 2>/dev/null || true)
echo
echo "EFA provider assertion ('$EFA_RE'):"
echo "   UCCL arm matches: ${uccl_efa:-0}   nccl-tests arm matches: ${nccl_efa:-0}"
if [ "${uccl_efa:-0}" -eq 0 ] || [ "${nccl_efa:-0}" -eq 0 ]; then
  echo "!! EFA provider NOT confirmed on one or both arms — run fell back to"  >&2
  echo "!! TCP/sockets. DISCARDING this Tier-A run. Inspect:"                   >&2
  echo "!!   $UCCL_LOG"                                                          >&2
  echo "!!   $NCCL_LOG"                                                          >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Parse + write the indicative side-by-side to /fsx/kimi-k2/bench/tier-a-<ts>.txt
# UCCL  : anchor on the verified '[tuning] Best dispatch' / '[tuning] Best combine'.
# nccl  : grep the per-size table rows + the '# Avg bus bandwidth' summary line.
# TODO(validate against image): nccl-tests column layout (which field is busbw)
# could not be confirmed from doc/PERFORMANCE.md; the awk below prints the last
# two numeric columns as algbw/busbw per the conventional perf-test table. Verify
# against actual output and adjust the field index if needed.
#   source: github.com/NVIDIA/nccl-tests/blob/master/doc/PERFORMANCE.md
# ----------------------------------------------------------------------------
{
  echo "================ Tier-A comm microbench (indicative) ================"
  echo "timestamp (UTC) : ${TS}"
  echo "block           : cb-${CB_SHORT}  nodes=${NNODES}  ep=${EP_SIZE}  np=${NP}"
  echo "moe shape       : tokens=${NUM_TOKENS} hidden=${HIDDEN} topk=${NUM_TOPK} experts=${NUM_EXPERTS}"
  echo "image (uccl)    : ${IMAGE}"
  echo "image (nccl)    : ${NCCL_TESTS_IMAGE}"
  echo
  echo "EFA provider confirmed on both arms (NET/OFI Selected Provider is efa):"
  grep -hE "$EFA_RE" "$UCCL_LOG" "$NCCL_LOG" 2>/dev/null | sort -u | sed 's/^/  /' || true
  echo
  echo "--- WITH-DeepEP (UCCL ep/bench, EP=${EP_SIZE}, NORMAL kernels) ---"
  echo "    dispatch+combine: transmit/notify (us) and BW GB/s (RDMA over EFA, NVL):"
  grep -hE "\[tuning\] Best (dispatch|combine)" "$UCCL_LOG" 2>/dev/null | sed 's/^/    /' \
    || echo "    (no [tuning] Best lines parsed — inspect ${UCCL_LOG})"
  echo
  echo "--- WITHOUT-DeepEP (nccl-tests alltoall_perf, ${NP} ranks, indicative) ---"
  echo "    size(B)            busbw(GB/s)  [bulk-packed all-to-all over EFA]:"
  # Table rows look like: "  <size> <count> <type> ... <time> <algbw> <busbw> <#wrong>"
  # The last numeric column after #wrong-or-N/A is busbw; print size (col 1) and
  # the conventional busbw column. TODO(validate): confirm $(NF-1) is busbw.
  awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {printf "    %-18s %s\n", $1, $(NF-1)}' \
    "$NCCL_LOG" 2>/dev/null || true
  grep -hE "# Avg bus bandwidth" "$NCCL_LOG" 2>/dev/null | sed 's/^/    /' \
    || echo "    (no '# Avg bus bandwidth' summary — inspect ${NCCL_LOG})"
  echo
  echo "Raw logs:"
  echo "  WITH-DeepEP : ${UCCL_LOG}"
  echo "  baseline    : ${NCCL_LOG}"
  echo
  echo "Reference (UCCL B200+EFAv4 EP32, NOT B300): dispatch ~53 GB/s / combine ~57 GB/s."
  echo "INDICATIVE only: UCCL is the MoE dispatch/combine pattern; alltoall_perf is"
  echo "uniform A2A. The clean dispatcher delta that matters for training is Tier-B"
  echo "(1.run-ab-dispatcher.sh) under IDENTICAL overlap config on both arms."
  echo "===================================================================="
} | tee "$SUMMARY"

echo
echo "Wrote parsed side-by-side -> ${SUMMARY}"
echo "Raw per-arm logs in        -> ${RUNDIR}"
