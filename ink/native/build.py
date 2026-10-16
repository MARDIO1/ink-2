"""Build the standalone blue-ink numerical extension (Windows x86_64 / MinGW)."""
from pathlib import Path
import argparse
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--compiler", default=shutil.which("g++") or "C:/mingw64/bin/g++.exe")
args = parser.parse_args()
here = Path(__file__).resolve().parent
subprocess.run([
    args.compiler, "-O3", "-std=c++17", "-ffp-contract=off", "-shared", "-static",
    str(here / "energy_extension.cpp"), "-o", str(here / "ink_energy.dll"),
], check=True, cwd=here)
print(here / "ink_energy.dll")
