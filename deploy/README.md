# Deploying the status list

Two workflows. `docker-build.yml` publishes an image to GHCR on push.
`docker-deploy.yml` is manual only, so merging a branch never changes what is
running.

The deploy drives the box's Docker daemon over SSH. Nothing is copied to the
server: compose reads the file and the environment on the runner and sends the
daemon an already-expanded spec. The only things that exist on the box are
containers, named volumes, the signing key directory, and the Docker socket.

## Before the first deploy

Three things, in this order.

**1. The edge must be up.** nginx-proxy, acme-companion and the `proxy-net`
network are defined in `eudi-srv-wallet-provider`, not here. Deploy that stack
first. The preflight step checks and stops if `proxy-net` is missing.

**2. The signing key must be on the box.** `SIGNING_KEY_DIR` in `stack.env`
points at `/home/ubuntu/statuslist-keys`, which must contain `signing.key` and
`signing.der`:

    ssh target mkdir -p /home/ubuntu/statuslist-keys
    scp signing.key signing.der target:/home/ubuntu/statuslist-keys/
    ssh target chmod 600 /home/ubuntu/statuslist-keys/signing.key

The key is placed out of band and never passes through a CI runner. This is the
one piece of configuration that is a file rather than a string, and it is the
reason there is no `SIGNING_KEY` secret.

It is also the quiet failure mode. A bind mount whose source does not exist does
not error: Docker creates an empty directory and the container starts with no
key. The preflight checks both files are readable before deploying, and the
verify step checks the mounted key is non-empty afterwards.

**3. The old writer must be stopped.** The bare flask process on the box holds
the same signing key. Two services allocating against the same logical lists
diverge in a way that cannot be merged, so only one writer, ever.

## Repository secrets

Only one, plus the SSH key.

| Secret | What it is |
| --- | --- |
| `SSH_KEY` | Private key authorised for `ubuntu@3.69.83.252`. Written to `~/.ssh/eudiw-deploy` on the runner. Paste the whole file, BEGIN and END lines included. |
| `STATUSLIST_API_KEY` | Shared secret for `X-Api-Key`, required by `/take` and `/set`. Must match the wallet provider's `TOKENSTATUSLISTSERVICE_APIKEY`, which is currently `test`. |

Everything else is non-secret and committed in `stack.env`, where it is
reviewable in a diff.

The two API key secrets live in different repositories and there is nothing that
keeps them in sync. Changing one without the other means the wallet provider
gets a 401 on every attestation it tries to issue.

## Replacing the VM service

The container starts with empty volumes and allocates from zero. The existing
lists on the box are deliberately not migrated.

Every token referencing them carries `:5603` inside its signature, so moving to
443 makes them unresolvable whether or not the data comes along. Migrating would
preserve lists that nothing can dereference, at the cost of a maintenance window
and an unrecoverable failure mode. New lists get fresh UUIDs, so nothing
collides, and the old directories stay on the box as a fallback.

What does move is the signing key, because its certificate runs to Jan 2028 and
is what relying parties expect. That is step 2 above.

The full sequence is in `CUTOVER.md` in the repository root.

## The port change

Tokens issued so far carry `:5603` inside the signature:

    "sub": "https://demo.eudiw.grnet.gr:5603/token_status_list/FC/..."

Behind the proxy the name arrives on 443 and `:5603` is no longer published, so
those stop resolving. They are development data expiring 2026-12-07 and the
decision to accept the break is recorded in the top-level `DOCKER.md`.

Two changes have to land together:

- `SERVICE_URL` here, already `https://demo.eudiw.grnet.gr/` in `stack.env`
- `TOKENSTATUSLISTSERVICE_SERVICEURL` in `eudi-srv-wallet-provider`, still
  pointing at `:5603`

## Routing

This service takes the root of the hostname:

    VIRTUAL_HOST=demo.eudiw.grnet.gr
    VIRTUAL_PATH=/
    VIRTUAL_DEST=/

The wallet provider sits at `/wallet-provider/` on the same name. nginx prefers
the longer location match, so its prefix keeps winning and this catches
everything else. The verify step checks both, because taking the root is exactly
the change that could shadow a sibling.

`VIRTUAL_DEST=/` passes paths through unchanged rather than stripping a prefix,
because the app namespaces itself with `url_prefix="/token_status_list"`.

## No TLS in the container

`run-statuslist-server.sh` passes `--cert` and `--key` read from
`/etc/letsencrypt`. The container does not: nginx-proxy terminates TLS and
reaches the service over plain HTTP on `proxy-net`. The certificate for
`demo.eudiw.grnet.gr` already exists, issued for the wallet provider, and
acme-companion reuses it for the same name.

## Still to sort

- The signing key is committed on the `demo` branch and needs rotating. Doing it
  at the same time as the port change costs nothing extra, since both invalidate
  the same tokens.
- `flask run` is the development server. See the repository `TODO.md`.
