#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
export AWS_PAGER=""

log() {
  printf '%s\n' "$*" >&2
}

require_env() {
  local name

  for name in AWS_REGION CLUSTER_ARN QUOTA_NAME COMPUTE_QUOTA_CONFIG COMPUTE_QUOTA_TARGET ACTIVATION_STATE DESCRIPTION; do
    if [[ -z "${!name+x}" ]]; then
      log "Missing required environment variable: ${name}"
      exit 1
    fi
  done

  for name in AWS_REGION CLUSTER_ARN QUOTA_NAME COMPUTE_QUOTA_CONFIG COMPUTE_QUOTA_TARGET ACTIVATION_STATE; do
    if [[ -z "${!name}" ]]; then
      log "Required environment variable cannot be empty: ${name}"
      exit 1
    fi
  done
}

aws_sm() {
  aws sagemaker --region "${AWS_REGION}" "$@"
}

json_field() {
  local field="$1"
  local json="$2"

  python3 -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "${field}" <<< "${json}"
}

find_quota() {
  aws_sm list-compute-quotas \
    --cluster-arn "${CLUSTER_ARN}" \
    --name-contains "${QUOTA_NAME}" \
    --output json |
    python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
name = os.environ["QUOTA_NAME"]
cluster_arn = os.environ["CLUSTER_ARN"]
matches = [
    quota for quota in data.get("ComputeQuotaSummaries", [])
    if quota.get("Name") == name
    and quota.get("ClusterArn") == cluster_arn
    and quota.get("Status") != "Deleted"
]

if len(matches) > 1:
    print(
        f"Found {len(matches)} compute quotas named {name!r} in cluster {cluster_arn!r}; expected at most one.",
        file=sys.stderr,
    )
    sys.exit(2)

if matches:
    print(json.dumps(matches[0], sort_keys=True, separators=(",", ":")))
'
}

describe_quota() {
  local quota_id="$1"

  aws_sm describe-compute-quota \
    --compute-quota-id "${quota_id}" \
    --output json
}

is_failure_status() {
  local status="$1"

  case "${status}" in
    CreateFailed | CreateRollbackFailed | UpdateFailed | UpdateRollbackFailed | DeleteFailed | DeleteRollbackFailed)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_create_failure_status() {
  local status="$1"

  case "${status}" in
    CreateFailed | CreateRollbackFailed)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

quota_matches_desired() {
  local current_json="$1"

  printf '%s' "${current_json}" |
    python3 -c '
import json
import os
import sys

def clean(value):
    if isinstance(value, dict):
        cleaned = {}
        for key, child in value.items():
            child = clean(child)
            if child is None or child == {} or child == []:
                continue
            cleaned[key] = child
        return cleaned
    if isinstance(value, list):
        cleaned = [
            clean(child) for child in value
        ]
        cleaned = [
            child for child in cleaned
            if child is not None and child != {} and child != []
        ]
        return sorted(cleaned, key=lambda child: json.dumps(child, sort_keys=True, separators=(",", ":")))
    return value

current = json.load(sys.stdin)
desired = {
    "Description": os.environ.get("DESCRIPTION", ""),
    "ComputeQuotaConfig": json.loads(os.environ["COMPUTE_QUOTA_CONFIG"]),
    "ComputeQuotaTarget": json.loads(os.environ["COMPUTE_QUOTA_TARGET"]),
    "ActivationState": os.environ["ACTIVATION_STATE"],
}
actual = {
    "Description": current.get("Description", ""),
    "ComputeQuotaConfig": current.get("ComputeQuotaConfig", {}),
    "ComputeQuotaTarget": current.get("ComputeQuotaTarget", {}),
    "ActivationState": current.get("ActivationState", ""),
}

sys.exit(0 if clean(actual) == clean(desired) else 1)
'
}

wait_for_stable_quota() {
  local quota_id="$1"
  local mode="${2:-ready}"
  local attempts="${COMPUTE_QUOTA_WAIT_ATTEMPTS:-60}"
  local sleep_seconds="${COMPUTE_QUOTA_WAIT_SECONDS:-10}"
  local current_json
  local status
  local failure_reason
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if ! current_json="$(describe_quota "${quota_id}" 2>/dev/null)"; then
      if [[ "${mode}" == "delete" ]]; then
        return 0
      fi
      log "Failed to describe compute quota ${quota_id}"
      exit 1
    fi

    status="$(json_field Status "${current_json}")"
    case "${status}" in
      Created | Updated)
        return 0
        ;;
      Deleted)
        if [[ "${mode}" == "delete" ]]; then
          return 0
        fi
        log "Compute quota ${quota_id} was deleted while waiting for it to become ready"
        exit 1
        ;;
      CreateFailed | CreateRollbackFailed | UpdateFailed | UpdateRollbackFailed | DeleteFailed | DeleteRollbackFailed)
        failure_reason="$(json_field FailureReason "${current_json}")"
        log "Compute quota ${quota_id} reached failed status ${status}: ${failure_reason}"
        exit 1
        ;;
    esac

    sleep "${sleep_seconds}"
  done

  log "Timed out waiting for compute quota ${quota_id} to reach a stable status"
  exit 1
}

