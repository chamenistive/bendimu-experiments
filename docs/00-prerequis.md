# 00 — Prérequis Bendimu Experiments

**Objectif :** installer tous les outils locaux nécessaires avant de toucher au cloud. Vérifier avec commandes de contrôle. Zéro pré-requis manquant = zéro échec en cours d'expérimentation.

---

## 1. Système d'exploitation supporté

- **Linux** (Ubuntu 22.04+ recommandé) — testé
- **macOS** 13+ — compatible
- **Windows** — non supporté directement, utiliser WSL2 Ubuntu

## 2. Outils obligatoires

### 2.1 Tableau récapitulatif

| Outil | Version min | Rôle | Vérif |
|---|---|---|---|
| `git` | 2.40+ | Versioning | `git --version` |
| `gcloud` (Google Cloud SDK) | 470+ | Provisioning GCP | `gcloud --version` |
| `kubectl` | 1.30+ | Client Kubernetes | `kubectl version --client` |
| `helm` | 3.14+ | Gestion charts K8s | `helm version` |
| `terraform` | 1.7+ | Infrastructure as Code | `terraform version` |
| `istioctl` | 1.24+ (V1/V2) et 1.22 (V0) | Diag Istio | `istioctl version` |
| `cilium` CLI | 0.16+ | Diag Cilium | `cilium version` |
| `docker` | 25+ | Build images | `docker --version` |
| `jq` | 1.6+ | Traitement JSON | `jq --version` |
| `yq` | 4.40+ | Traitement YAML | `yq --version` |
| `go` | 1.22+ | Rebuild tls_server | `go version` |
| `python` | 3.10+ | Scripts analyse | `python3 --version` |
| `pre-commit` | 3.7+ | Hooks git | `pre-commit --version` |
| `make` | GNU 4+ | Cibles Makefile | `make --version` |
| `openssl` | 3.0+ | Certificats | `openssl version` |
| `curl` | 8+ | HTTP | `curl --version` |
| `openapi-generator-cli` | 7.5+ | Génération stubs PSD2 (V1/V2) | `openapi-generator-cli version` |

### 2.2 Installation Ubuntu 22.04

```bash
# Système
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git make jq openssl python3 python3-pip \
  build-essential gnupg lsb-release apt-transport-https ca-certificates \
  software-properties-common

# gcloud
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
gcloud components install kubectl gke-gcloud-auth-plugin

# kubectl (version explicite)
curl -LO "https://dl.k8s.io/release/v1.30.5/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | \
  sudo tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] \
  https://baltocdn.com/helm/stable/debian/ all main" | \
  sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt update && sudo apt install -y helm

# terraform
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# istioctl — DEUX versions (V0 = 1.22, V1/V2 = 1.24)
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.22.6 sh -
sudo mv istio-1.22.6/bin/istioctl /usr/local/bin/istioctl-1.22
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.0 sh -
sudo mv istio-1.24.0/bin/istioctl /usr/local/bin/istioctl-1.24
sudo ln -sf /usr/local/bin/istioctl-1.24 /usr/local/bin/istioctl

# cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz

# docker
curl -fsSL https://get.docker.com | sudo bash
sudo usermod -aG docker $USER
# → redémarrer session pour prise en compte du groupe

# yq
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq

# go
GO_VERSION=1.22.5
wget https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc

# python packages
pip3 install --user pre-commit detect-secrets pyyaml jsonschema numpy scipy pandas matplotlib

# openapi-generator-cli (via npm — nécessite Node.js)
sudo apt install -y nodejs npm
sudo npm install -g @openapitools/openapi-generator-cli

# pre-commit
pip3 install --user pre-commit
```

### 2.3 Installation macOS

```bash
brew install --cask google-cloud-sdk docker
brew install kubectl helm terraform jq yq go python@3.11 pre-commit make openssl@3 curl
gcloud components install kubectl gke-gcloud-auth-plugin
brew install istioctl cilium-cli
brew install openapi-generator
```

## 3. Vérification globale

Créer `~/check-prereqs.sh` :

```bash
#!/bin/bash
set +e

check() {
  local tool=$1
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "❌ $tool absent"
    return 1
  fi
  local v=$($tool --version 2>&1 | head -1)
  echo "✅ $tool : $v"
}

for t in git gcloud kubectl helm terraform istioctl cilium docker jq yq go python3 pre-commit openssl curl openapi-generator-cli; do
  check "$t"
done
```

```bash
chmod +x ~/check-prereqs.sh && ~/check-prereqs.sh
```

## 4. Ressources système minimum (local)

- **RAM** : 8 GB (kubectl + istioctl + docker + IDE)
- **Disque** : 20 GB libres (images Docker + résultats JSON + logs)
- **Réseau** : latence stable vers `europe-west9.googleapis.com`

Test réseau :
```bash
ping -c 5 europe-west9-a-c.gce-atlantic.googleapis.com
# Latence attendue depuis France/Europe : < 40 ms ; depuis Afrique de l'Ouest : 60–120 ms
```

## 5. Compte GitHub

- Compte GitHub actif
- Clé SSH configurée (`ssh -T git@github.com` doit répondre)
- Repo `bendimu-experiments` créé (**privé recommandé** pour mémoire M2)

## 6. Compte Google Cloud

- Compte Google actif
- **Crédit 300 USD activé** (Free Tier ou promotion)
- Compte de facturation lié
- Accès Console GCP fonctionnel (`https://console.cloud.google.com`)

Détails setup GCP : voir [01-setup-gcp.md](01-setup-gcp.md).

## 7. Éditeur recommandé

- **VSCode** avec extensions :
  - HashiCorp Terraform
  - Kubernetes
  - YAML (Red Hat)
  - GitLens
  - Python
  - Docker

## 8. Checklist finale avant de continuer

- [ ] Tous les outils du tableau 2.1 installés et versions vérifiées
- [ ] `docker ps` fonctionne sans sudo (redémarrer session si besoin)
- [ ] `gcloud auth list` liste au moins un compte
- [ ] SSH GitHub OK (`ssh -T git@github.com`)
- [ ] 8 GB RAM libres, 20 GB disque libres
- [ ] Compte GCP avec 300 USD de crédit visible dans Console
- [ ] Repo GitHub `bendimu-experiments` créé (vide, privé)

**Si toutes cases cochées → passer à [01-setup-gcp.md](01-setup-gcp.md).**
