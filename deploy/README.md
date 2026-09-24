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

Both sides are portless as of 2026-09-19: `SERVICE_URL` here and
`TOKENSTATUSLISTSERVICE_SERVICEURL` in `eudi-srv-wallet-provider`.

## Routing

Two prefixes, which are everything the service serves or publishes:

    /token_status_list    the API (take, get, set, swagger) and published status lists
    /identifier_list      published identifier lists

Neither is stripped: the app namespaces itself with
`url_prefix="/token_status_list"`, and the URIs it signs into credentials carry
both prefixes as they are.

It held the hostname root until 2026-09-24. The root is now the landing page in
`eudi-srv-wallet-provider`.

## The web container, and why the lists need it

**Every list URI this service published was a 404 until 2026-09-24.** The app
writes each list it issues to disk as signed files and signs the URL into
credentials:

    https://<host>/token_status_list/<country>/<doctype>/<uuid>
    https://<host>/identifier_list/<country>/<doctype>/<uuid>

but it has no route that serves them. Upstream expects a web server in front.
Nothing noticed, because every check probed the API, never a published list.

`eudiw-statuslist-web` is that web server, stock nginx, and the only container
here the proxy routes to. The app is behind it on a private network.

| Request | Served |
| --- | --- |
| a list URI, `Accept: application/statuslist+jwt`, or no `Accept` | `token_status_list.jwt`, `Content-Type: application/statuslist+jwt` |
| a list URI, `Accept: …+cwt` | the `.cwt`, with the matching `+cwt` type |
| the same under `/identifier_list/` | `identifier_list.jwt` or `.cwt`, `application/identifierlist+…` |
| anything else under `/token_status_list` | passed to the app, path unchanged |

The media types are the ones the tokens declare themselves, in `typ` and the CWT
content type. Responses carry `Vary: Accept`.

**`full_list.json` is never served.** It sits beside each list and is the app's
unsigned working state. The web container maps only the negotiated signed file
to disk; any other path falls through to the app, which has no route for it.

It mounts the lists volume read-only; the app is the only writer.

A quirk worth knowing if you edit it. The `Accept` format is resolved with
`set $fmt $list_fmt` *before* the rewrite. The map behind `$list_fmt` is a regex,
and when it matches it clobbers the rewrite's `$1..$3`, so evaluating it inside
the rewrite produced an empty path and a 404, for CWT only. Found by testing.

`deploy.sh` and the workflow both fetch a list the service actually published,
by the URI it signed, and check that `full_list.json` beside it is a 404.

## No TLS in the container

`run-statuslist-server.sh` passes `--cert` and `--key` read from
`/etc/letsencrypt`. The container does not: nginx-proxy terminates TLS and
reaches the service over plain HTTP on `proxy-net`. The certificate for
`demo.eudiw.grnet.gr` already exists, issued for the wallet provider, and
acme-companion reuses it for the same name.

## Configuration

Every value below is read at import time by `app/config_service.py`, each
falling back to the upstream default when unset, so the image still runs with
none of them set.

| Variable | Default | What it does |
| --- | --- | --- |
| `SERVICE_URL` | `https://issuer.eudiw.dev/` | Signed into every token as `sub`. Must match where the service is actually reachable. |
| `STATUS_LISTS_DIR` | `/var/opt/status_lists` | Where issued lists are written. Set to `/data/status_lists` in the image. |
| `STATUS_LIST_BACKUP_DIR` | `/var/opt/status_list_backup` | Rotation backups. Set to `/data/status_list_backup` in the image. |
| `FC_PRIVATE_KEY` | a `PID-DS-0001_UT` path | EC private key that signs the lists. |
| `FC_CERTIFICATE` | a `PID-DS-0001_UT` path | DER certificate matching that key. |
| `API_key` | unset | Shared secret for `X-Api-Key`. Note the capitalisation, it is read as `API_key`. |

`SERVICE_URL` deserves care. It is not cosmetic and it is not rewritable later:
the value ends up inside the signature of every token, so changing it does not
migrate anything already issued.

## The API, as it actually behaves

Worth writing down, because the shapes are not obvious and cost time to
rediscover.

`POST /token_status_list/take` allocates an index. It reads **form data**, not
JSON, and all three fields are required:

    curl -X POST http://localhost:5603/token_status_list/take \
      -H "X-Api-Key: test" \
      -F "country=FC" \
      -F "doctype=oauth-client-attestation+jwt" \
      -F "expiry_date=2030-01-01"

It returns the `uri` and `idx` that go into the credential.

`GET /token_status_list/get` reads a status back. The URI is a query parameter,
not a path to dereference. Fetching the returned `uri` directly gives a 404,
which looks like a bug and is not:

    curl -G http://localhost:5603/token_status_list/get \
      --data-urlencode "uri=$URI" --data-urlencode "idx=$IDX"

`0` means valid, `1` means revoked.

`GET /token_status_list/swagger/` is the health endpoint. The trailing slash
matters: without it Flask answers `308` and `curl -f` treats that as a failure.
That is why the healthcheck includes it.

`take` and `set` require `X-Api-Key`. `get` does not, which is correct, since
relying parties have to read status without holding a secret.

## What this does not do

`flask run` is the development server, and it prints a warning saying so on every
start. It is what the VM already uses, so the container is no worse, but it is a
single-threaded development server holding the only copy of the revocation data.
See `TODO.md`.

The renewal thread in `app/lists_renewal.py` starts inside `create_app()` and
rotates lists daily. It means the service cannot be scaled past one replica:
two containers would both rotate the same volume. Not a problem today, worth
knowing before anyone reaches for `deploy.replicas`.

`app.debug = True` is hardcoded in `app/__init__.py`. Flask's reloader is off
because `flask run` is not invoked with `--debug`, but the interactive debugger
and its traceback pages are reachable on an unhandled exception. See `TODO.md`.

## Still to sort

- The signing key is committed on the `demo` branch and needs rotating. Not
  cheap: it is a leaf issued by the GRNET IACA, so rotating means a new leaf from
  `WEBUILD/pki/` rather than a fresh openssl key.
- The bare flask process on the box still serves `:5603` with the same key.
