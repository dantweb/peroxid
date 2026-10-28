# CI and deployment

## CI (`.github/workflows/ci.yml`) — every push and pull request

1. **Quality gate:** lint (+prettier) · `vue-tsc` · knip (dead code) · unit tests · `npm audit` (no
   package with a known advisory) · build (themes → app → rendered instance configs → nginx configs)
   · a check that **no YAML is in the build output**.
2. **E2E matrix** over the three instances (Playwright, `vite preview`, shop API mocked): consent
   dialog, the peroxid-extending plugin, overriding dashboard, the instance's theme and webfont.

### Secrets for CI

`oxid-fe-core` and `oxid-fe-user` are private repositories installed over git+ssh. Each has a
**read-only deploy key**; the private halves are repository secrets here:

| Secret            | Purpose                               |
| ----------------- | ------------------------------------- |
| `CORE_DEPLOY_KEY` | read access to `dantweb/oxid-fe-core` |
| `USER_DEPLOY_KEY` | read access to `dantweb/oxid-fe-user` |

## Playwright traces hold secrets

`retain-on-failure` traces, videos and `error-context.md` under `test-results/` keep the bearer
token, the live-shop login (`SHOP_USER`/`SHOP_PASSWORD`) and everything typed into forms. On a
shared machine delete `test-results/` after a failed live run; CI uploads only the mocked suite's
report and must never upload traces of a live run.

## Deployment (`.github/workflows/deploy.yml`) — manual only

Target: `pay1.oxid.dev`, directory `/var/www/oxid/oxid75/peroxid`:

```
peroxid/
├── releases/<commit-sha>/   dist/  build/instances/  build/nginx-pay1.conf   (the five newest are kept)
└── current  →  releases/<sha>                                                  (atomic switch)
```

**Who writes what.** The project folder is written **only by the CI user `github-actions`** — never by
root. A person with root runs `deploy/server-setup.sh` **once** (outside the folder): it creates a
self-signed origin certificate (Cloudflare reaches custom ports over TLS in "Full" mode, **525**
without), and installs `/etc/nginx/conf.d/peroxid.conf`, a root-owned one-liner that
`include`s `…/peroxid/current/build/nginx-pay1.conf` — the server blocks ship with each release.

**Rename from `hydroxid-project`.** Run `deploy/server-setup.sh` once more as root, then deploy: the
script moves `/var/www/oxid/oxid75/hydroxid-project` and `/etc/ssl/hydroxid` to their `peroxid` names,
removes `/etc/nginx/conf.d/hydroxid-project.conf` and leaves symlinks at the old paths so the live
release keeps serving. After the next deploy the symlinks can be removed
(`rm /var/www/oxid/oxid75/hydroxid-project /etc/ssl/hydroxid`).

`workflow_dispatch` with the input `deploy`, in the `pay1` environment. It repeats the gate, builds and
ships over SSH as `github-actions` (`deploy/deploy.sh`), then `deploy/remote-activate.sh` switches
`current` atomically, reloads nginx through the CI user's single sudo rule
(`/etc/sudoers.d/github-actions-nginx`: `nginx -s reload`), health-checks every port and **rolls back**
to the previous release (and reloads) if nginx did not come up. Finally the workflow smoke-tests all
three ports (config JSON served, YAML 404).

| Port on pay1.oxid.dev | Theme                 |
| --------------------- | --------------------- |
| 2053                  | `hydroxid-vibrant`    |
| 2083                  | `hydroxid-dark-ocean` |
| 8443                  | `hydroxid-light-red`  |

nginx on pay1 listens on these origin ports with TLS and proxies `/graphql/` to the shop's apache on
`127.0.0.1:8543`.

### Secrets and variables for the deployment (environment `pay1`)

| Name                 | Kind     | Value                                          |
| -------------------- | -------- | ---------------------------------------------- |
| `DEPLOY_SSH_KEY`     | secret   | private key authorised on the server           |
| `DEPLOY_HOST`        | variable | `85.236.47.72`                                 |
| `DEPLOY_USER`        | variable | `root` (nginx reload and `/etc/nginx` need it) |
| `DEPLOY_KNOWN_HOSTS` | variable | the server's pinned host key (`ssh-keyscan`)   |

### Access logs carry no query string (sprint 138d)

