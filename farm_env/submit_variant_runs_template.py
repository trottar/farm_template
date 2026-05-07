#!/usr/bin/env python3
"""
Generic template: submit one SWIF job per manifest variant + run.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

from template_common import (
    DEFAULT_ACCOUNT,
    DEFAULT_CORES,
    DEFAULT_DISK,
    DEFAULT_MANIFEST_DIR,
    DEFAULT_MAX_CONCURRENT,
    DEFAULT_PARTITION,
    DEFAULT_RAM,
    DEFAULT_SWIF2,
    DEFAULT_TIME,
    ManifestJob,
    OutputSpec,
    derive_job_name,
    create_workflow_if_needed,
    build_worker_invocation,
    format_remote_arg,
    load_existing_job_names,
    load_framework_worker_env,
    load_manifest_jobs,
    merge_worker_env_layers,
    read_runs_file,
    render_outputs,
    render_worker_args,
    render_worker_env,
    resolve_submit_path_arg,
    run_command,
    safe_name,
    summarize_cmd,
)


@dataclass(frozen=True)
class RunPlan:
    variant_name: str
    run: int
    job_name: str
    worker_args: Tuple[str, ...]
    worker_env: Tuple[Tuple[str, str], ...]
    outputs_all: Tuple[OutputSpec, ...]
    outputs_missing: Tuple[OutputSpec, ...]
    partition: str
    status: str
    note: str


def resolve_manifest_glob(selector: str, manifest_glob: Optional[str]) -> str:
    if manifest_glob:
        return manifest_glob
    if selector:
        return f"{selector}*.json"
    return "*.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Submit one SWIF job per manifest variant + run.")
    parser.add_argument("selector", nargs="?", default="", help="Optional manifest selector prefix")
    parser.add_argument("--manifest-dir", default=DEFAULT_MANIFEST_DIR, help="Directory containing manifests")
    parser.add_argument("--manifest-glob", default=None, help="Explicit manifest glob, e.g. '*simc*.json'")
    parser.add_argument("--worker-script", required=True, help="Batch-node worker script to run")
    parser.add_argument("--framework-config", default=None, help="Optional framework config JSON for shared worker_env")
    parser.add_argument("--workflow-name", required=True, help="Target SWIF workflow name")
    parser.add_argument("--swif2-bin", default=DEFAULT_SWIF2, help="SWIF2 client executable")
    parser.add_argument("--account", default=DEFAULT_ACCOUNT, help="SWIF/Slurm account")
    parser.add_argument("--partition", default=None, help="Override manifest partition")
    parser.add_argument("--max-concurrent", type=int, default=DEFAULT_MAX_CONCURRENT)
    parser.add_argument("--cores", type=int, default=DEFAULT_CORES)
    parser.add_argument("--ram", default=DEFAULT_RAM)
    parser.add_argument("--disk", default=DEFAULT_DISK)
    parser.add_argument("--time", default=DEFAULT_TIME)
    parser.add_argument("--submit", action="store_true", help="Actually create/add jobs")
    parser.add_argument("--no-run", action="store_true", help="With --submit, do not call swif2 run")
    parser.add_argument("--skip-existing", action="store_true", default=True, help="Skip jobs already present in workflow")
    parser.add_argument("--no-skip-existing", dest="skip_existing", action="store_false")
    return parser.parse_args()


def build_run_plans(args: argparse.Namespace, manifest_jobs: Sequence[ManifestJob]) -> List[RunPlan]:
    existing_job_names = load_existing_job_names(args.swif2_bin, args.workflow_name) if args.skip_existing else set()
    plans: List[RunPlan] = []
    selector_label = args.selector or "selection"
    framework_worker_env = load_framework_worker_env(args.framework_config)
    for manifest_job in manifest_jobs:
        variant_runs = set()
        for runs_file in manifest_job.runs_files:
            variant_runs.update(read_runs_file(runs_file))

        for run in sorted(variant_runs):
            worker_args = render_worker_args(
                manifest_job.worker_args_raw,
                selector=selector_label,
                run=run,
                variant=manifest_job.variant_name,
                manifest_name=manifest_job.manifest_path.stem,
                manifest_path=manifest_job.manifest_path,
                fallback=(manifest_job.variant_name, "{run}"),
            )
            worker_env = render_worker_env(
                merge_worker_env_layers(framework_worker_env, manifest_job.worker_env_raw),
                selector=selector_label,
                run=run,
                variant=manifest_job.variant_name,
                manifest_name=manifest_job.manifest_path.stem,
                manifest_path=manifest_job.manifest_path,
            )
            outputs_all = render_outputs(
                manifest_job.outputs_raw,
                selector=selector_label,
                run=run,
                variant=manifest_job.variant_name,
                manifest_name=manifest_job.manifest_path.stem,
                manifest_path=manifest_job.manifest_path,
            )
            outputs_missing = tuple(output for output in outputs_all if not output.remote_file.exists())
            job_name = derive_job_name(
                f"{selector_label}_{manifest_job.variant_name}_run{run}",
                worker_args=worker_args,
                worker_env=worker_env,
                outputs=outputs_all,
                extra_identity=(manifest_job.variant_name, manifest_job.manifest_path.stem),
            )

            if not outputs_missing:
                status = "SKIP"
                note = "all_declared_outputs_already_exist"
            elif job_name in existing_job_names:
                status = "SKIP"
                note = "job_name_already_exists"
            else:
                status = "ADD"
                note = "missing_outputs_only" if len(outputs_missing) != len(outputs_all) else "all_outputs_missing"

            plans.append(
                RunPlan(
                    variant_name=manifest_job.variant_name,
                    run=run,
                    job_name=job_name,
                    worker_args=worker_args,
                    worker_env=worker_env,
                    outputs_all=outputs_all,
                    outputs_missing=outputs_missing,
                    partition=manifest_job.partition,
                    status=status,
                    note=note,
                )
            )
    return plans


def build_add_job_command(args: argparse.Namespace, plan: RunPlan) -> List[str]:
    selector_label = args.selector or args.manifest_glob or "selection"
    cmd: List[str] = [
        args.swif2_bin,
        "add-job",
        args.workflow_name,
        "-account",
        args.account,
        "-partition",
        plan.partition or DEFAULT_PARTITION,
        "-name",
        plan.job_name,
        "-cores",
        str(args.cores),
        "-ram",
        args.ram,
        "-disk",
        args.disk,
        "-time",
        args.time,
        "-tag",
        "selection",
        selector_label,
        "-tag",
        "variant",
        plan.variant_name,
        "-tag",
        "run",
        str(plan.run),
    ]
    for output in plan.outputs_missing:
        cmd.extend(["-output", output.local_name, format_remote_arg(output.remote_file)])
    worker_env = list(plan.worker_env)
    if len(plan.outputs_all) == 1:
        worker_env.append(("SWIF_PRIMARY_OUTPUT_BASENAME", plan.outputs_all[0].local_name))
    cmd.extend(build_worker_invocation(args.worker_script, plan.worker_args, tuple(worker_env)))
    return cmd


def main() -> int:
    args = parse_args()
    args.worker_script = resolve_submit_path_arg(args.worker_script, what="worker_script", must_exist=True)
    manifest_dir = Path(resolve_submit_path_arg(args.manifest_dir, what="manifest_dir", must_exist=True, require_dir=True))
    manifest_glob = resolve_manifest_glob(args.selector, args.manifest_glob)
    manifest_jobs = load_manifest_jobs(manifest_dir, manifest_glob, args.partition)
    plans = build_run_plans(args, manifest_jobs)

    print(f"Selector          : {args.selector or '<all>'}")
    print(f"Manifest glob     : {manifest_glob}")
    print(f"Manifest directory: {manifest_dir}")
    print(f"Workflow          : {args.workflow_name}")
    print(f"Worker script     : {args.worker_script}")
    print(f"Account           : {args.account}")
    print(f"Partition         : {args.partition or 'per-manifest defaults.partition'}")
    print(f"Matched variants  : {len(manifest_jobs)}")
    print(f"Planned jobs      : {len(plans)}")
    print()

    print("Planned SWIF2 jobs")
    print("-" * 80)
    commands: List[List[str]] = []
    for plan in plans:
        print(f"[{plan.status} {plan.note}] variant={plan.variant_name} run={plan.run} job={plan.job_name}")
        for output in plan.outputs_all:
            prefix = "missing" if output in plan.outputs_missing else "exists "
            print(f"         {prefix}: {output.local_name} -> {output.remote_file}")
        if plan.status == "ADD":
            cmd = build_add_job_command(args, plan)
            commands.append(cmd)
            print(f"         cmd     : {summarize_cmd(cmd)}")
    print()

    if not args.submit:
        print("Dry run only. Use --submit to create/update the workflow and add jobs.")
        return 0

    if not commands:
        print("No jobs to submit.")
        return 0

    create_workflow_if_needed(args.swif2_bin, args.workflow_name, args.max_concurrent)
    for cmd in commands:
        result = run_command(cmd, capture=True)
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        if result.returncode != 0:
            return result.returncode

    if not args.no_run:
        result = run_command([args.swif2_bin, "run", args.workflow_name], capture=True)
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        return result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
