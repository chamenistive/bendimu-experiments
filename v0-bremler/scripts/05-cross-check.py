#!/usr/bin/env python3
"""V0 cross-check — compare résultats T0/T1/T2/T3 aux cibles Bremler-Barr 2024.
Exit 0 = GO (V1 autorisé). Exit 1 = NO-GO."""

import json
import pathlib
import sys
from typing import Optional, Tuple

BASE = pathlib.Path(__file__).resolve().parents[1] / "results"
TARGETS_P99_MS_DATA10KB = {
    "t1-istio": 600,
    "t2-cilium": 440,
    "t3-ambient": 500,   # optionnel
}
TOL_P99 = 0.15    # ±15 %
TOL_MEM = 0.20    # ±20 %

def load_json(path: pathlib.Path):
    try:
        return json.loads(path.read_text())
    except Exception as e:
        return {"error": str(e)}

def p99_of(fortio_json: dict) -> Optional[float]:
    """Extrait p99 (ms) d'un JSON Fortio load."""
    try:
        return fortio_json["DurationHistogram"]["Percentiles"][-1]["Value"] * 1000
    except (KeyError, IndexError, TypeError):
        return None

def check_phase(phase: str, target_p99: float) -> Tuple[bool, str]:
    f = BASE / phase / "data10kb-12800rps.json"
    if not f.exists():
        return False, f"{phase}: résultat manquant ({f.name})"
    data = load_json(f)
    p99 = p99_of(data)
    if p99 is None:
        return False, f"{phase}: p99 illisible dans JSON"
    delta = (p99 - target_p99) / target_p99
    ok = abs(delta) <= TOL_P99
    tag = "✅" if ok else "❌"
    return ok, f"{tag} {phase}: p99={p99:.1f} ms (target {target_p99}, Δ {delta*100:+.1f}%)"

def main() -> int:
    print("=== V0 Cross-check vs Bremler-Barr 2024 ===\n")
    results = []
    all_ok = True
    for phase, target in TARGETS_P99_MS_DATA10KB.items():
        # T3 ambient optionnel : ne fait pas échouer V0
        ok, msg = check_phase(phase, target)
        print(msg)
        if phase != "t3-ambient":
            all_ok = all_ok and ok
        results.append((phase, ok, msg))
    print()

    verdict = "GO" if all_ok else "NO-GO"
    summary = f"# V0 Verdict : {verdict}\n\n"
    for phase, ok, msg in results:
        summary += f"- {msg}\n"
    (BASE / "cross-check-v0.md").write_text(summary)

    print(f"\n➡ V0 verdict : {verdict}")
    if not all_ok:
        print("   Investiguer avant V1. Voir docs/05-troubleshooting.md.")
        return 1
    print("   Passer à V1 : ../../v1-bendimu/scripts/00-provision.sh")
    return 0

if __name__ == "__main__":
    sys.exit(main())
