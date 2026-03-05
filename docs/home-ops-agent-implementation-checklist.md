# Home-Ops Telegram Pi Agent — Implementation-Ready Checklist

## Decisions (locked)

- Telegram ingress: **Webhook**
- Authorization: **single allowed Telegram user**
- `/apply`: always
  1. creates a feature branch,
  2. commits changes,
  3. opens a PR
- PR target branch: **`main`**
- Merge strategy: **Squash**

---

## Phase 1 — Agent runtime (application)

- [x] Build `pi-telegram-home-ops-agent` Node service (single process)
- [x] Use Pi SDK (`createAgentSession`) for agent execution
- [x] Persist one session per chat/thread on disk
- [x] Add webhook endpoint:
  - [x] `POST /telegram/webhook/<secret-path-or-token>`
  - [x] Verify `X-Telegram-Bot-Api-Secret-Token`
- [x] Add Telegram authorization guard:
  - [x] Allow only `TELEGRAM_ALLOWED_USER_ID`
  - [x] Reject all non-authorized users/chats
- [x] Implement command router:
  - [x] `/status`
  - [x] `/plan <task>`
  - [x] `/run <task>` (read-only)
  - [x] `/arm <minutes>`
  - [x] `/apply <task>`
  - [x] `/abort`
- [x] Implement mutating guardrails:
  - [x] Default mode = read-only
  - [x] `/arm` required for writes
  - [x] Arm TTL auto-expiry
- [x] Implement `/apply` workflow:
  - [x] Create branch `agent/<timestamp>-<slug>`
  - [x] Run task via Pi
  - [x] `git add -A`
  - [x] Commit with standardized message
  - [x] Push branch
  - [x] Open PR to `main`
- [x] GitHub auth integration:
  - [x] Implement GitHub App JWT + installation token flow in TypeScript
  - [x] Refresh token only when needed for an operation (and retry on HTTP 401)
  - [x] Export token as `GH_TOKEN` for `gh`
- [x] Response hygiene:
  - [x] Redact secrets from logs/messages
  - [x] Return concise run summary + PR URL

---

## Phase 2 — Containerization

- [ ] Create Dockerfile with non-root runtime
- [ ] Include required tooling:
  - [ ] Node runtime
  - [ ] Pi package (`@mariozechner/pi-coding-agent`)
  - [ ] `gh` CLI
- [ ] Mount repo workspace at `/workspace/home-ops`
- [ ] Persist state at `/data/sessions`
- [ ] Add health endpoints:
  - [ ] `/healthz` (liveness)
  - [ ] `/readyz` (readiness)

---

## Phase 3 — Kubernetes (GitOps in `home-ops`)

- [ ] Add new app under `kubernetes/apps/agents/pi-telegram-home-ops/`
- [ ] Create Flux Kustomization `ks.yaml`
- [ ] Create app manifests:
  - [ ] `app/kustomization.yaml`
  - [ ] `app/helmrelease.yaml`
  - [ ] `app/externalsecret.yaml`
  - [ ] `app/ocirepository.yaml`
- [ ] Expose webhook route:
  - [ ] Hostname `pi.home-ops.${SECRET_EXTERNAL_DOMAIN}`
- [ ] Configure app env in Helm values:
  - [ ] Repo owner/name
  - [ ] Base branch = `main`
  - [ ] Telegram webhook secret
- [ ] Add baseline security context/resources
- [ ] Add persistent storage for `/data` (and workspace cache if needed)
- [ ] Register app in `kubernetes/apps/agents/kustomization.yaml`

---

## Phase 4 — Secret and configuration contract

### ExternalSecret-backed values (from 1Password)

- [ ] `TELEGRAM_BOT_TOKEN`
- [ ] `TELEGRAM_WEBHOOK_SECRET`
- [ ] `TELEGRAM_ALLOWED_USER_ID`
- [ ] `GITHUB_APP_ID`
- [ ] `GITHUB_APP_INSTALLATION_ID` (optional)
- [ ] `GITHUB_APP_PRIVATE_KEY`

### Non-secret config

- [ ] `REPO_OWNER=auricom`
- [ ] `REPO_NAME=home-ops`
- [ ] `REPO_BASE_BRANCH=main`
- [ ] `APPLY_AUTO_PR=true`

---

## Phase 5 — Operational hardening

- [ ] Add per-user rate limiting
- [ ] Add per-task timeout + cancellation
- [ ] Add single in-flight mutation lock
- [ ] Register webhook on startup (`setWebhook`)
- [ ] Validate webhook config (`getWebhookInfo`)
- [ ] Add PR body template for agent-created PRs
- [ ] Run validation gates (`pre-commit run -a`)

---

## Proposed file layout

### Runtime code repository (`auricom/agents`)

```text
agents/
└── pi-telegram-home-ops/
    ├── src/
    │   ├── main.ts
    │   ├── telegram/
    │   │   ├── server.ts
    │   │   ├── verify.ts
    │   │   └── commands.ts
    │   ├── agent/
    │   │   ├── session-manager.ts
    │   │   ├── pi-runner.ts
    │   │   └── policy.ts
    │   ├── git/
    │   │   ├── branch.ts
    │   │   ├── commit.ts
    │   │   ├── pr.ts
    │   │   └── gh-auth.ts
    │   ├── github/
    │   │   └── token-refresh.ts
    │   ├── web/
    │   │   └── health.ts
    │   └── types.ts
    ├── package.json
    ├── tsconfig.json
    ├── Dockerfile
    └── README.md
```

### GitOps repository (`auricom/home-ops`)

```text
kubernetes/apps/agents/pi-telegram-home-ops/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── helmrelease.yaml
    ├── externalsecret.yaml
    └── ocirepository.yaml
```

And add to:

```text
kubernetes/apps/agents/kustomization.yaml
# - ./pi-telegram-home-ops/ks.yaml
```

---

## Notes

- Keep repo assumptions public-safe (no hardcoded real domains/emails/public IPs).
- Continue using `${SECRET_*}` substitutions and External Secrets patterns.
- Do not use or modify `.archive/` content.
