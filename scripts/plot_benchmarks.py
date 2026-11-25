#!/usr/bin/env python3
"""Gnuplot charts for the timings in benchmark JSON files."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory


METRICS = ("compute_seconds", "compute_with_transfer_seconds")
COLORS = {
    "cpu-naive": "#1D4ED8",
    "cpu-coalesced-access": "#087F9B",
    "cpu-direct-soa": "#1E3A8A",
    "cpu-naive-aos": "#4F46E5",
    "cpu-optim": "#0369A1",
    "gpu-naive": "#B45309",
    "gpu-coalesced-access": "#C2410C",
    "gpu-optim": "#BE185D",
    "gpu-advanced-optim": "#9D174D",
    "gpu-direct-soa": "#9A3412",
    "gpu-naive-aos": "#854D0E",
    "gpu-advanced_optim": "#9F1239",
}


def load_results(paths):
    reference = {}
    rows = []
    for path in paths:
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise ValueError(f"{path}: could not read benchmark JSON ({error})") from error
        if not isinstance(result, dict):
            raise ValueError(f"{path}: expected a JSON object")

        # The first file sets the comparison size for the other runs.
        for field in ("nbodies", "steps"):
            value = result.get(field)
            if type(value) is not int or value < 1:
                raise ValueError(f"{path}: {field} must be a positive integer")
            expected = reference.setdefault(field, value)
            if value != expected:
                raise ValueError(
                    f"{path}: {field}={value}, expected {expected} (from {paths[0]})"
                )

        algo = result.get("algo")
        if not isinstance(algo, str) or not algo.strip():
            raise ValueError(f"{path}: algo must be a nonempty string")
        durations = []
        for field in METRICS:
            value = result.get(field)
            if type(value) not in (int, float) or not 0 <= value < float("inf"):
                raise ValueError(f"{path}: {field} must be a finite, nonnegative number")
            durations.append(value)
        rows.append((path.stem, algo, *durations))
    return reference, rows


def plot(gnuplot, reference, rows, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    # A common scale makes it easier to compare the curves across images.
    y_max = max(max(compute, with_transfer) for _, _, compute, with_transfer in rows)
    with TemporaryDirectory(dir=output_dir) as temp_dir:
        workspace = Path(temp_dir)
        commands = [
            "set encoding utf8",
            "set terminal pngcairo noenhanced size 1000,600 font ',13'",
            f"set title '{reference['nbodies']} bodies, {reference['steps']} steps'",
            "set ylabel 'Time (s)'",
            "set grid ytics linecolor rgb '#E2E8F0'",
            "set xtics ('Compute only' 0, 'With memory transfers' 1)",
            "set format y '%.4g'",
            "set key outside top center",
            "set xrange [-0.25:1.25]",
            f"set yrange [0:{y_max or 1.0}]",
            "set offsets graph 0, graph 0, graph 0.15, graph 0",
        ]
        filenames = {}
        used = set()
        for index, (stem, algo, compute, with_transfer) in enumerate(rows, start=1):
            name = f"{stem}.png"
            suffix = 2
            while name in used:
                name = f"{stem}-{suffix}.png"
                suffix += 1
            used.add(name)
            filenames[f"{index}.png"] = name

            color = COLORS.get(algo, "#475569")
            # The algorithm name goes in the data header for the line legend.
            data = f"mode {json.dumps(algo, ensure_ascii=False)}\n0 {compute}\n1 {with_transfer}\n"
            (workspace / f"{index}.dat").write_text(data, encoding="utf-8")
            commands.extend((
                f"set output '{index}.png'",
                f"plot '{index}.dat' using 1:2 with linespoints linewidth 3 pointtype 7 "
                f"pointsize 1.5 linecolor rgb '{color}' title columnhead(2), "
                f"\"\" using 1:2:(sprintf('%.4g s', $2)) with labels offset 0,1.3 "
                f"textcolor rgb '{color}' notitle",
                "unset output",
            ))
        subprocess.run(
            [gnuplot], input="\n".join(commands) + "\n", encoding="utf-8", cwd=workspace, check=True
        )
        for filename, name in filenames.items():
            destination = output_dir / name
            (workspace / filename).replace(destination)
            print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_files", nargs="+", type=Path, help="benchmark JSON summaries to compare")
    args = parser.parse_args()
    try:
        reference, rows = load_results(args.json_files)
        gnuplot = shutil.which("gnuplot")
        if not gnuplot:
            parser.error(
                "gnuplot not found. Install it with 'brew install gnuplot' on macOS "
                "or 'sudo apt install gnuplot' on Debian/Ubuntu."
            )
        output_dir = Path(__file__).resolve().parents[1] / "results" / "plots"
        plot(Path(gnuplot).resolve(), reference, rows, output_dir)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
