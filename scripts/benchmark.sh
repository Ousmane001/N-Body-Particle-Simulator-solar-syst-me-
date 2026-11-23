#!/usr/bin/env bash
# Build the selected engine, run it without a display, and save its JSON summary.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/benchmark.sh <variant> [options]

Variant:
  cpu-sequential
  gpu-naive             requires the CUDA toolkit and an NVIDIA GPU

Options passed to the engine:
  --scenario NAME       default: cluster
  --count N             default for cluster: 1000
  --steps N             default: 20
  --seed N              default: 42
  --dt X               default: 0.001
  --energy-every K      default: 0 (start and end only)
  --max-energy-drift X  optional relative limit, e.g. 0.001 for 0.1%
  --softening X         default: 0.02
  --G X                 default: 1
  --galaxies N          for the merger scenario
  --block-size N        GPU threads per block, default: 256

The JSON summary is written to results/. A run over the energy limit
still produces a summary and exits with status 2.
EOF
}

if (($# == 0)); then
    usage >&2
    exit 1
fi
for argument in "$@"; do
    if [[ "$argument" == "--help" || "$argument" == "-h" ]]; then
        usage
        exit 0
    fi
done

variant=$1
shift
case "$variant" in
    cpu-sequential)
        preset=release
        target=nbody_cpu
        ;;
    gpu-naive)
        preset=cuda
        target=nbody_gpu_naive
        ;;
    *)
        printf 'Unknown benchmark variant: %s\n' "$variant" >&2
        exit 1
        ;;
esac

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
engine_dir="$project_dir/Engine"
build_dir="$project_dir/build/$preset"
results_dir="$project_dir/results"

(
    cd -- "$engine_dir"
    cmake --preset "$preset"
    cmake --build --preset "$preset" --target "$target" --parallel
) >&2

mkdir -p -- "$results_dir"
timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
temporary_file=$(mktemp "$results_dir/.${variant}-${timestamp}-XXXXXX")
trap 'rm -f -- "$temporary_file"' EXIT

status=0
"$build_dir/$target" --scenario cluster --steps 20 "$@" --json > "$temporary_file" || status=$?
if ((status != 0 && status != 2)); then
    exit "$status"
fi

name=${temporary_file##*/}
result="$results_dir/${name#.}.json"
mv -- "$temporary_file" "$result"
cat -- "$result"
printf 'Results saved in -> results/%s\n' "${result##*/}"
exit "$status"
