import { describe, expect, it } from 'vitest';
import { renderNginx } from '../../scripts/render-nginx.mjs';

const targets = {
  instances: {
    vibrant: { theme: 'hydroxid-vibrant', ports: { local: 8101, pay1: 2053 } },
    'dark-ocean': { theme: 'hydroxid-dark-ocean', ports: { local: 8102, pay1: 2083 } },
  },
};

describe('renderNginx', () => {
  it('one server block per instance on that target’s port, serving the instance’s own rendered JSON', () => {
    const conf = renderNginx(targets, 'local');

    expect(conf).toContain('listen 8101;');
    expect(conf).toContain('listen 8102;');
    expect(conf).not.toContain('ssl'); // plain HTTP on localhost
    expect(conf).toContain('alias /srv/hydroxid/build/instances/vibrant/oxid-config.json;');
    expect(conf).toContain('alias /srv/hydroxid/build/instances/dark-ocean/oxid-config.json;');
    expect(conf).not.toContain('2053');
  });

  it('pay1 uses its own ports, release path and the shop behind it over TLS', () => {
    const conf = renderNginx(targets, 'pay1');

    expect(conf).toContain('listen 2053 ssl;');
    expect(conf).toContain('listen 2083 ssl;');
    expect(conf).toContain('ssl_certificate /etc/ssl/peroxid/origin.crt;');
    expect(conf).toContain('/var/www/oxid/oxid75/peroxid/current/dist');
    expect(conf).toContain('proxy_pass https://127.0.0.1:8543/graphql/;');
    expect(conf).toContain('proxy_set_header Host pay1.oxid.dev;');
  });

  it('never serves a YAML, and never the instance folders', () => {
    for (const target of ['local', 'pay1']) {
      const conf = renderNginx(targets, target);
      expect(conf).toMatch(/location ~\* \\\.ya\?ml\(\\\.dist\)\?\$ \{\s*return 404;/);
      expect(conf).not.toContain('oxid-config.yaml;');
      expect(conf).not.toMatch(/alias [^;]*instances\/[^;]*yaml/);
    }
  });

  it('cache policy: hashed assets immutable; everything that keeps its URL revalidates (no stale releases)', () => {
    for (const target of ['local', 'pay1']) {
      const conf = renderNginx(targets, target);
      expect(conf).toMatch(
        /location \/assets\/ \{\s*add_header Cache-Control "public, max-age=31536000, immutable";/,
      );
      expect(conf).toMatch(
        /location \/themes\/ \{\s*add_header Cache-Control "no-cache";\s*try_files \$uri =404;/,
      );
      expect(conf).toMatch(/location = \/oxid-config\.json \{[^}]*Cache-Control "no-store"/);
      expect(conf).toMatch(/location \/ \{\s*add_header Cache-Control "no-cache";/); // index.html / SPA routes
    }
  });

  it('log hygiene (138d): every access_log uses the `headless` format — the path only, never a query string or referer', () => {
    for (const target of ['local', 'pay1']) {
      const conf = renderNginx(targets, target);
      const format = conf.match(/^log_format headless '([^']*)';$/m)?.[1] ?? '';

      expect(format).toBe(
        '$remote_addr - [$time_local] "$request_method $uri $server_protocol" $status $body_bytes_sent',
      );
      expect(format).toContain('$uri');
      for (const leaky of [
        '$request ',
        '$request"',
        '$request_uri',
        '$args',
        '$query_string',
        '$http_referer',
      ]) {
        expect(format).not.toContain(leaky);
      }
      // the format is defined once, before the first server block that uses it
      expect(conf.match(/^log_format /gm)).toHaveLength(1);
      expect(conf.indexOf('log_format')).toBeLessThan(conf.indexOf('server {'));

      const accessLogs = conf.match(/^\s*access_log .*$/gm) ?? [];
      expect(accessLogs).toHaveLength(Object.keys(targets.instances).length);
      for (const line of accessLogs) {
        expect(line).toMatch(/ headless;$/);
      }
      expect(conf).not.toMatch(/\$request\b(?!_method)/); // nowhere in the file, not even in a comment
    }
  });

  it('rejects an unknown target and duplicate ports', () => {
    expect(() => renderNginx(targets, 'moon')).toThrow(/unknown target/);
    const clash = { instances: { a: { ports: { local: 1 } }, b: { ports: { local: 1 } } } };
    expect(() => renderNginx(clash, 'local')).toThrow(/same port/);
  });
});
