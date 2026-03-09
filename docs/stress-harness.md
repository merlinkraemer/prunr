## Stress Harness

Use the project-owned harness to generate a deterministic synthetic tree for large-path scan verification.

### Create a dataset

```bash
make stress-create STRESS_ROOT="$PWD/tmp/stress-tree" STRESS_FILES=250000 STRESS_FILE_SIZE=4096 STRESS_FANOUT=250
```

### Inspect the dataset

```bash
make stress-stats STRESS_ROOT="$PWD/tmp/stress-tree"
```

### Mutate part of the dataset

```bash
make stress-mutate STRESS_ROOT="$PWD/tmp/stress-tree" STRESS_MUTATE_COUNT=5000 STRESS_MUTATE_BYTES=1048576
```

### Run a non-UI production scan

The built `Prunr` binary now supports a headless stress mode that runs the real production scan path against the dataset and writes JSON results under `tmp/stress-results/runs/`.

Baseline/full scan:

```bash
make stress-scan STRESS_ROOT="$PWD/tmp/stress-tree" STRESS_RESULTS_ROOT="$PWD/tmp/stress-results"
```

Unchanged repeat scan:

```bash
make stress-repeat STRESS_ROOT="$PWD/tmp/stress-tree" STRESS_RESULTS_ROOT="$PWD/tmp/stress-results" STRESS_EXPECT_UNCHANGED=1 STRESS_RUN_LABEL=unchanged-repeat
```

Mutated repeat scan:

```bash
make stress-repeat STRESS_ROOT="$PWD/tmp/stress-tree" STRESS_RESULTS_ROOT="$PWD/tmp/stress-results" STRESS_EXPECT_UNCHANGED=0 STRESS_RUN_LABEL=mutated-repeat
```

Aggregate report:

```bash
make stress-report STRESS_RESULTS_ROOT="$PWD/tmp/stress-results"
```

Each run JSON records:

- dataset path
- snapshot IDs
- wall-clock duration
- delta count
- total growth bytes
- false-growth bytes for unchanged repeats
- DB file size before/after

### Remove the dataset

```bash
make stress-clean STRESS_ROOT="$PWD/tmp/stress-tree"
```

### Suggested verification flow

1. `make build`
2. `make test`
3. `make stress-create ...`
4. `make stress-scan ...`
5. `make stress-repeat ... STRESS_EXPECT_UNCHANGED=1 STRESS_RUN_LABEL=unchanged-repeat`
6. `make stress-mutate ...`
7. `make stress-repeat ... STRESS_EXPECT_UNCHANGED=0 STRESS_RUN_LABEL=mutated-repeat`
8. `make stress-report ...`
