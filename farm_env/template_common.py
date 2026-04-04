#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

DEFAULT_SWIF2 = os.environ.get("SWIF2_BIN", "swif2")
DEFAULT_ACCOUNT = "hallc"
DEFAULT_PARTITION = "production"
DEFAULT_MAX_CONCURRENT = 200
DEFAULT_CORES = 1
DEFAULT_RAM = "8g"
DEFAULT_DISK = "40g"
DEFAULT_TIME = "8h"
DEFAULT_MANIFEST_DIR = str(Path(__file__).resolve().parents[1] / "examples")

RUN_LINE_RE = re.compile(r"^\s*(\d+)\s*$")
SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9_.-]+")


@dataclass(frozen=True)
class OutputSpec:
    local_name: str
    remote_file: Path


@dataclass(frozen=True)
class ManifestJob:
    manifest_path: Path
    variant_name: str
    partition: str
    runs_files: Tuple[Path, ...]
    worker_args_raw: Tuple[str, ...]
    outputs_raw: Tuple[Dict[str, str], ...]


def run_command(cmd: Sequence[str], capture: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(list(cmd), text=True, capture_output=capture, check=False)


def safe_name(text: str) -> str:
    return SAFE_NAME_RE.sub("_", text).strip("_")


def format_tokens(template: str, *, selector: str, run: int, variant: str, manifest_name: str) -> str:
    return template.format(
        selector=selector,
        run=run,
        run5=f"{run:05d}",
        variant=variant,
        manifest=manifest_name,
    )


def format_remote_arg(remote_path: Path) -> str:
    remote_text = str(remote_path)
    if remote_text.startswith("/mss/"):
        return f"mss:{remote_text}"
    return remote_text


def read_runs_file(path: Path) -> Set[int]:
    if not path.exists():
        raise FileNotFoundError(f"Runs file not found: {path}")
    runs: Set[int] = set()
    with path.open("r", encoding="utf-8") as handle:
        for raw in handle:
            match = RUN_LINE_RE.match(raw)
            if match:
                runs.add(int(match.group(1)))
    return runs


def normalize_runs_files(raw_value: object, manifest_path: Path) -> Tuple[Path, ...]:
    if isinstance(raw_value, str):
        values = [raw_value]
    elif isinstance(raw_value, list):
        values = [item for item in raw_value if isinstance(item, str)]
    else:
        values = []

    paths: List[Path] = []
    for value in values:
        path = Path(os.path.expandvars(value))
        if not path.is_absolute():
            path = (manifest_path.parent / path).resolve()
        paths.append(path)
    return tuple(paths)


def load_manifest_jobs(manifest_dir: Path, manifest_glob: str, partition_override: Optional[str]) -> List[ManifestJob]:
    manifest_paths = sorted(manifest_dir.glob(manifest_glob))
    if not manifest_paths:
        raise FileNotFoundError(f"No manifests found for glob {manifest_glob} under {manifest_dir}")

    jobs: List[ManifestJob] = []
    for manifest_path in manifest_paths:
        with manifest_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)

        defaults = payload.get("defaults", {})
        default_partition = str(defaults.get("partition") or DEFAULT_PARTITION)
        manifest_jobs = payload.get("jobs", [])
        if not isinstance(manifest_jobs, list) or not manifest_jobs:
            raise ValueError(f"Manifest has no jobs list: {manifest_path}")

        for index, job in enumerate(manifest_jobs, start=1):
            if not isinstance(job, dict):
                continue

            variant_name = str(job.get("variant_name") or manifest_path.stem)
            if len(manifest_jobs) > 1 and "variant_name" not in job:
                variant_name = f"{manifest_path.stem}_{index}"

            runs_files = normalize_runs_files(job.get("runs_file") or job.get("runs_files"), manifest_path)
            if not runs_files:
                raise ValueError(f"Manifest job missing runs_file/runs_files: {manifest_path} ({variant_name})")

            raw_outputs = job.get("outputs", [])
            if not isinstance(raw_outputs, list) or not raw_outputs:
                raise ValueError(f"Manifest job missing outputs list: {manifest_path} ({variant_name})")

            outputs_raw: List[Dict[str, str]] = []
            for raw_output in raw_outputs:
                if not isinstance(raw_output, dict):
                    continue
                local_template = raw_output.get("local_template")
                remote_dir = raw_output.get("remote_dir")
                remote_file_template = raw_output.get("remote_file_template")
                if not isinstance(local_template, str):
                    raise ValueError(f"Output missing local_template: {manifest_path} ({variant_name})")
                if not isinstance(remote_dir, str) and not isinstance(remote_file_template, str):
                    raise ValueError(
                        f"Output must define remote_dir or remote_file_template: {manifest_path} ({variant_name})"
                    )
                output_entry = {"local_template": local_template}
                if isinstance(remote_dir, str):
                    output_entry["remote_dir"] = remote_dir
                if isinstance(remote_file_template, str):
                    output_entry["remote_file_template"] = remote_file_template
                outputs_raw.append(output_entry)

            worker_args_raw: Tuple[str, ...]
            if isinstance(job.get("worker_args"), list):
                worker_args_raw = tuple(str(item) for item in job["worker_args"])
            else:
                worker_args_raw = ()

            jobs.append(
                ManifestJob(
                    manifest_path=manifest_path,
                    variant_name=variant_name,
                    partition=str(partition_override or job.get("partition") or default_partition),
                    runs_files=runs_files,
                    worker_args_raw=worker_args_raw,
                    outputs_raw=tuple(outputs_raw),
                )
            )
    return jobs


