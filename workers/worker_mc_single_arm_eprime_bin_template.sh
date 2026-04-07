#! /bin/bash

set -euo pipefail

KIN_NAME="${1:-}"
BIN_INDEX="${2:-}"
JOB_WORK_DIR="${SWIF_JOB_WORK_DIR:-${SWIF_JOB_STAGE_DIR:-$(pwd)}}"

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

MC_SINGLE_ARM_REPO="${MC_SINGLE_ARM_REPO:-${PWD}}"
RUN_SCRIPT="${MC_SINGLE_ARM_RUN_SCRIPT:-run_mc_single_arm_tree_eprime_bin}"
TARGET_GOOD_EVENTS="${TARGET_GOOD_EVENTS:-1000000}"
CHUNK_TRIALS="${CHUNK_TRIALS:-2000000}"
MAX_CHUNKS="${MAX_CHUNKS:-500}"

if [[ ! -d "${MC_SINGLE_ARM_REPO}" ]]; then
    echo "ERROR: MC_SINGLE_ARM_REPO does not exist: ${MC_SINGLE_ARM_REPO}" >&2
    exit 3
fi

if [[ "${RUN_SCRIPT}" = /* ]]; then
    SCRIPT_PATH="${RUN_SCRIPT}"
else
    SCRIPT_PATH="${MC_SINGLE_ARM_REPO}/${RUN_SCRIPT}"
fi

if [[ ! -f "${SCRIPT_PATH}" ]]; then
    echo "ERROR: run script file not found: ${SCRIPT_PATH}" >&2
    exit 3
fi
if [[ ! -x "${SCRIPT_PATH}" ]]; then
    echo "ERROR: run script is not executable: ${SCRIPT_PATH}" >&2
    exit 3
fi

if ! [[ "${TARGET_GOOD_EVENTS}" =~ ^[0-9]+$ && "${CHUNK_TRIALS}" =~ ^[0-9]+$ && "${MAX_CHUNKS}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: TARGET_GOOD_EVENTS, CHUNK_TRIALS, and MAX_CHUNKS must be integers." >&2
    exit 2
fi

run_tag="${KIN_NAME}_bin$(printf '%03d' "${BIN_INDEX}")"
expected_output="${MC_SINGLE_ARM_REPO}/outfiles/${run_tag}.root"

# Prevent stale-file false positives from previous retries/runs.
rm -f "${expected_output}"

pushd "${MC_SINGLE_ARM_REPO}" >/dev/null
TARGET_GOOD_EVENTS="${TARGET_GOOD_EVENTS}" \
CHUNK_TRIALS="${CHUNK_TRIALS}" \
MAX_CHUNKS="${MAX_CHUNKS}" \
"${SCRIPT_PATH}" "${KIN_NAME}" "${BIN_INDEX}"
popd >/dev/null

if [[ ! -f "${expected_output}" ]]; then
    echo "ERROR: expected output file not found: ${expected_output}" >&2
    exit 4
fi
if [[ ! -s "${expected_output}" ]]; then
    echo "ERROR: expected output file is empty (possible Fortran/runtime failure): ${expected_output}" >&2
    exit 4
fi

mkdir -p "${JOB_WORK_DIR}"
staged_name="${KIN_NAME}_bin${BIN_INDEX}.root"
staged_file="${JOB_WORK_DIR}/${staged_name}"
cp -f "${expected_output}" "${staged_file}"

echo "Staged SWIF output copy at ${staged_file}"
