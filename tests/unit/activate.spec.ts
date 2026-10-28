import { execFileSync, spawnSync } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/** deploy/remote-activate.sh in a temp directory, with a stubbed nginx reload and health check. */
function sandbox(healthy: boolean) {
  const root = mkdtempSync(join(tmpdir(), 'hx-activate-'));
  const reloads = join(root, 'reloads.log');
  const reload = join(root, 'reload.sh');
  writeFileSync(reload, `#!/bin/sh\necho reload >> '${reloads}'\n`);
  const curl = join(root, 'curl.sh');
  writeFileSync(curl, `#!/bin/sh\n${healthy ? 'exit 0' : 'exit 22'}\n`);
  chmodSync(reload, 0o755);
  chmodSync(curl, 0o755);

  const base = join(root, 'peroxid');
  const release = (name: string, ports = [2053, 2083]): string => {
    const dir = join(base, 'releases', name);
    mkdirSync(join(dir, 'dist'), { recursive: true });
    mkdirSync(join(dir, 'build'), { recursive: true });
    writeFileSync(join(dir, 'dist', 'index.html'), name);
    writeFileSync(
      join(dir, 'build', 'nginx-pay1.conf'),
      ports.map((p) => `server {\n    listen ${p} ssl;\n}`).join('\n'),
    );
    return dir;
  };
  const activate = (dir: string) =>
    spawnSync('sh', ['deploy/remote-activate.sh', dir], {
      env: { ...process.env, NGINX_RELOAD: reload, HEALTH_CURL: curl },
      encoding: 'utf-8',
    });
  const reloadCount = (): number =>
    existsSync(reloads) ? readFileSync(reloads, 'utf-8').trim().split('\n').length : 0;
  return { root, base, release, activate, reloadCount };
}

describe('deploy/remote-activate.sh (runs as the CI user, writes only inside the project folder)', () => {
  it('switches `current` to the release and reloads nginx once', () => {
    const s = sandbox(true);
    const first = s.release('aaa');

    const result = s.activate(first);

    expect(result.status).toBe(0);
    expect(readlinkSync(join(s.base, 'current'))).toBe(first);
    expect(s.reloadCount()).toBe(1);
  });

  it('rolls back to the previous release — and reloads again — when the new one is not healthy', () => {
    const good = sandbox(true);
    const old = good.release('old');
    expect(good.activate(old).status).toBe(0);

    const bad = sandbox(false);
    const oldDir = bad.release('old');
    execFileSync('ln', ['-sfn', oldDir, join(bad.base, 'current')]);
    const next = bad.release('new');

    const result = bad.activate(next);

    expect(result.status).toBe(1);
    expect(result.stderr).toContain('rolling back');
    expect(readlinkSync(join(bad.base, 'current'))).toBe(oldDir);
    expect(bad.reloadCount()).toBe(2); // the new release, then the rollback
  });

  it('health-checks every port the release’s nginx config listens on', () => {
    const s = sandbox(true);
    const dir = s.release('ports', [2053, 2083, 8443]);
    writeFileSync(join(s.root, 'seen.log'), '');
    const probe = join(s.root, 'probe.sh');
    writeFileSync(probe, `#!/bin/sh\necho "$@" >> '${join(s.root, 'seen.log')}'\n`);
    chmodSync(probe, 0o755);

    spawnSync('sh', ['deploy/remote-activate.sh', dir], {
      env: { ...process.env, NGINX_RELOAD: join(s.root, 'reload.sh'), HEALTH_CURL: probe },
    });

    const seen = readFileSync(join(s.root, 'seen.log'), 'utf-8');
    for (const port of [2053, 2083, 8443]) {
      expect(seen).toContain(`https://127.0.0.1:${port}/oxid-config.json`);
    }
  });

  it('refuses a release without the compiled app and leaves `current` alone', () => {
    const s = sandbox(true);
    const dir = join(s.base, 'releases', 'empty');
    mkdirSync(dir, { recursive: true });

    expect(s.activate(dir).status).not.toBe(0);
    expect(existsSync(join(s.base, 'current'))).toBe(false);
    expect(s.reloadCount()).toBe(0);
  });

  it('keeps only the five newest releases', () => {
    const s = sandbox(true);
    for (let i = 1; i <= 7; i += 1) {
      execFileSync('touch', ['-d', `2026-01-0${i}`, s.release(`r${i}`)]);
    }
    s.activate(join(s.base, 'releases', 'r7'));

    const left = execFileSync('ls', [join(s.base, 'releases')], { encoding: 'utf-8' })
      .trim()
      .split('\n');
    expect(left.sort()).toEqual(['r3', 'r4', 'r5', 'r6', 'r7']);
  });

  it('never needs root: no command in the script is run as root except the reload', () => {
    const script = readFileSync('deploy/remote-activate.sh', 'utf-8')
      .split('\n')
      .filter((line) => !line.trimStart().startsWith('#'))
      .join('\n');
    expect(script.match(/sudo /g)).toHaveLength(1);
    expect(script).not.toMatch(/\/etc\/|systemctl|chown|openssl/);
  });
});
