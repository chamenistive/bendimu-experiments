#!/usr/bin/env python3
"""V1 synthèse — évalue H1 (réseau) et H2 (applicatif) depuis T0..T3."""

import json
import pathlib
from statistics import mean

BASE = pathlib.Path(__file__).resolve().parents[1] / "results"
DELAYS_FIXED_MS = {"aisp": 100, "authorize": 200, "execute": 400}
ENDPOINTS = list(DELAYS_FIXED_MS.keys())
PHASES = ["t0-baseline-reseau", "t1-baseline-appli", "t2-istio-mtls", "t3-cilium-mtls"]

def p99_ms(path: pathlib.Path):
    try:
        d = json.loads(path.read_text())
        return d["DurationHistogram"]["Percentiles"][-1]["Value"] * 1000
    except Exception:
        return None

def collect(phase: str, endpoint: str) -> dict[int, float]:
    """Retourne {rps: p99_ms} pour un endpoint dans une phase."""
    out = {}
    for f in (BASE / phase).glob(f"{endpoint}-*rps.json"):
        rps = int(f.stem.split("-")[1].replace("rps", ""))
        p99 = p99_ms(f)
        if p99 is not None:
            out[rps] = p99
    return out

def main():
    print("=== V1 Synthèse H1 (réseau) + H2 (applicatif) ===\n")

    md = ["# Synthèse V1 Bendimu\n"]

    # H1 — Δ réseau Istio vs Cilium par endpoint à 12800 RPS
    md.append("\n## H1 — Δ réseau Istio vs Cilium (RPS=12800)\n")
    md.append("| Endpoint | Istio p99 (ms) | Cilium p99 (ms) | Δ (ms) | H1 |")
    md.append("|---|---|---|---|---|")

    h1_verdicts = []
    for ep in ENDPOINTS:
        istio_map = collect("t2-istio-mtls", ep)
        cilium_map = collect("t3-cilium-mtls", ep)
        i99 = istio_map.get(12800)
        c99 = cilium_map.get(12800)
        if i99 is None or c99 is None:
            md.append(f"| {ep} | N/A | N/A | N/A | 🟡 données manquantes |")
            continue
        delta = i99 - c99
        h1_ok = delta > 5  # Cilium < Istio d'au moins 5 ms = H1 validée
        h1_verdicts.append(h1_ok)
        md.append(f"| {ep} | {i99:.1f} | {c99:.1f} | {delta:+.1f} | {'✅' if h1_ok else '❌'} |")

    # H2 — overhead applicatif mesh par endpoint
    md.append("\n## H2 — Overhead applicatif mesh (isolé du délai fixe)\n")
    md.append("| Endpoint | Δ = p99 - délai fixe (Istio) | Δ = p99 - délai fixe (Cilium) |")
    md.append("|---|---|---|")

    for ep in ENDPOINTS:
        d = DELAYS_FIXED_MS[ep]
        i99 = collect("t2-istio-mtls", ep).get(12800)
        c99 = collect("t3-cilium-mtls", ep).get(12800)
        if i99 is None or c99 is None:
            md.append(f"| {ep} | N/A | N/A |")
            continue
        md.append(f"| {ep} | {i99 - d:+.1f} ms | {c99 - d:+.1f} ms |")

    # Verdict
    n_ok = sum(1 for v in h1_verdicts if v)
    h1_verdict = "validée" if n_ok >= 2 else "réfutée"
    md.append(f"\n**Verdict H1 :** {h1_verdict} ({n_ok}/{len(h1_verdicts)} endpoints)")
    md.append("**Verdict H2 :** dépend interprétation domaine (voir docs/03 §1)")

    out = BASE / "synthese-v1.md"
    out.write_text("\n".join(md))
    print("\n".join(md))
    print(f"\n➡ Écrit : {out}")

if __name__ == "__main__":
    main()
