#! /bin/bash

set -euo pipefail

VARIANT_NAME="${1:-}"
RUN_ID="${2:-}"
JOB_WORK_DIR="${SWIF_JOB_WORK_DIR:-${SWIF_JOB_STAGE_DIR:-$(pwd)}}"

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

require_file "${PRIMARY_OUTPUT_SOURCE}"
stage_swif_copy "${PRIMARY_OUTPUT_SOURCE}"

if [[ -n "${SECONDARY_OUTPUT_SOURCE}" ]]; then
    require_file "${SECONDARY_OUTPUT_SOURCE}"
    stage_swif_copy "${SECONDARY_OUTPUT_SOURCE}"
fi
