# SEC-1 follow-up — closing the zod advisory in hydroxid

Branch `feature/zod4-advisories` fixes what is local to hydroxid: `happy-dom` is pinned to the patched
`21.0.4` (GHSA-834v-8h66-3h79; was `latest`, locked at 21.0.3). hydroxid has no direct zod dependency.

GHSA-mrhx-c7xc-m3w5 (zod < 4.6.6) stays open here until the GitHub `#main` pins deliver zod 4. `npm audit`
reports exactly these, all one root cause (the pins resolve to zod 3.25.76):

- `zod`
- `@dantweb/oxid-fe-core` (depends on zod 3)
- `@dantweb/oxid-fe-user` (depends on core and zod 3)

Never waive them. Close them in this order. Nothing here was pushed or merged by the agent that prepared it.

## 1. oxid-fe-core (branch `feature/admin-seams`, 0.11.0, carries zod 4.6.7)

```bash
cd /home/dtkachev/osc/strpwt7-nov26/oxid-fe-core
git checkout main
git merge --no-ff feature/admin-seams
git tag v0.11.0
git push origin main v0.11.0
```

## 2. oxid-fe-user (branch `feature/zod4-advisories`, 0.7.1, built on `main`)

```bash
cd /home/dtkachev/osc/strpwt7-nov26/oxid-fe-user
git checkout main
git merge --no-ff feature/zod4-advisories
git push origin main
```

## 3. hydroxid: merge this branch, update the pins, re-audit

```bash
cd /home/dtkachev/osc/strpwt7-nov26/peroxid
git checkout main
git merge --no-ff feature/zod4-advisories
npm update @dantweb/oxid-fe-core @dantweb/oxid-fe-user
npm ls zod            # every line must be 4.6.7 or newer (no 3.x)
npm audit             # expect: found 0 vulnerabilities
```

If `npm ls zod` still shows 3.x, the lock still holds the old commit hashes: delete the two
`node_modules/@dantweb/*` entries from `package-lock.json` and run `npm install`.

## 4. Jitless (only if hydroxid is ever served under a CSP without `'unsafe-eval'` / with Trusted Types)

hydroxid has no CSP today, and its `src/main.ts` does not use oxid-fe-user's `main.ts`, so the user app's
`zodConfig.ts` does not run here. Zod 4 compiles parsers with `new Function`; under such a CSP, add
`src/zodConfig.ts` and import it first in `src/main.ts`. It needs core 0.11.0, so it can only be added after step 3:

```ts
// src/zodConfig.ts
import { configureZodForCsp } from '@dantweb/oxid-fe-core/zod-csp';
configureZodForCsp();
```

```ts
// src/main.ts, first line
import './zodConfig';
```

## 5. Verify

```bash
./bin/pre-commit-check.sh --no-e2e      # expect COMMITABLE, npm audit included
```
