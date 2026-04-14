#! /bin/bash

set -euo pipefail

normalize_job_path() {
    local path="${1:-}"
    if [[ -z "${path}" ]]; then
        printf '%s\n' ""
        return
    fi
    if [[ "${path}" == /scratch/slurm/* ]]; then
        if [[ -z "${USER:-}" ]]; then
            echo "ERROR: USER must be set to normalize scratch path: ${path}" >&2
            return 1
        fi
        printf '/scratch/%s/slurm/%s\n' "${USER}" "${path#/scratch/slurm/}"
        return
    fi
    printf '%s\n' "${path}"
}

ensure_job_work_dir() {
    local path="$1"
    local parent_dir
    parent_dir="$(dirname "${path}")"

    if [[ -d "${path}" ]]; then
        return
    fi
    if [[ ! -d "${parent_dir}" ]]; then
        echo "ERROR: JOB_WORK_DIR parent does not exist on the batch node: ${parent_dir}" >&2
        exit 3
    fi
    if [[ ! -w "${parent_dir}" ]]; then
        echo "ERROR: JOB_WORK_DIR parent is not writable on the batch node: ${parent_dir}" >&2
        exit 3
    fi
    mkdir "${path}"
}

require_absolute_path() {
    local path="$1"
    local label="$2"
    if [[ "${path}" != /* ]]; then
        echo "ERROR: ${label} must be an absolute path: ${path}" >&2
        exit 3
    fi
}

KIN_NAME="${1:-}"
BIN_INDEX="${2:-}"
JOB_WORK_DIR="$(normalize_job_path "${SWIF_JOB_WORK_DIR:-${SWIF_JOB_STAGE_DIR:-/scratch/${USER}/slurm/${SLURM_JOB_ID:-$$}}}")"

if [[ -z "${KIN_NAME}" || -z "${BIN_INDEX}" ]]; then
    echo "Usage: $0 KIN_NAME BIN_INDEX" >&2
    exit 1
fi

if ! [[ "${KIN_NAME}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: KIN_NAME contains unsupported characters: ${KIN_NAME}" >&2
    echo "       Allowed: letters, numbers, underscore, dot, dash" >&2
    exit 2
fi

if ! [[ "${BIN_INDEX}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: BIN_INDEX must be a non-negative integer." >&2
    exit 2
fi

MC_SINGLE_ARM_REPO="${MC_SINGLE_ARM_REPO:-}"
RUN_SCRIPT="${MC_SINGLE_ARM_RUN_SCRIPT:-run_mc_single_arm_tree_eprime_bin}"
TARGET_GOOD_EVENTS="${TARGET_GOOD_EVENTS:-1000000}"
CHUNK_TRIALS="${CHUNK_TRIALS:-2000000}"
MAX_CHUNKS="${MAX_CHUNKS:-500}"
BIN_PAD_WIDTH="${MC_SINGLE_ARM_BIN_PAD_WIDTH:-3}"
MC_SINGLE_ARM_USE_LOCAL_COPY="${MC_SINGLE_ARM_USE_LOCAL_COPY:-1}"
MC_SINGLE_ARM_BUILD_ROOT="${MC_SINGLE_ARM_BUILD_ROOT:-${JOB_WORK_DIR}/mc_single_arm_build}"
JOB_CACHE_DIR="${JOB_WORK_DIR}/.cache"
JOB_TMP_DIR="${JOB_WORK_DIR}/tmp"

if [[ -z "${MC_SINGLE_ARM_REPO}" ]]; then
    echo "ERROR: MC_SINGLE_ARM_REPO is required and must be an absolute path on batch nodes." >&2
    exit 3
fi
if [[ "${MC_SINGLE_ARM_REPO}" != /* ]]; then
    echo "ERROR: MC_SINGLE_ARM_REPO must be an absolute path: ${MC_SINGLE_ARM_REPO}" >&2
    exit 3
fi
require_absolute_path "${JOB_WORK_DIR}" "JOB_WORK_DIR"
require_absolute_path "${MC_SINGLE_ARM_BUILD_ROOT}" "MC_SINGLE_ARM_BUILD_ROOT"
ensure_job_work_dir "${JOB_WORK_DIR}"
if [[ ! -w "${JOB_WORK_DIR}" ]]; then
    echo "ERROR: JOB_WORK_DIR is not writable on the batch node: ${JOB_WORK_DIR}" >&2
    exit 3
fi

if [[ ! -d "${MC_SINGLE_ARM_REPO}" ]]; then
    echo "ERROR: MC_SINGLE_ARM_REPO does not exist: ${MC_SINGLE_ARM_REPO}" >&2
    exit 3
fi

mkdir -p "${JOB_CACHE_DIR}" "${JOB_TMP_DIR}"

WORK_REPO="${MC_SINGLE_ARM_REPO}"
if [[ "${MC_SINGLE_ARM_USE_LOCAL_COPY}" = "1" ]]; then
    WORK_REPO="${MC_SINGLE_ARM_BUILD_ROOT}"
    mkdir -p "${WORK_REPO}"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude='.git' "${MC_SINGLE_ARM_REPO}/" "${WORK_REPO}/"
    else
        rm -rf "${WORK_REPO}"
        mkdir -p "${WORK_REPO}"
        cp -a "${MC_SINGLE_ARM_REPO}/." "${WORK_REPO}/"
    fi
fi

if [[ "${RUN_SCRIPT}" = /* ]]; then
    SCRIPT_PATH="${RUN_SCRIPT}"
else
    SCRIPT_PATH="${WORK_REPO}/${RUN_SCRIPT}"
fi
require_absolute_path "${WORK_REPO}" "WORK_REPO"
require_absolute_path "${SCRIPT_PATH}" "SCRIPT_PATH"

if [[ ! -f "${SCRIPT_PATH}" ]]; then
    echo "ERROR: run script file not found: ${SCRIPT_PATH}" >&2
    exit 3
fi

if ! [[ "${TARGET_GOOD_EVENTS}" =~ ^[0-9]+$ && "${CHUNK_TRIALS}" =~ ^[0-9]+$ && "${MAX_CHUNKS}" =~ ^[0-9]+$ && "${BIN_PAD_WIDTH}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: TARGET_GOOD_EVENTS, CHUNK_TRIALS, MAX_CHUNKS, and MC_SINGLE_ARM_BIN_PAD_WIDTH must be integers." >&2
    exit 2
fi

run_tag="${KIN_NAME}_bin$(printf "%0${BIN_PAD_WIDTH}d" "${BIN_INDEX}")"
expected_output="${WORK_REPO}/outfiles/${run_tag}.root"
require_absolute_path "${expected_output}" "expected_output"

rm -f "${expected_output}"

pushd "${WORK_REPO}" >/dev/null
if [[ -x "${SCRIPT_PATH}" ]]; then
    XDG_CACHE_HOME="${JOB_CACHE_DIR}" \
    TMPDIR="${JOB_TMP_DIR}" \
    TMP="${JOB_TMP_DIR}" \
    TEMP="${JOB_TMP_DIR}" \
    TARGET_GOOD_EVENTS="${TARGET_GOOD_EVENTS}" \
    CHUNK_TRIALS="${CHUNK_TRIALS}" \
    MAX_CHUNKS="${MAX_CHUNKS}" \
    "${SCRIPT_PATH}" "${KIN_NAME}" "${BIN_INDEX}"
else
    XDG_CACHE_HOME="${JOB_CACHE_DIR}" \
    TMPDIR="${JOB_TMP_DIR}" \
    TMP="${JOB_TMP_DIR}" \
    TEMP="${JOB_TMP_DIR}" \
    TARGET_GOOD_EVENTS="${TARGET_GOOD_EVENTS}" \
    CHUNK_TRIALS="${CHUNK_TRIALS}" \
    MAX_CHUNKS="${MAX_CHUNKS}" \
    bash "${SCRIPT_PATH}" "${KIN_NAME}" "${BIN_INDEX}"
fi
popd >/dev/null

if [[ ! -f "${expected_output}" ]]; then
    echo "ERROR: expected output file not found: ${expected_output}" >&2
    exit 4
fi
if [[ ! -s "${expected_output}" ]]; then
    echo "ERROR: expected output file is empty (possible Fortran/runtime failure): ${expected_output}" >&2
    exit 4
fi

staged_name="${KIN_NAME}_bin${BIN_INDEX}.root"
staged_file="${JOB_WORK_DIR}/${staged_name}"
cp -f "${expected_output}" "${staged_file}"

echo "Staged SWIF output copy at ${staged_file}"
