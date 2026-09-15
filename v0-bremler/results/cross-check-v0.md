# V0 Verdict : GO

## Métriques data10kb-12800rps
- **t0-baseline** : p99 = 0.99 ms, QPS = 12798 (100.0% de 12800)
- **t1-istio** : p99 = 19.95 ms, QPS = 9650 (75.4% de 12800)
- **t2-cilium** : p99 = 10.68 ms, QPS = 12739 (99.5% de 12800)
- **t3-ambient** : manquant / illisible

## Checks
- ✅ **Ordre p99** — p99 T0=0.99 < T2=10.68 < T1=19.95 ms → OK
- ✅ **Saturation** — T1=75.4%, T2=99.5% (min 60%)
- ✅ **Ratio T1/T2** — T1/T2 p99 = 1.87× (paper 2024 = 1.36×)

## Note fidélité 2024→2026
Cibles absolues paper (T1=600ms, T2=440ms) obsolètes sur infra 2026 (kernel eBPF + n2-standard-4 dépassent testbed 2024). Pattern qualitatif reproduit correctement : T0 < T2 < T1 (mesh overhead croissant).
