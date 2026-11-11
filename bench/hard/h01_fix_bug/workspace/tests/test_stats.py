import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from calc.stats import mean, median, spread

failures = []


def check(name, got, want):
    if got != want:
        failures.append(f"{name}: got {got}, want {want}")


check("mean", mean([1, 2, 3, 4]), 2.5)
check("median odd", median([3, 1, 2]), 2)
check("median even", median([4, 1, 3, 2]), 2.5)
check("spread", spread([5, 1, 9]), 8)

for failure in failures:
    print("FAIL", failure)
print("ok" if not failures else f"{len(failures)} failed")
sys.exit(1 if failures else 0)
