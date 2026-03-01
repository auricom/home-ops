# AGENTS.md - AI Assistant Guidance for home-ops

## CRITICAL: Treat This Repo As Public

Assume this repository is publicly accessible. Do not commit or propose changes that introduce personally identifiable information or sensitive infrastructure details.

### PII Protection Rules

Never commit any of the following:

| Prohibited | Use Instead | Example |
| --- | --- | --- |
| Real names | Pseudonyms or variables | `${USERNAME}` |
| Email addresses | Secret variables | `${SECRET_CLUSTER_DOMAIN_EMAIL}` |
| Public hostnames/domains | Secret variables | `app.${SECRET_EXTERNAL_DOMAIN}` |
| Public IP addresses | SOPS secret variables (add a `SECRET_*` entry) | `${SECRET_PUBLIC_IP}` |
| Private domain names | `SECRET_*` variables | `${SECRET_INTERNAL_DOMAIN}` |

Allowed in this repository:
- RFC1918 IP addresses (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
- Hostnames used only inside the cluster (e.g. `svc.cluster.local`)
- Hardware model names and non-sensitive vendor references

### Secret and Variable Reference

All sensitive values are stored in SOPS-encrypted secrets and injected via Flux or External Secrets. Prefer these variables instead of hardcoding:

| Variable | Purpose | Location |
| --- | --- | --- |
| `${SECRET_DOMAIN}` | Base domain for email or app config | `kubernetes/components/common/vars/cluster-secrets.sops.yaml` |
| `${SECRET_EXTERNAL_DOMAIN}` | Public ingress domain | `kubernetes/components/common/vars/cluster-secrets.sops.yaml` |
| `${SECRET_INTERNAL_DOMAIN}` | Internal DNS domain | `kubernetes/components/common/vars/cluster-secrets.sops.yaml` |
| `${SECRET_CLUSTER_DOMAIN_EMAIL}` | ACME/cluster email | `kubernetes/components/common/vars/cluster-secrets.sops.yaml` |
| `${SECRET_CLOUDFLARE_TUNNEL_ID}` | Cloudflare Tunnel ID | `kubernetes/components/common/vars/cluster-secrets.sops.yaml` |

Non-secret cluster values (e.g. load balancer IPs, time zone, CIDRs) live in `kubernetes/components/common/vars/cluster-settings.yaml`.

### Secret Handling Rules

- Encrypt all secrets with SOPS following `.sops.yaml` rules.
- Use `*.sops.yaml` (or other `*.sops.*`) for Kubernetes, Ansible, and Terraform secrets.
- Do not commit plaintext secrets or credentials anywhere.
- App secrets should use External Secrets with `ClusterSecretStore` named `onepassword-connect`.

## CRITICAL CONTEXT

This repository manages home infrastructure as code.

- Kubernetes GitOps is managed by Flux.
- Cluster OS and provisioning are managed by Talos Linux.
- Ansible manages auxiliary hosts (NAS, appliances, etc.).
- Renovate automates dependency updates.

## BEHAVIORAL GUIDELINES

1. Research existing patterns before proposing changes.
2. Preserve current functionality unless explicitly asked to remove it.
3. Keep GitOps as the source of truth. Avoid `kubectl apply` outside documented bootstrap flows.
4. Prefer existing patterns for HelmRelease, Kustomization, ExternalSecret, and Gateway API resources.
5. Keep security tight. Do not add `privileged`, `hostNetwork`, or `runAsUser: 0` without a clear need.
6. Validate changes locally when possible and call out any gaps.
7. Always ignore the `.archive/` folder when making or proposing changes.

## ANTI-PATTERNS

- Hardcoding domains, emails, API keys, or public IPs.
- Adding secrets to non-SOPS files.
- Introducing manual, out-of-band cluster changes.
- Diverging from existing namespace/app layouts without justification.

## SECURITY BASELINE

Use least privilege defaults when adding new workloads:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  readOnlyRootFilesystem: true
```

Add resource requests/limits unless there is a strong reason not to:

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
```

## REPOSITORY STRUCTURE

```
ansible/                    # Host automation (NAS/appliance playbooks)
docs/                       # Operational documentation
kubernetes/                 # Flux GitOps manifests
kubernetes/apps/            # Namespaced app deployments
kubernetes/bootstrap/       # Bootstrap manifests and Helmfile
kubernetes/components/      # Reusable Kustomize components
kubernetes/flux/            # Flux system config
kubernetes/talos/           # Talos cluster config (talhelper inputs)
kubernetes/talos_new/       # Experimental Talos config
scripts/                    # Talos helper scripts
.justfile + .just/          # Task automation (bootstrap, talos, kube)
```

## OPERATIONS AND VALIDATION

- Discover tasks with `just --list` and `just --list <module>`.
- Bootstrap flow lives in `.just/bootstrap.just` and `kubernetes/bootstrap/README.md`.
- Talos render/apply is automated in `.just/talos.just` and `scripts/`.
- Run `pre-commit run -a` before submitting changes when possible.

## REMEMBER

1. Treat this repo as public.
2. Keep secrets in SOPS or External Secrets, never plaintext.
3. Use `${SECRET_*}` variables for domains, emails, and external identifiers.
4. Follow existing Flux and Gateway API patterns.
5. Prefer `just` tasks over manual command sequences.