A provider's return URL carries `session_id` / `PayerID` / `token`, a password-reset link a `uid`. The
instance blocks therefore log with `log_format headless` (`$remote_addr - [$time_local] "$request_method $uri
$server_protocol" $status $body_bytes_sent`): the path only, no query string, no referer. Every
`access_log` of `build/nginx-pay1.conf` (written to `/var/log/nginx/peroxid.access.log`) uses it;
`tests/unit/nginx.spec.ts` renders the config and fails on `$request`, `$request_uri`, `$args`,
`$query_string` or `$http_referer`.

**Host-level nginx in front.** If another nginx (or Cloudflare's origin logging, a load balancer) sits in front
of these ports, its own `access_log` must drop the query string too — a `log_format` with `$uri` instead of
`$request`. That config is outside this repository; its owner (server administration) has to make the change.
Check: `sudo grep -rnE 'log_format|access_log' /etc/nginx/` and `sudo grep -c 'session_id=\|PayerID=\|uid=' <log>`
must print `0` for the logs written after the change.

### The shop on pay1 (GraphQL)

The frontends call the shop's GraphQL API at `/graphql/` (nginx proxies it to the shop's apache on
`127.0.0.1:8543`). The pay1 shop needs the GraphQL storefront; its `composer.json` `require` has:

```json
"thecodingmachine/graphqlite": "^7.0",
"oxid-esales/graphql-base": "dev-b-7.4.x",
"oxid-esales/graphql-storefront": "dev-b-7.4.x"
```

- **Why `graphqlite ^7.0`:** every `graphql-base` (also v13) requires `^7`, and under graphqlite 8 the
  storefront controllers are not discovered (the schema shows only `dummyQuery`, and PHP deprecation
  notices land inside the JSON). Upstream `payment-base` itself requires no graphqlite. The earlier root
  pin `^8.3` was therefore replaced; the change is a small downgrade (graphqlite 8.3.1 → 7.0.0 and its
  helpers) with no advisories (`composer update` reports none).
- After `composer update`: `oe:module:install` and `oe:module:activate` for `oe_graphql_base` and
  `oe_graphql_storefront`, `oe:graphql:cache-clear`, delete `var/cache/container/container_cache_shop_1.php`.
- Backups of the previous files: `composer.json.bak-20261016-graphql`, `composer.lock.bak-20261016-graphql`.
- Proof: `LIVE=1 E2E_BASE_URL=https://pay1.oxid.dev:2053 SHOP_USER=… SHOP_PASSWORD=… npx playwright test live` — catalogue, sign-in,
  account greeting, checkout (all three ports).

### Updating the shop on pay1 (sprint 139a, 138b, 138d)

GraphQLite's schema is cached on the file system and never cleared by itself: a module update that adds a
query (`paymentClientConfig`, …) can leave the old schema live and answer `Cannot query field
"paymentClientConfig"`. Run these steps, in this order, from the shop root on pay1 after **every** shop
update:

1. `composer update` (the modules' new versions; read its advisory output, never waive one).
2. Re-activate the modules: `vendor/bin/oe-console oe:module:install-configuration` where the module
   configuration changed, then `oe:module:activate` for `oe_graphql_base`, `oe_graphql_storefront`,
   `oe_payment_base` and each payment module (`oe:module:deactivate` first if its activation is stale).
3. **Migrations of payment-base:** `vendor/oxid-esales/payment-base/bin/run-migrations.sh` (from the shop
   root; it needs PHP 8.3+ and the doctrine migration wrapper, and exits quietly if either is missing — read
   its output for `Migrations completed.`). Version `20261022100000` hashes the stored headless contract
   tokens (SHA-256, sprint 138b); a checkout started before it is finished with the old plaintext token, so
   run it in a quiet moment.
4. `vendor/bin/oe-console oe:graphql:cache-clear`, then delete
   `var/cache/container/container_cache_shop_1.php`.
5. **Smoke query** — the new field must be in the schema (a stale cache fails here):

   ```bash
   curl -sk -H 'Host: pay1.oxid.dev' -H 'Content-Type: application/json' \
     'https://127.0.0.1:8543/graphql/?lang=1&shp=1' \
     -d '{"query":"{ __type(name: \"Query\") { fields { name } } }"}' | grep -o 'paymentClientConfig'
   ```

   It prints `paymentClientConfig`. Nothing printed means the schema is stale (repeat step 4) or the module is
   not active (step 2). A real query follows with a token, as in the stripe module's
   `docs/for_developer/05-headless-graphql-checkout.md`.

### The `/graphql/` rewrite (QSA, skipSession)

nginx proxies `/graphql/` to the shop's apache; apache's rewrite in the shop's web-root `.htaccess` turns it
into the widget controller. Both flags matter: `skipSession=1` (the shop must not open a session cookie for an API
call) and `QSA` (the query string — `lang`, `shp` of sprint 139b — must survive the rewrite, or the shop
answers in its default language and subshop). On the host, verify it in the shop's `.htaccess`:

```bash
grep -n 'graphql' /var/www/oxid/oxid75/source/.htaccess
# expect exactly: RewriteRule ^graphql/?$    widget.php?cl=graphql&skipSession=1   [QSA,NC,L]
```

(Use the shop's web root of the pay1 container's mount if it differs.) `skipSession=1` and `QSA` must both
appear on that line; an `.htaccess` regenerated by a shop update can lose them — check after every update. The
behaviour proof is the language: `curl -sk … '/graphql/?lang=0'` and `'?lang=1'` of a localised field answer in
different languages.

### PHP setting for the shop's log

Set `zend.exception_ignore_args=On` in the shop's PHP ini (PHP's production default; the SDK's development
image may have it off). With it off, graphql-base's stack traces copy the full query text — return URLs and
contract tokens — into `oxideshop.log` (finding of sprint 138d). Check:
`php -r 'var_dump(ini_get("zend.exception_ignore_args"));'` inside the shop's php-fpm/apache container (the
CLI may read another ini than the web SAPI: check `php-fpm -i` / `phpinfo()` there too).

