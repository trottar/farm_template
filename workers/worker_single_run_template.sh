#! /bin/bash

set -euo pipefail

RUN_ID="${1:-}"
JOB_WORK_DIR="${SWIF_JOB_WORK_DIR:-${SWIF_JOB_STAGE_DIR:-$(pwd)}}"

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

require_file "${PRIMARY_OUTPUT_SOURCE}"
stage_swif_copy "${PRIMARY_OUTPUT_SOURCE}"

if [[ -n "${PRIMARY_REPORT_SOURCE}" ]]; then
    require_file "${PRIMARY_REPORT_SOURCE}"
    stage_swif_copy "${PRIMARY_REPORT_SOURCE}"
fi

if [[ -n "${REPORT_TARBALL_SOURCE_DIR}" && -n "${REPORT_TARBALL_GLOB}" ]]; then
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
