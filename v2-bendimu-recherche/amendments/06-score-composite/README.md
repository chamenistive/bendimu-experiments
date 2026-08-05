# Amendement 06 — score composite

**Objectif** : remplacer la comparaison p99 seule par un score composite pondéré `score = w_p99·p99 + w_rss·RSS + w_cpu·CPU`.

**Justification** : le classement Istio-vs-Cilium peut basculer si on tient compte du coût mémoire et CPU en plus de la latence. Cet amendement teste la robustesse du verdict Bendimu à différentes fonctions d'utilité.

**Pondérations testées** : (0.7/0.2/0.1), (0.5/0.3/0.2), (0.4/0.4/0.2).

**Sortie** : `results/aisp-*.json` + `results/top-pods.txt` + `results/top-cilium.txt`. Le calcul du score composite est fait dans `04-synthese-v2.py`.
