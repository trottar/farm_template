#! /bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ENV_DIR="${SCRIPT_DIR}/farm_env"
DEFAULT_MANIFEST_DIR="${SCRIPT_DIR}/examples"

UNIQUE_SUBMIT_SCRIPT="${TEMPLATE_ENV_DIR}/submit_unique_runs_template.py"
VARIANT_SUBMIT_SCRIPT="${TEMPLATE_ENV_DIR}/submit_variant_runs_template.py"
DIAGNOSE_SCRIPT="${TEMPLATE_ENV_DIR}/diagnose_swif_failures_template.py"
REBALANCE_SCRIPT="${TEMPLATE_ENV_DIR}/rebalance_swif_template.py"

DEFAULT_WORKFLOW_PREFIX="analysis"
DEFAULT_UNIQUE_WORKER="${SCRIPT_DIR}/workers/worker_single_run_template.sh"
DEFAULT_VARIANT_WORKER="${SCRIPT_DIR}/workers/worker_variant_run_template.sh"

resolve_existing_path() {
    python3 - <<'PY' "$1"
from pathlib import Path
import sys

path = Path(sys.argv[1]).expanduser().resolve()
if not path.exists():
    raise SystemExit(f"ERROR: path does not exist: {path}")
print(path)
PY
}

resolve_existing_dir() {
    python3 - <<'PY' "$1"
from pathlib import Path
import sys

path = Path(sys.argv[1]).expanduser().resolve()
if not path.exists():
    raise SystemExit(f"ERROR: directory does not exist: {path}")
if not path.is_dir():
    raise SystemExit(f"ERROR: expected directory path, got: {path}")
print(path)
PY
}

print_help() {
    echo "--------------------------------------------------------------"
    echo "./farm_templates/run_farm_template.sh [flags] [selector]"
    echo
    echo "Description: Generic SWIF submit/rebalance/diagnose wrapper."
    echo "--------------------------------------------------------------"
    echo
    echo "Flags:"
    echo "    -h, help"
    echo "    -s, actually submit jobs (default is dry-run)"
    echo "    -r, rebalance an existing workflow"
    echo "    -a, with -r, actually apply modify-jobs commands"
    echo "    -n, do not call 'swif2 run' after submit/rebalance"
    echo "    -d, diagnose failed jobs and inspect completed ROOT cache files"
    echo "    -v, use variant-run mode instead of unique-run mode"
    echo "    -g, explicit manifest glob (default: selector*.json or *.json)"
    echo "    -C, framework config JSON"
    echo "    -w, override workflow name"
    echo "    -m, override manifest directory"
    echo "    -W, override worker script"
    echo "    -A, override SWIF/Slurm account"
    echo "    -P, override SWIF/Slurm partition"
    echo
    echo "Examples:"
    echo "    ./farm_templates/run_farm_template.sh simc_prod"
    echo "    ./farm_templates/run_farm_template.sh -s simc_prod"
    echo "    ./farm_templates/run_farm_template.sh -g '*replay*.json' -s"
    echo "    ./farm_templates/run_farm_template.sh -C farm_templates/framework_config.example.json -s"
    echo "    ./farm_templates/run_farm_template.sh -d -w my_workflow"
    echo "    ./farm_templates/run_farm_template.sh -r -a -w my_workflow"
}

while getopts 'hsrandvg:C:w:m:W:A:P:' flag; do
    case "${flag}" in
        h) print_help; exit 0 ;;
        s) submit_flag='true' ;;
        r) rebalance_flag='true' ;;
        a) apply_flag='true' ;;
        n) no_run_flag='true' ;;
        d) diagnose_flag='true' ;;
        v) variant_flag='true' ;;
        g) manifest_glob="${OPTARG}" ;;
        C) framework_config="${OPTARG}" ;;
        w) workflow_override="${OPTARG}" ;;
        m) manifest_dir="${OPTARG}"; manifest_dir_set='true' ;;
        W) worker_script="${OPTARG}"; worker_script_set='true' ;;
        A) account_override="${OPTARG}" ;;
        P) partition_override="${OPTARG}" ;;
        *) exit 1 ;;
    esac
