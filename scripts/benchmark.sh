#!/usr/bin/env bash
# Benchmark runner for the CPU and GPU variants.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/benchmark.sh <variant> [options]

Variants:
  cpu-naive             Engine/src/cpu/naive.cpp (AoS)
  cpu-coalesced-access  Engine/src/cpu/coalesced_access.cpp
  gpu-naive             Engine/src/gpu/naive.cu (AoS)
  gpu-coalesced-access  Engine/src/gpu/coalesced_access.cu
  gpu-optim             Engine/src/gpu/optim.cu

GPU variants require the CUDA toolkit and an NVIDIA GPU.
All benchmarks use the cluster scenario.

Options passed to the engine:
  --count N             default: 1000
  --steps N             default: 20
  --dt X               default: 0.001
  --energy-every K      default: 0 (start and end only)
  --max-energy-drift X  optional relative limit, e.g. 0.001 for 0.1%
  --block-size N        GPU threads per block, default: 256

Each run replaces results/<variant>.json. A run over the energy limit
still updates the summary and exits with status 2.
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
for argument in "$@"; do
    case "$argument" in
        --scenario|--scenario=*|--galaxies|--galaxies=*)
            printf 'Unsupported option %s. Benchmarks use the cluster scenario.\n' "${argument%%=*}" >&2
            exit 1
            ;;
    esac
done
case "$variant" in
    cpu-naive-aos|gpu-naive-aos)
        variant="${variant%-aos}"
        ;;
    cpu-optim)
        variant=cpu-coalesced-access
        ;;
    gpu-advanced_optim)
        variant=gpu-coalesced-access
        ;;
esac
case "$variant" in
    cpu-coalesced-access)
        target=nbody_cpu
        ;;
    cpu-naive|gpu-naive|gpu-coalesced-access|gpu-optim)
        target="nbody_${variant//-/_}"
        ;;
    *)
        printf 'Unknown benchmark variant: %s\n' "$variant" >&2
        exit 1
        ;;
esac

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
engine_dir="$project_dir/Engine"
build_dir="$project_dir/build"
results_dir="$project_dir/results"

(
    cmake -S "$engine_dir" -B "$build_dir"
    cmake --build "$build_dir" --config Release --target "$target" --parallel
) >&2

mkdir -p -- "$results_dir"
result="$results_dir/${variant}.json"
# We write to a temporary file so a crash leaves the previous JSON in place.
temporary_file=$(mktemp "$results_dir/.${variant}-XXXXXX")
trap 'rm -f -- "$temporary_file"' EXIT

status=0
"$build_dir/$target" --scenario cluster --steps 20 "$@" --json > "$temporary_file" || status=$?
# Exit 2 still has a complete report, even though the energy check failed.
if ((status != 0 && status != 2)); then
    exit "$status"
fi

mv -- "$temporary_file" "$result"
cat -- "$result"
printf 'Results saved in -> results/%s\n' "${result##*/}"
exit "$status"
