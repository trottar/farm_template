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

RUN_ID="${1:-}"
JOB_USER="$(resolve_job_user)"
JOB_WORK_DIR_RAW="${SWIF_JOB_WORK_DIR:-${SWIF_JOB_STAGE_DIR:-${SLURM_JOB_ID:+/scratch/${JOB_USER}/slurm/${SLURM_JOB_ID}}}}"
JOB_WORK_DIR="$(normalize_job_work_dir "${JOB_WORK_DIR_RAW}" "${JOB_USER}")"
if [[ -z "${JOB_WORK_DIR}" ]]; then
    JOB_WORK_DIR="$(pwd)"
fi
require_absolute_path "${JOB_WORK_DIR}" "JOB_WORK_DIR"
ensure_job_work_dir "${JOB_WORK_DIR}" "${JOB_USER}"

if [[ -z "${RUN_ID}" ]]; then
    echo "Usage: $0 RUN_ID" >&2
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
# TODO: replace this section with your real analysis setup.
# Typical pattern:
#   1. source your environment
#   2. run the analysis for ${RUN_ID}
#   3. define the final output/report files below
#

echo "TODO: customize worker_single_run_template.sh before real use"
echo "      RUN_ID=${RUN_ID}"

PRIMARY_OUTPUT_SOURCE="${PRIMARY_OUTPUT_SOURCE:-}"
PRIMARY_REPORT_SOURCE="${PRIMARY_REPORT_SOURCE:-}"
REPORT_TARBALL_SOURCE_DIR="${REPORT_TARBALL_SOURCE_DIR:-}"
REPORT_TARBALL_GLOB="${REPORT_TARBALL_GLOB:-}"
REPORT_TARBALL_BASENAME="${SWIF_REPORT_TARBALL_BASENAME:-reports_run_${RUN_ID}.tar}"

if [[ -z "${PRIMARY_OUTPUT_SOURCE}" ]]; then
    echo "ERROR: set PRIMARY_OUTPUT_SOURCE inside the template before use" >&2
    exit 1
fi

require_absolute_path "${PRIMARY_OUTPUT_SOURCE}" "PRIMARY_OUTPUT_SOURCE"
require_file "${PRIMARY_OUTPUT_SOURCE}"
stage_swif_copy "${PRIMARY_OUTPUT_SOURCE}"

if [[ -n "${PRIMARY_REPORT_SOURCE}" ]]; then
    require_absolute_path "${PRIMARY_REPORT_SOURCE}" "PRIMARY_REPORT_SOURCE"
    require_file "${PRIMARY_REPORT_SOURCE}"
    stage_swif_copy "${PRIMARY_REPORT_SOURCE}"
fi

if [[ -n "${REPORT_TARBALL_SOURCE_DIR}" && -n "${REPORT_TARBALL_GLOB}" ]]; then
    require_absolute_path "${REPORT_TARBALL_SOURCE_DIR}" "REPORT_TARBALL_SOURCE_DIR"
    shopt -s nullglob
    report_members=( "${REPORT_TARBALL_SOURCE_DIR}"/${REPORT_TARBALL_GLOB} )
    shopt -u nullglob
    if [[ ${#report_members[@]} -gt 0 ]]; then
        member_names=()
        for member in "${report_members[@]}"; do
            [[ -f "${member}" ]] || continue
            member_names+=( "$(basename "${member}")" )
        done
        if [[ ${#member_names[@]} -gt 0 ]]; then
            tar -cf "${JOB_WORK_DIR}/${REPORT_TARBALL_BASENAME}" -C "${REPORT_TARBALL_SOURCE_DIR}" "${member_names[@]}"
            echo "Staged SWIF report tarball at ${JOB_WORK_DIR}/${REPORT_TARBALL_BASENAME}"
        fi
    fi
fi
