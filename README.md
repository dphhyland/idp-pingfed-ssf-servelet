# SSF transmitter demo — PingFederate + Identity Object Model store

A self-contained docker-compose demo of the **pf-oidf-modules SSF (Shared Signals Framework 1.0)
transmitter** running inside a real PingFederate 13.0.3, persisting its state in the **ID Partners
Identity Object Model** (`idp-scim-service`) as Postgres JSONB object-class entries.

```
┌────────────────────────────┐         ┌──────────────────────────────┐
│ pingfederate (:19031/:19999)│  JDBC   │ ldm-store (postgres:16, :55432)│
│  pf-runtime.war ⟵ merged:  │────────▶│  idm.entry — ssfStream /      │
│   • SSF servlets (root ctx) │         │  ssfStreamSubject /           │
│   • LogoutEventFilter       │         │  ssfPendingSet entries        │
│   • postgres JDBC driver    │         │  (schema + SSF migration      │
│  licensing: DevOps-fetched  │         │   applied on init)            │
└────────────────────────────┘         └──────────────────────────────┘
```

## Run it

```sh
cp .env.example .env        # fill in your Ping DevOps credentials (licensing)
docker compose up -d --build
./scripts/bootstrap-pf.sh   # one-time: license agreement, admin, ATM, mapping, ssf.manage scope, receiver client
./scripts/probe-demo.sh     # the end-to-end walk
```

Then open the **demo UI**: http://localhost:18080 — a single-page walk (metadata → stream → SCIM
subject → events → poll → loopback push→receiver) through a thin proxy that injects the `ssf.manage`
bearer; the browser never handles credentials. PF admin console: https://localhost:19999/pingfederate/app.

The probe proves, in order: transmitter metadata → PF-issued bearer (client_credentials `ssf.manage`,
validated by RFC 7662 introspection) → stream CRUD → **SCIM provisioning drives stream subjects** →
verification SET minted/polled/ack'd → **PF logout emits a signed `caep.session-revoked` SET**
(`LogoutEventFilter` over `/idp/init_logout.openid`) → **SCIM disable emits `risc.account-disabled`** →
the state lives in `idm.entry` (peek: `docker compose exec ldm-store psql -U ldm -d ldm`) → **a PF
restart loses nothing** (durability is Postgres's) → poll-ack semantics.

## What's in the box

| Piece | Detail |
|---|---|
| `pf/Dockerfile` | Stock PF 13.0.3 + the module **merged into `pf-runtime.war`** (root context; the SSF logout filter registered in its web.xml by `assemble-pf-runtime-war.sh`) + the Postgres JDBC driver. No baked license — DevOps-fetched at boot. |
| `ldm-store/init/` | `01` = the Identity Object Model DDL (from `idp-scim-service/spec`), `02` = the `0001-add-shared-signals-ssf` migration (classes `ssfStream`/`ssfStreamSubject`/`ssfPendingSet`, vocabularies, queue indexes). Applied on first `up`. |
| `scripts/bootstrap-pf.sh` | Stock-PF first-run gates (license agreement + initial admin — the image's `83-configure-admin` hook is never invoked in STANDALONE mode, so this does its job) + OAuth config via the admin API. Idempotent. |
| `scripts/probe-demo.sh` | The 10-stage end-to-end verification. |

SSF configuration is **pure env** (`OIDF_SSF_*` in `docker-compose.yml`): issuer, `storeDialect=ldm`,
direct JDBC URL, and the introspection client. No web.xml edits, no PF console clicking for the SSF side.

## Gotchas encountered (so you don't re-hit them)

- **Don't bundle jose4j into `pf-runtime.war`** — PF ships its own on the server classpath; a second copy
  in `WEB-INF/lib` causes a `LinkageError` (loader constraint violation) the moment PF-loaded jose4j types
  cross into module code. The assemble script's jose4j arg is `-` (skip) for merged-war builds.
- **JDBC drivers in `WEB-INF/lib` need explicit loading** — `DriverManager` only auto-registers drivers
  from the system classpath; the store factory `Class.forName`s the driver from its own classloader.
- **Stock-PF first run**: accept `/license/agreement` then `POST /administrativeAccounts` (unauthenticated,
  one-shot). Probe the API **unauthenticated** while waiting — repeated failed Basic auth locks the fresh
  admin account for ~1 minute.
- Admin console: https://localhost:19999/pingfederate/app (administrator / 2FederateM0re).