create_quota() {
  local result_json
  local quota_id
  local -a create_args

  log "Creating SageMaker compute quota ${QUOTA_NAME}"
  create_args=(
    create-compute-quota
    --name "${QUOTA_NAME}"
    --cluster-arn "${CLUSTER_ARN}"
    --compute-quota-config "${COMPUTE_QUOTA_CONFIG}"
    --compute-quota-target "${COMPUTE_QUOTA_TARGET}"
    --activation-state "${ACTIVATION_STATE}"
    --output json
  )
  if [[ -n "${DESCRIPTION}" ]]; then
    create_args+=(--description "${DESCRIPTION}")
  fi

  result_json="$(aws_sm "${create_args[@]}")"
  quota_id="$(json_field ComputeQuotaId "${result_json}")"
  wait_for_stable_quota "${quota_id}" ready
}

apply_quota() {
  local quota_json
  local quota_id
  local current_json
  local status
  local target_version

  quota_json="$(find_quota)"

  if [[ -z "${quota_json}" ]]; then
    create_quota
    return
  fi

  quota_id="$(json_field ComputeQuotaId "${quota_json}")"
  current_json="$(describe_quota "${quota_id}")"
  status="$(json_field Status "${current_json}")"

  if is_create_failure_status "${status}"; then
    log "Deleting failed SageMaker compute quota ${QUOTA_NAME} before recreating it"
    aws_sm delete-compute-quota \
      --compute-quota-id "${quota_id}" \
      --output json >/dev/null
    wait_for_stable_quota "${quota_id}" delete
    create_quota
    return
  fi

  wait_for_stable_quota "${quota_id}" ready
  current_json="$(describe_quota "${quota_id}")"

  if quota_matches_desired "${current_json}"; then
    log "SageMaker compute quota ${QUOTA_NAME} is up to date"
    return
  fi

  target_version="$(json_field ComputeQuotaVersion "${current_json}")"
  log "Updating SageMaker compute quota ${QUOTA_NAME} at version ${target_version}"

  aws_sm update-compute-quota \
    --compute-quota-id "${quota_id}" \
    --target-version "${target_version}" \
    --compute-quota-config "${COMPUTE_QUOTA_CONFIG}" \
    --compute-quota-target "${COMPUTE_QUOTA_TARGET}" \
    --activation-state "${ACTIVATION_STATE}" \
    --description "${DESCRIPTION}" \
    --output json >/dev/null

  wait_for_stable_quota "${quota_id}" ready
}

delete_quota() {
  local quota_json
  local quota_id
  local current_json
  local status

  quota_json="$(find_quota)"

  if [[ -z "${quota_json}" ]]; then
    log "SageMaker compute quota ${QUOTA_NAME} is already absent"
    return
  fi

  quota_id="$(json_field ComputeQuotaId "${quota_json}")"
  if ! current_json="$(describe_quota "${quota_id}" 2>/dev/null)"; then
    log "SageMaker compute quota ${QUOTA_NAME} is already absent"
    return
  fi

  status="$(json_field Status "${current_json}")"
  if [[ "${status}" == "Deleted" ]]; then
    log "SageMaker compute quota ${QUOTA_NAME} is already deleted"
    return
  fi

  if ! is_failure_status "${status}"; then
    wait_for_stable_quota "${quota_id}" ready
    current_json="$(describe_quota "${quota_id}")"
  fi

  if ! quota_matches_desired "${current_json}"; then
    log "Skipping delete for ${QUOTA_NAME}; the live quota no longer matches this Terraform instance"
    return
  fi

  log "Deleting SageMaker compute quota ${QUOTA_NAME}"
  aws_sm delete-compute-quota \
    --compute-quota-id "${quota_id}" \
    --output json >/dev/null
  wait_for_stable_quota "${quota_id}" delete
}

if [[ "${ACTION}" != "apply" && "${ACTION}" != "delete" ]]; then
  log "Usage: $0 apply|delete"
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  log "The AWS CLI is required to manage SageMaker compute quotas"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "python3 is required to compare SageMaker compute quota JSON"
  exit 1
fi

require_env

case "${ACTION}" in
  apply)
    apply_quota
    ;;
  delete)
    delete_quota
    ;;
esac
