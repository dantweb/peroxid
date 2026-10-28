# HydroXid project

A client storefront built **on top of** [`oxid-fe-user`](https://github.com/dantweb/oxid-fe-user):

```
oxid-fe-core   internal library
   ↑
oxid-fe-user   the storefront application (shop, checkout, payments, dashboard, …)
   ↑
peroxid            ← this repository: depends on oxid-fe-user, adds its own plugins, themes, instances
```

| What                      | Where                                                                                                                                                   |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App shell                 | `src/main.ts` — `startStorefront({ plugins })` from `@dantweb/oxid-fe-user/bootstrap`                                                                   |
| Plugin that **overrides** | `plugins/dashboard-override` — same name as the bundled `dashboard`, so it replaces it (extends the original)                                           |
| **Extends peroxid**       | `plugins/hydroxid` — the `peroxid` layout plugin of oxid-fe-user (header with the shop plugin's search box, front page) plus HydroXid's footer and copy |
| **GDPR cookie consent**   | `plugins/gdpr-cookie-consent` — a standalone plugin (dialog, categories, Consent Mode v2, re-open link)                                                 |
| Themes (own fonts)        | children of the **`peroxid` theme**: `hydroxid-vibrant` (Poppins) · `hydroxid-dark-ocean` (IBM Plex Sans) · `hydroxid-light-red` (Playfair + Lato)      |
| Instances (one per theme) | `instances/<name>/oxid-config.yaml` — **server-side only, never served**                                                                                |
| Ports                     | `deploy/instances.json`                                                                                                                                 |

## Run it on localhost

```bash
make local        # needs the OXID SDK shop running (http://localhost.local) and Docker
```

| Theme                 | URL                   | pay1.oxid.dev port |
| --------------------- | --------------------- | ------------------ |
| `hydroxid-vibrant`    | http://localhost:8101 | 2053               |
| `hydroxid-dark-ocean` | http://localhost:8102 | 2083               |
| `hydroxid-light-red`  | http://localhost:8103 | 8443               |

(`pay1.oxid.dev` sits behind Cloudflare, which proxies only a fixed set of HTTPS ports — 2053, 2083
and 8443 are three of them.) Development with hot reload: `INSTANCE=dark-ocean npm run dev`
→ http://localhost:5273.

## Quality gate

```bash
make check        # lint · types · knip (dead code) · unit tests · npm audit
make e2e          # Playwright per instance against `vite preview`, shop API mocked
```

CI (`.github/workflows/ci.yml`) runs the same on every push and pull request; the e2e job is a
matrix over the three instances. **Deployment** is a separate, manual workflow
(`deploy.yml`) — see [docs/ci.md](docs/ci.md).

## Security rule

`oxid-config.yaml` is a deployment file. It is **never served**: the browser gets
`/oxid-config.json`, rendered from it with an allow-list, and the renderer refuses anything that
looks like a secret (`@dantweb/oxid-fe-user`, `docs/instance-configuration.md`). Everything under
`plugins.*.config` is public — keep keys out of it. The build also fails if a YAML ends up in `dist/`.

Conference demo — change a translation, deploy, the open page updates itself: [docs/demo-localisation.md](docs/demo-localisation.md)

More: [docs/architecture.md](docs/architecture.md) · [docs/gdpr-cookie-consent.md](docs/gdpr-cookie-consent.md) ·
[docs/themes.md](docs/themes.md) · [docs/ci.md](docs/ci.md)