done

shift $((OPTIND - 1))

if [[ "${rebalance_flag:-false}" = "true" && "${submit_flag:-false}" = "true" ]]; then
    echo "Please choose either submit mode or rebalance mode, not both."
    exit 1
fi

if [[ "${diagnose_flag:-false}" = "true" && "${submit_flag:-false}" = "true" ]]; then
    echo "The -s flag is not used in diagnose mode."
    exit 1
fi

if [[ "${diagnose_flag:-false}" = "true" && "${rebalance_flag:-false}" = "true" ]]; then
    echo "Please choose either diagnose mode or rebalance mode, not both."
    exit 1
fi

if [[ "${rebalance_flag:-false}" != "true" && "${apply_flag:-false}" = "true" ]]; then
    echo "The -a flag is only valid together with -r."
    exit 1
fi

SELECTOR="${1:-}"

MODE_NAME="unique"
MODE_SCRIPT="${UNIQUE_SUBMIT_SCRIPT}"
DEFAULT_WORKER="${DEFAULT_UNIQUE_WORKER}"
WORKFLOW_SUFFIX=""
if [[ "${variant_flag:-false}" = "true" ]]; then
    MODE_NAME="variant"
    MODE_SCRIPT="${VARIANT_SUBMIT_SCRIPT}"
    DEFAULT_WORKER="${DEFAULT_VARIANT_WORKER}"
    WORKFLOW_SUFFIX="_variant"
fi

if [[ -n "${framework_config:-}" ]]; then
    framework_config="$(resolve_existing_path "${framework_config}")"
    CONFIG_EXPORTS="$(python3 - <<'PY' "${framework_config}"
import json, sys
from pathlib import Path

config_path = Path(sys.argv[1]).expanduser().resolve()
with config_path.open("r", encoding="utf-8") as handle:
    config = json.load(handle)

def emit(name, value):
    if value is None:
        return
    print(f'{name}="{value}"')

