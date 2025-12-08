**Codeserver + Traefik Compose**

- **Purpose:** run the built `ghcr.io/ebpro/solen:<tag>-codeserver` image behind Traefik with TLS.
- **File:** `docker-compose.codeserver.yml`

Quick start

1. Copy the example env and edit values:

```bash
cp .env.codeserver.example .env.codeserver
# edit TRAEFIK_DOMAIN and TRAEFIK_EMAIL
```

2. Ensure the codeserver image exists (built with `./build.sh --build-codeserver` or `docker build -f Dockerfile.codeserver`).

3. Make sure the domain in `TRAEFIK_DOMAIN` resolves to this host (use a DNS A record or `/etc/hosts` for local testing).

4. Start the stack:

```bash
docker compose -f docker-compose.codeserver.yml --env-file .env.codeserver up -d
```

What the stack does
- `traefik` listens on ports 80 and 443 and will request TLS certs from Let's Encrypt using the HTTP challenge.
- `codeserver` is reachable at `https://${TRAEFIK_DOMAIN}` and Traefik will route and terminate TLS.

Notes & troubleshooting
- For local testing without a public domain, you can generate a local certificate and mount it under `letsencrypt` and adjust Traefik static config — otherwise use a real domain that points to this machine.
- Traefik will store ACME state at `./letsencrypt/acme.json` — ensure the directory is writable by Docker.
- If Let's Encrypt rate limits are a concern during testing, set up staging by configuring Traefik's `acme` resolver to use staging endpoints (or set `TRAEFIK_LETSENCRYPT_STAGING=1` and adjust the compose command accordingly).
- The Traefik dashboard is exposed on host port `8080` (insecure) in this example for convenience; you can disable `--api.insecure=true` and protect it behind auth in production.

Security
- Do not run with `--api.insecure=true` on internet-exposed hosts.
- Prefer `--auth password` for code-server or put Traefik in front with BasicAuth/TLS.