def render_worker_args(raw_args: Sequence[str], *, selector: str, run: int, variant: str, manifest_name: str, fallback: Sequence[str]) -> Tuple[str, ...]:
    templates = list(raw_args) if raw_args else list(fallback)
    return tuple(
        format_tokens(str(template), selector=selector, run=run, variant=variant, manifest_name=manifest_name)
        for template in templates
    )


def render_outputs(outputs_raw: Sequence[Dict[str, str]], *, selector: str, run: int, variant: str, manifest_name: str) -> Tuple[OutputSpec, ...]:
    rendered: List[OutputSpec] = []
    for raw_output in outputs_raw:
        local_name = format_tokens(
            raw_output["local_template"],
            selector=selector,
            run=run,
            variant=variant,
            manifest_name=manifest_name,
        )
        if "remote_file_template" in raw_output:
            remote_path = Path(
                format_tokens(
                    raw_output["remote_file_template"],
                    selector=selector,
                    run=run,
                    variant=variant,
                    manifest_name=manifest_name,
                )
            )
        else:
            remote_dir = Path(
                format_tokens(
                    raw_output["remote_dir"],
                    selector=selector,
                    run=run,
                    variant=variant,
                    manifest_name=manifest_name,
                )
            )
            remote_path = remote_dir / local_name
        rendered.append(OutputSpec(local_name=local_name, remote_file=remote_path))
    return tuple(rendered)


def workflow_exists(swif2_bin: str, workflow: str) -> bool:
    result = run_command([swif2_bin, "status", workflow, "-summary"], capture=True)
    return result.returncode == 0


def load_existing_job_names(swif2_bin: str, workflow: str) -> Set[str]:
    if not workflow_exists(swif2_bin, workflow):
        return set()
    result = run_command([swif2_bin, "status", workflow, "-jobs", "-display", "json"], capture=True)
    if result.returncode != 0:
        return set()
    payload = json.loads(result.stdout)
    names: Set[str] = set()
    for job in payload.get("jobs", []):
        if isinstance(job, dict) and job.get("job_name"):
            names.add(str(job["job_name"]))
    return names


def create_workflow_if_needed(swif2_bin: str, workflow: str, max_concurrent: int) -> None:
    if workflow_exists(swif2_bin, workflow):
        return
    result = run_command([swif2_bin, "create", workflow, "-max-concurrent", str(max_concurrent)], capture=True)
    if result.stdout:
        print(result.stdout.rstrip())
    if result.stderr:
        print(result.stderr.rstrip())
    if result.returncode != 0:
        raise RuntimeError(f"Failed to create workflow {workflow}")


def summarize_cmd(cmd: Sequence[str]) -> str:
    return " ".join(shlex.quote(part) for part in cmd)