emit("CFG_WORKFLOW_PREFIX", config.get("workflow_prefix"))
emit("CFG_MANIFEST_DIR", config.get("manifest_dir"))
emit("CFG_MANIFEST_GLOB", config.get("manifest_glob"))
emit("CFG_MODE", config.get("mode"))
emit("CFG_WORKER_SCRIPT", config.get("worker_script"))
emit("CFG_ACCOUNT", config.get("account"))
emit("CFG_PARTITION", config.get("partition"))
PY
)"
    eval "${CONFIG_EXPORTS}"

    if [[ "${manifest_dir_set:-false}" != "true" && -n "${CFG_MANIFEST_DIR:-}" ]]; then
        manifest_dir="${CFG_MANIFEST_DIR}"
        if [[ "${manifest_dir}" != /* ]]; then
            manifest_dir="$(cd "$(dirname "${framework_config}")" && pwd)/${manifest_dir}"
        fi
    fi
    if [[ -z "${manifest_glob:-}" && -n "${CFG_MANIFEST_GLOB:-}" ]]; then
        manifest_glob="${CFG_MANIFEST_GLOB}"
    fi
    if [[ "${worker_script_set:-false}" != "true" && -n "${CFG_WORKER_SCRIPT:-}" ]]; then
        worker_script="${CFG_WORKER_SCRIPT}"
        if [[ "${worker_script}" != /* ]]; then
            worker_script="$(cd "$(dirname "${framework_config}")" && pwd)/${worker_script}"
        fi
    fi
    if [[ "${variant_flag:-false}" != "true" && "${CFG_MODE:-}" = "variant" ]]; then
        variant_flag='true'
        MODE_NAME="variant"
        MODE_SCRIPT="${VARIANT_SUBMIT_SCRIPT}"
        DEFAULT_WORKER="${DEFAULT_VARIANT_WORKER}"
        WORKFLOW_SUFFIX="_variant"
    fi
    if [[ -z "${account_override:-}" && -n "${CFG_ACCOUNT:-}" ]]; then
        account_override="${CFG_ACCOUNT}"
    fi
    if [[ -z "${partition_override:-}" && -n "${CFG_PARTITION:-}" ]]; then
        partition_override="${CFG_PARTITION}"
    fi
    if [[ -n "${CFG_WORKFLOW_PREFIX:-}" ]]; then
        DEFAULT_WORKFLOW_PREFIX="${CFG_WORKFLOW_PREFIX}"
    fi
fi

if [[ -z "${manifest_dir:-}" ]]; then
    manifest_dir="${DEFAULT_MANIFEST_DIR}"
fi
manifest_dir="$(resolve_existing_dir "${manifest_dir}")"

if [[ -z "${worker_script:-}" ]]; then
    worker_script="${DEFAULT_WORKER}"
fi
worker_script="$(resolve_existing_path "${worker_script}")"

if [[ -z "${manifest_glob:-}" ]]; then
    if [[ -n "${SELECTOR}" ]]; then
        manifest_glob="${SELECTOR}*.json"
    else
        manifest_glob="*.json"
    fi
fi

if [[ -n "${workflow_override:-}" ]]; then
    WORKFLOW="${workflow_override}"
elif [[ "${diagnose_flag:-false}" = "true" || "${rebalance_flag:-false}" = "true" ]] && [[ -n "${SELECTOR}" ]]; then
    WORKFLOW="${SELECTOR}"
else
    USER_NAME="${USER:-user}"
    WORKFLOW_TOKEN="${SELECTOR:-${manifest_glob}}"
    WORKFLOW_TOKEN="$(printf '%s' "${WORKFLOW_TOKEN}" | tr -cs 'A-Za-z0-9._-' '_')"
    WORKFLOW="${DEFAULT_WORKFLOW_PREFIX}_${WORKFLOW_TOKEN}${WORKFLOW_SUFFIX}_${USER_NAME}"
fi

if [[ "${diagnose_flag:-false}" = "true" ]]; then
    cmd=(python3 "${DIAGNOSE_SCRIPT}" "${WORKFLOW}")
    echo "Running: ${cmd[*]}"
    "${cmd[@]}"
    exit $?
fi

if [[ "${rebalance_flag:-false}" = "true" ]]; then
    cmd=(python3 "${REBALANCE_SCRIPT}" "${WORKFLOW}")
    if [[ "${apply_flag:-false}" = "true" ]]; then
        cmd+=(--apply)
    fi
    if [[ "${no_run_flag:-false}" = "true" ]]; then
        cmd+=(--no-run)
    fi
    echo "Running: ${cmd[*]}"
    "${cmd[@]}"
    exit $?
fi

cmd=(python3 "${MODE_SCRIPT}" --manifest-dir "${manifest_dir}" --manifest-glob "${manifest_glob}" --workflow-name "${WORKFLOW}" --worker-script "${worker_script}")
if [[ -n "${framework_config:-}" ]]; then
    cmd+=(--framework-config "${framework_config}")
fi
if [[ -n "${SELECTOR}" ]]; then
    cmd=("${cmd[@]:0:2}" "${SELECTOR}" "${cmd[@]:2}")
fi
if [[ -n "${account_override:-}" ]]; then
    cmd+=(--account "${account_override}")
fi
if [[ -n "${partition_override:-}" ]]; then
    cmd+=(--partition "${partition_override}")
fi
if [[ "${submit_flag:-false}" = "true" ]]; then
    cmd+=(--submit)
fi
if [[ "${no_run_flag:-false}" = "true" ]]; then
    cmd+=(--no-run)
fi

echo "Running: ${cmd[*]}"
"${cmd[@]}"