### Payments on pay1

pay1's shop offers **Stripe** (test mode, automatic capture) and **Mollie** (test mode, manual capture);
PayPal's module is not installed there. The instances run both inline (iframe mode) with their
**no provider key at all**: the Stripe publishable key and the Mollie profile id (and test mode) are held by the shop and handed to the browser sealed (oxid-fe-user `docs/payments-keys.md`); a key field in an instance config stops the build — no key and no secret ever enters this repository.

Shop-side setup for this (each with a backup of `composer.json` / `composer.lock` next to the original):

| Change                                                                                                                          | Why                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `oe_payment_base` → `sPaymentBaseHeadlessReturnOrigins` = the three `https://pay1.oxid.dev:<port>` origins                      | the shop returns shoppers only to allow-listed frontends                                                                                                                                                                                                           |
| `oxid-esales/mollie-payment` **`dev-b-7.4.x`** (upstream)                                                                       | the headless `cardToken` / `uiMode: embedded` change for Mollie Components is merged upstream (OXID-eSales/mollie-payment#8, `7fb262a`)                                                                                                                            |
| `oxid-esales/stripe-wallet` pinned to branch `feature/session-locale-from-request-language` (`b98e559`, in the OXID repository) | Checkout Sessions are created in the shop's active language (`locale`); without it Stripe's form follows the browser. CI on that branch passed (OXID CE 7.4 / 7.5 / 7.6). **When the branch is merged into `b-7.4.x`, set the requirement back to `dev-b-7.4.x`.** |

Proof: `LIVE=1 E2E_BASE_URL=https://pay1.oxid.dev:2053 SHOP_USER=… SHOP_PASSWORD=… npx playwright test payments-live --workers=1`
(and `:2083`, `:8443`): Stripe test card pays inline, a declined card is explained inside the form and a
good card then succeeds, Mollie card (Components, authorized), failed Mollie payment → no order and a
fresh attempt works, iDEAL — each ending in an order visible in `/dashboard/orders`.
The specs use the shared sandbox test customer; they create real (test-mode) orders in the pay1 shop.

### Cache policy — every deploy reaches phones and browsers

| Path                                  | `Cache-Control`                       | Why                                                                                   |
| ------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------- |
| `/assets/*` (content-hashed bundles)  | `public, max-age=31536000, immutable` | a new release has new file names                                                      |
| `/`, SPA routes (`index.html`)        | `no-cache`                            | always revalidated, so it always points at the newest bundles                         |
| `/themes/*` (config, css, fonts, img) | `no-cache`                            | **the URL stays the same across releases**: without this, browsers keep the old theme |
| `/oxid-config.json`                   | `no-store`                            | the instance's configuration applies on the next load                                 |

`no-cache` means "store, but revalidate every time" (ETag → `304`), so it costs one cheap request.
The deploy workflow's smoke test fails if any of these headers regress. A browser that cached the
**theme files under the old (header-less) policy** keeps them until its heuristic freshness expires
(typically hours); clear the site's cache once, or wait.
