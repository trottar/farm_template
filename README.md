# Generic Farm/Batch Templates

This directory is a reusable SWIF/farm orchestration scaffold that can be
repurposed for:

- other replay wrappers
- SIMC production
- skim or post-processing jobs
- any analysis that wants SWIF `-output`, failure diagnosis, and resource rebalance

Nothing in this directory is wired into the live KaonLT workflow. It is a
separate template stack you can copy and customize.

## Layout

- `run_farm_template.sh`
  Generic wrapper for submit, rebalance, and diagnose flows.
- `framework_config.example.json`
  Example framework-level config that points the wrapper at a manifest set,
  worker script, account, partition, and submit mode.
- `framework_config.kaonlt_replay.example.json`
  Concrete KaonLT replay example using the real repo manifests and replay worker.
- `framework_config.kaonlt_applycuts.example.json`
  Concrete KaonLT applyCuts example using the real repo manifests and applyCuts worker.
- `farm_env/submit_unique_runs_template.py`
  One SWIF job per unique run, merged across matching manifests.
- `farm_env/submit_variant_runs_template.py`
  One SWIF job per manifest variant + run.
- `farm_env/diagnose_swif_failures_template.py`
  Template entrypoint for the failure-diagnosis helper.
- `farm_env/rebalance_swif_template.py`
  Template entrypoint for the resource-rebalance helper.
- `workers/worker_single_run_template.sh`
  Batch-node worker skeleton for a single-run job.
- `workers/worker_variant_run_template.sh`
  Batch-node worker skeleton for a variant + run job.
- `examples/manifest_example.json`
  Example manifest shape expected by the submit templates.

## Manifest Shape

The template submitters expect manifests that look like this:

```json
{
  "defaults": {
    "partition": "production"
  },
  "jobs": [
    {
      "variant_name": "center_lowe",
      "runs_file": "/path/to/run_list.txt",
      "worker_args": ["center_lowe", "{run}"],
      "outputs": [
        {
          "local_template": "analysis_{run}.root",
          "remote_dir": "/mss/hallc/example/ROOTfiles/Analysis/Example"
        },
        {
          "local_template": "analysis_{run}.report",
          "remote_dir": "/mss/hallc/example/REPORT_OUTPUT/Analysis/Example"
        }
      ]
    }
  ]
}
```

Supported output fields:

- `local_template`
  Basename staged by the worker into `SWIF_JOB_WORK_DIR`.
- `remote_dir`
  MSS directory. The submitter appends the local basename.
- `remote_file_template`
  Full remote filename template if you need a custom output name.

Supported placeholders:

- `{run}`
- `{run5}`
- `{selector}`
- `{variant}`
- `{manifest}`

## Two Submit Styles

`submit_unique_runs_template.py`

- merges all matching manifests for a selector or explicit manifest glob
- submits one job per unique run
- best for replay-like production where multiple variants share the same run

`submit_variant_runs_template.py`

- keeps manifest variants separate
- submits one job per variant + run
- best for skims, SIMC variants, cut sweeps, or anything variant-specific

## Worker Expectations

The worker scripts are intentionally light and generic. The submitters assume:

- the job script creates its real outputs wherever your analysis normally writes them
- the job script copies final artifacts into:
  `\${SWIF_JOB_WORK_DIR:-\${SWIF_JOB_STAGE_DIR:-$(pwd)}}`
- the basenames staged there match the manifest `local_template` values

That is the same SWIF `-output` pattern the KaonLT farm flow is using now.

## Generic Usage

Dry-run unique-run submission using a selector prefix:

```bash
./farm_templates/run_farm_template.sh simc_prod
```

Actual unique-run submission:

```bash
./farm_templates/run_farm_template.sh -s simc_prod
```

Submission using an explicit glob instead of a selector:

```bash
./farm_templates/run_farm_template.sh -g "*replay*.json" -s
```

Submission driven by a framework config JSON:

```bash
./farm_templates/run_farm_template.sh -C farm_templates/framework_config.example.json -s
```

KaonLT replay example:

```bash
./farm_templates/run_farm_template.sh -C farm_templates/framework_config.kaonlt_replay.example.json -s
```

KaonLT applyCuts example:

```bash
./farm_templates/run_farm_template.sh -C farm_templates/framework_config.kaonlt_applycuts.example.json -s
```

Variant-run submission:

```bash
./farm_templates/run_farm_template.sh -v -s simc_prod
```

Diagnose an existing workflow:

```bash
./farm_templates/run_farm_template.sh -d -w my_workflow
```

Rebalance an existing workflow:

```bash
./farm_templates/run_farm_template.sh -r -a -w my_workflow
```

## Customization Checklist

1. Copy the template worker that matches your job shape.
2. Replace the placeholder analysis commands inside the worker script.
3. Point the wrapper at your manifest directory with `-m`.
4. Edit your manifest `worker_args` and `outputs`.
5. Keep SWIF `-output` as the preferred MSS path unless you truly need a manual copy step.

## Framework Config

The template wrapper can be driven from a framework config JSON with `-C`.
That keeps framework-specific details out of the shell wrapper.

Supported top-level fields:

- `workflow_prefix`
- `manifest_dir`
- `manifest_glob`
- `mode`
  `unique` or `variant`
- `worker_script`
- `account`
- `partition`

The config is optional. Command-line flags still override it.

Included examples:

- [framework_config.example.json](c:/Users/trott/Documents/Programs/lt_analysis/farm_templates/framework_config.example.json)
  Generic SIMC-style example
- [framework_config.kaonlt_replay.example.json](c:/Users/trott/Documents/Programs/lt_analysis/farm_templates/framework_config.kaonlt_replay.example.json)
  KaonLT replay-style example
- [framework_config.kaonlt_applycuts.example.json](c:/Users/trott/Documents/Programs/lt_analysis/farm_templates/framework_config.kaonlt_applycuts.example.json)
  KaonLT applyCuts-style example

## Notes

- The diagnose and rebalance template entrypoints reuse the current generic
  helpers from `farm_env/`. If you want a fully detached copy later, copy the
  helper bodies into those template files.
- These templates intentionally avoid ltsep-specific path resolution so they can
  be adapted to non-KaonLT code more easily.
