#!/usr/bin/env python3
"""Export or check the accepted implementation ABIs without third-party Python packages."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if an exported ABI differs from the compiled source")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    mismatches = []
    for name in ("LaunchToken", "Game"):
        result = subprocess.run(
            ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
            cwd=root, check=True, capture_output=True, text=True,
        )
        abi = json.loads(result.stdout)
        if not isinstance(abi, list) or not abi:
            raise ValueError(f"Empty or invalid ABI for {name}")
        expected = json.dumps(abi, indent=2) + "\n"
        path = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not path.is_file() or path.read_text() != expected:
                mismatches.append(str(path.relative_to(root)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(expected)
            print(f"Exported {path.relative_to(root)}")
    if mismatches:
        print("ABI export is stale: " + ", ".join(mismatches), file=sys.stderr)
        return 1
    if args.check:
        print("Both ABI exports match the compiled implementation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
