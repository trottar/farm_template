#! /bin/bash

set -euo pipefail

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

prepare_local_output_dirs() {
    local repo_root="$1"
    local entry
    for entry in runout worksim outfiles; do
        if [[ -L "${repo_root}/${entry}" || ! -d "${repo_root}/${entry}" ]]; then
            rm -rf "${repo_root:?}/${entry}"
            mkdir -p "${repo_root}/${entry}"
        fi
    done
}

resolve_root_output() {
    local repo_root="$1"
    local tag="$2"
    local exact_output="${repo_root}/outfiles/${tag}.root"
    local sf_output="${repo_root}/outfiles/${tag}3HeFit.root"
    local candidates=()

    if [[ -f "${exact_output}" ]]; then
        printf '%s\n' "${exact_output}"
        return 0
    fi
    if [[ -f "${sf_output}" ]]; then
        printf '%s\n' "${sf_output}"
        return 0
    fi

    shopt -s nullglob
    candidates=( "${repo_root}/outfiles/${tag}"*.root )
    shopt -u nullglob

    if [[ ${#candidates[@]} -eq 1 ]]; then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi
    return 1
}

KIN_NAME="${1:-}"
BIN_INDEX="${2:-}"
JOB_WORK_DIR="${SWIF_JOB_WORK_DIR:-${SWIF_JOB_STAGE_DIR:-${SLURM_JOB_ID:+/scratch/slurm/${SLURM_JOB_ID}}}}"
if [[ -z "${JOB_WORK_DIR}" ]]; then
    JOB_WORK_DIR="$(pwd)"
fi

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
    prepare_local_output_dirs "${WORK_REPO}"
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
expected_output_sf="${WORK_REPO}/outfiles/${run_tag}3HeFit.root"
require_absolute_path "${expected_output_sf}" "expected_output_sf"

rm -f "${expected_output}"
rm -f "${expected_output_sf}"

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

actual_output="$(resolve_root_output "${WORK_REPO}" "${run_tag}" || true)"

if [[ -z "${actual_output}" ]]; then
    echo "ERROR: expected output file not found: ${expected_output}" >&2
    if [[ -d "${WORK_REPO}/outfiles" ]]; then
        echo "Available outfiles entries:" >&2
        find "${WORK_REPO}/outfiles" -maxdepth 1 -type f -name "${KIN_NAME}_bin*" -printf '  %f\n' >&2 || true
    fi
    if [[ -d "${WORK_REPO}/worksim" ]]; then
        echo "Available worksim entries:" >&2
        find "${WORK_REPO}/worksim" -maxdepth 1 -type f -name "${KIN_NAME}_bin*" -printf '  %f\n' >&2 || true
    fi
    if [[ -f "${WORK_REPO}/runout/${run_tag}.out" ]]; then
        echo "Tail of run log ${WORK_REPO}/runout/${run_tag}.out:" >&2
        tail -n 40 "${WORK_REPO}/runout/${run_tag}.out" >&2 || true
    fi
    exit 4
fi
if [[ ! -s "${actual_output}" ]]; then
    echo "ERROR: expected output file is empty (possible Fortran/runtime failure): ${actual_output}" >&2
    exit 4
fi

if [[ -n "${SWIF_PRIMARY_OUTPUT_BASENAME:-}" ]]; then
    staged_name="${SWIF_PRIMARY_OUTPUT_BASENAME}"
elif [[ "${actual_output}" == *3HeFit.root ]]; then
    staged_name="${KIN_NAME}_bin${BIN_INDEX}3HeFit.root"
else
    staged_name="${KIN_NAME}_bin${BIN_INDEX}.root"
fi
staged_file="${JOB_WORK_DIR}/${staged_name}"
cp -f "${actual_output}" "${staged_file}"

echo "Resolved ROOT output at ${actual_output}"
echo "Staged SWIF output copy at ${staged_file}"
