#! /bin/bash

set -euo pipefail

ensure_job_work_dir() {
    local path="$1"
    local job_user="$2"
    local parent_dir
    local scratch_user_root="/scratch/${job_user}"
    local scratch_slurm_root="${scratch_user_root}/slurm"
    parent_dir="$(dirname "${path}")"

    if [[ -d "${path}" ]]; then
        return
    fi

    if [[ "${path}" == "${scratch_slurm_root}" || "${path}" == "${scratch_slurm_root}/"* ]]; then
        if [[ ! -d "${scratch_user_root}" ]]; then
            echo "ERROR: JOB_WORK_DIR base does not exist on the batch node: ${scratch_user_root}" >&2
            exit 1
        fi
        if [[ ! -w "${scratch_user_root}" ]]; then
            echo "ERROR: JOB_WORK_DIR base is not writable on the batch node: ${scratch_user_root}" >&2
            exit 1
        fi
        mkdir -p "${path}"
        return
    fi

    if [[ ! -d "${parent_dir}" ]]; then
        echo "ERROR: JOB_WORK_DIR parent does not exist on the batch node: ${parent_dir}" >&2
        exit 1
    fi
    if [[ ! -w "${parent_dir}" ]]; then
        echo "ERROR: JOB_WORK_DIR parent is not writable on the batch node: ${parent_dir}" >&2
        exit 1
    fi
    mkdir -p "${path}"
}

require_absolute_path() {
    local path="$1"
    local label="$2"
    if [[ "${path}" != /* ]]; then
        echo "ERROR: ${label} must be an absolute path: ${path}" >&2
        exit 1
    fi
}

resolve_job_user() {
    if [[ -n "${USER:-}" ]]; then
        printf '%s\n' "${USER}"
        return
    fi
    id -un
}

normalize_job_work_dir() {
    local path="$1"
    local job_user="$2"

    if [[ "${path}" == /scratch/slurm/* ]]; then
        printf '/scratch/%s/slurm/%s\n' "${job_user}" "${path#/scratch/slurm/}"
        return
    fi
    printf '%s\n' "${path}"
}

VARIANT_NAME="${1:-}"
RUN_ID="${2:-}"
JOB_USER="$(resolve_job_user)"
JOB_WORK_DIR_RAW="${SWIF_JOB_WORK_DIR:-${SWIF_JOB_STAGE_DIR:-${SLURM_JOB_ID:+/scratch/${JOB_USER}/slurm/${SLURM_JOB_ID}}}}"
JOB_WORK_DIR="$(normalize_job_work_dir "${JOB_WORK_DIR_RAW}" "${JOB_USER}")"
if [[ -z "${JOB_WORK_DIR}" ]]; then
    JOB_WORK_DIR="$(pwd)"
fi
require_absolute_path "${JOB_WORK_DIR}" "JOB_WORK_DIR"
ensure_job_work_dir "${JOB_WORK_DIR}" "${JOB_USER}"

if [[ -z "${VARIANT_NAME}" || -z "${RUN_ID}" ]]; then
    echo "Usage: $0 VARIANT_NAME RUN_ID" >&2
    exit 1
fi

require_file() {
    local path="$1"
    if [[ ! -f "${path}" ]]; then
        echo "ERROR: expected file not found: ${path}" >&2
        exit 1
    fi
}

stage_swif_copy() {
    local source_file="$1"
    local staged_file="${JOB_WORK_DIR}/$(basename "${source_file}")"
    cp -f "${source_file}" "${staged_file}"
    echo "Staged SWIF output copy at ${staged_file}"
}

#
# TODO: replace this section with your real variant-aware batch command.
# Typical pattern:
#   ./my_worker.sh "${VARIANT_NAME}" "${RUN_ID}"
# and then stage the final outputs below.
#

echo "TODO: customize worker_variant_run_template.sh before real use"
echo "      VARIANT_NAME=${VARIANT_NAME}"
echo "      RUN_ID=${RUN_ID}"

PRIMARY_OUTPUT_SOURCE="${PRIMARY_OUTPUT_SOURCE:-}"
SECONDARY_OUTPUT_SOURCE="${SECONDARY_OUTPUT_SOURCE:-}"

if [[ -z "${PRIMARY_OUTPUT_SOURCE}" ]]; then
    echo "ERROR: set PRIMARY_OUTPUT_SOURCE inside the template before use" >&2
    exit 1
fi

require_absolute_path "${PRIMARY_OUTPUT_SOURCE}" "PRIMARY_OUTPUT_SOURCE"
require_file "${PRIMARY_OUTPUT_SOURCE}"
stage_swif_copy "${PRIMARY_OUTPUT_SOURCE}"

if [[ -n "${SECONDARY_OUTPUT_SOURCE}" ]]; then
    require_absolute_path "${SECONDARY_OUTPUT_SOURCE}" "SECONDARY_OUTPUT_SOURCE"
    require_file "${SECONDARY_OUTPUT_SOURCE}"
    stage_swif_copy "${SECONDARY_OUTPUT_SOURCE}"
fi
