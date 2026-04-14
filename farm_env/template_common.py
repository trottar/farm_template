#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple

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
UNRESOLVED_ENV_RE = re.compile(r"\$(\{[^}]+\}|[A-Za-z_][A-Za-z0-9_]*)")
WINDOWS_DRIVE_RE = re.compile(r"^[A-Za-z]:[\\/]")


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
    worker_env_raw: Tuple[Tuple[str, str], ...]
    outputs_raw: Tuple[Dict[str, str], ...]


def run_command(cmd: Sequence[str], capture: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(list(cmd), text=True, capture_output=capture, check=False)


def safe_name(text: str) -> str:
    return SAFE_NAME_RE.sub("_", text).strip("_")


def expand_path_tokens(value: str, *, context: str) -> str:
    expanded = os.path.expanduser(os.path.expandvars(value))
    if UNRESOLVED_ENV_RE.search(expanded):
        raise ValueError(f"Unresolved environment variable in {context}: {value}")
    return expanded


def looks_like_path(value: str) -> bool:
    if not value:
        return False
    if WINDOWS_DRIVE_RE.match(value):
        return True
    if value.startswith(("~", "/", "./", "../", ".\\", "..\\")):
        return True
    return "/" in value or "\\" in value


def env_value_should_be_path(key: str, value: str) -> bool:
    key_upper = key.upper()
    if os.pathsep in value and key_upper in {"PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "PYTHONPATH"}:
        return False
    return key_upper.endswith(("_DIR", "_FILE", "_PATH", "_ROOT", "_REPO", "_SCRIPT", "_HOME"))


def resolve_explicit_path(value: str, *, base_dir: Path, context: str, must_exist: bool = False) -> Path:
    expanded = expand_path_tokens(value, context=context)
    path = Path(expanded)
    if not path.is_absolute():
        path = base_dir / path
    path = path.resolve()
    if must_exist and not path.exists():
        raise FileNotFoundError(f"{context} not found: {path}")
    return path


def normalize_path_like_value(value: str, *, base_dir: Path, context: str, force_path: bool = False) -> str:
    expanded = expand_path_tokens(value, context=context)
    if force_path or looks_like_path(expanded):
        return str(resolve_explicit_path(expanded, base_dir=base_dir, context=context))
    return expanded


def resolve_submit_path_arg(value: str, *, what: str, must_exist: bool = True, require_dir: bool = False) -> str:
    path = resolve_explicit_path(value, base_dir=Path.cwd(), context=what, must_exist=must_exist)
    if require_dir and not path.is_dir():
        raise NotADirectoryError(f"{what} is not a directory: {path}")
    return str(path)


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
        path = resolve_explicit_path(value, base_dir=manifest_path.parent, context=f"runs_file in {manifest_path.name}")
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

            worker_args_raw = tuple(str(item) for item in job.get("worker_args", [])) if isinstance(job.get("worker_args"), list) else ()

            worker_env_raw: Tuple[Tuple[str, str], ...] = ()
            if isinstance(job.get("worker_env"), dict):
                worker_env_raw = tuple((str(k), str(v)) for k, v in job["worker_env"].items())

            jobs.append(
                ManifestJob(
                    manifest_path=manifest_path,
                    variant_name=variant_name,
                    partition=str(partition_override or job.get("partition") or default_partition),
                    runs_files=runs_files,
                    worker_args_raw=worker_args_raw,
                    worker_env_raw=worker_env_raw,
                    outputs_raw=tuple(outputs_raw),
                )
            )
    return jobs


def render_worker_args(
    raw_args: Sequence[str],
    *,
    selector: str,
    run: int,
    variant: str,
    manifest_name: str,
    manifest_path: Path,
    fallback: Sequence[str],
) -> Tuple[str, ...]:
    templates = list(raw_args) if raw_args else list(fallback)
    return tuple(
        normalize_path_like_value(
            format_tokens(str(template), selector=selector, run=run, variant=variant, manifest_name=manifest_name),
            base_dir=manifest_path.parent,
            context=f"worker_args[{index}] in {manifest_path.name}",
        )
        for index, template in enumerate(templates, start=1)
    )


def render_worker_env(
    raw_env: Sequence[Tuple[str, str]],
    *,
    selector: str,
    run: int,
    variant: str,
    manifest_name: str,
    manifest_path: Path,
) -> Tuple[Tuple[str, str], ...]:
    rendered: List[Tuple[str, str]] = []
    token_map = {
        "{selector}": selector,
        "{run}": str(run),
        "{run5}": f"{run:05d}",
        "{variant}": variant,
        "{manifest}": manifest_name,
    }
    for key, value_template in raw_env:
        value = value_template
        for token, token_value in token_map.items():
            value = value.replace(token, token_value)
        value = normalize_path_like_value(
            value,
            base_dir=manifest_path.parent,
            context=f"worker_env[{key}] for variant={variant}, run={run}",
            force_path=env_value_should_be_path(key, value),
        )
        if value:
            rendered.append((key, value))
    return tuple(rendered)


def render_outputs(
    outputs_raw: Sequence[Dict[str, str]],
    *,
    selector: str,
    run: int,
    variant: str,
    manifest_name: str,
    manifest_path: Path,
) -> Tuple[OutputSpec, ...]:
    rendered: List[OutputSpec] = []
    for raw_output in outputs_raw:
        local_name = format_tokens(raw_output["local_template"], selector=selector, run=run, variant=variant, manifest_name=manifest_name)
        if looks_like_path(local_name):
            raise ValueError(
                f"local_template must resolve to a basename, not a path: {local_name} ({manifest_path.name})"
            )
        if "remote_file_template" in raw_output:
            remote_path = resolve_explicit_path(
                format_tokens(
                    raw_output["remote_file_template"],
                    selector=selector,
                    run=run,
                    variant=variant,
                    manifest_name=manifest_name,
                ),
                base_dir=manifest_path.parent,
                context=f"remote_file_template in {manifest_path.name}",
            )
        else:
            remote_dir = resolve_explicit_path(
                format_tokens(
                    raw_output["remote_dir"],
                    selector=selector,
                    run=run,
                    variant=variant,
                    manifest_name=manifest_name,
                ),
                base_dir=manifest_path.parent,
                context=f"remote_dir in {manifest_path.name}",
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


def build_worker_invocation(worker_script: str, worker_args: Sequence[str], worker_env: Sequence[Tuple[str, str]]) -> List[str]:
    worker_script = resolve_submit_path_arg(worker_script, what="worker_script", must_exist=True)
    exported = [f"{key}={value}" for key, value in worker_env if key and value]
    if not exported:
        return [worker_script, *worker_args]
    return ["env", *exported, worker_script, *worker_args]
