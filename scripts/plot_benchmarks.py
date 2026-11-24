#!/usr/bin/env python3
"""Gnuplot charts for the timings in benchmark JSON files."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory


METRICS = (
    ("compute_seconds", "Compute only", "#2563EB"),
    ("compute_with_transfer_seconds", "Compute with memory transfers", "#0F766E"),
)


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
        for field, _, _ in METRICS:
            value = result.get(field)
            if type(value) not in (int, float) or not 0 <= value < float("inf"):
                raise ValueError(f"{path}: {field} must be a finite, nonnegative number")
            durations.append(value)
        rows.append((algo, *durations))
    return reference, rows


def plot(gnuplot, reference, rows, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output_dir) as temp_dir:
        workspace = Path(temp_dir)
        data = "".join(
            f"{index} {compute} {with_transfer} {json.dumps(algo, ensure_ascii=False)}\n"
            for index, (algo, compute, with_transfer) in enumerate(rows, start=1)
        )
        (workspace / "benchmarks.dat").write_text(data, encoding="utf-8")
        commands = [
            "set encoding utf8",
            "set terminal pngcairo noenhanced size 1000,600",
            "set xlabel 'Algorithm'",
            "set ylabel 'Time (s)'",
            "set grid ytics",
            "set xtics rotate by -25",
            "set format y '%.3g'",
            "unset key",
            f"set xrange [0.5:{len(rows) + 0.5}]",
            "set yrange [0:*]",
        ]
        filenames = []
        for column, (field, title, color) in enumerate(METRICS, start=2):
            filename = f"{field}.png"
            filenames.append(filename)
            commands.extend((
                f'set title "{title}\\n{reference["nbodies"]} bodies, {reference["steps"]} steps"',
                f"set output '{filename}'",
                f"plot 'benchmarks.dat' using 1:{column}:xticlabels(4) "
                f"with linespoints linewidth 2 pointtype 7 pointsize 1.3 linecolor rgb '{color}'",
                "unset output",
            ))
        subprocess.run(
            [gnuplot], input="\n".join(commands) + "\n", encoding="utf-8", cwd=workspace, check=True
        )
        for filename in filenames:
            destination = output_dir / filename
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
        output_dir = Path(__file__).resolve().parents[1] / "results"
        plot(Path(gnuplot).resolve(), reference, rows, output_dir)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
