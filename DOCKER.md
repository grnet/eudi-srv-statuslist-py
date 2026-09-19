# Running the status list in Docker

The service is a Flask app that allocates revocation indices and writes signed
status lists to disk. It has no database. Everything it has ever issued lives in
two directories, so the volumes below are not an optimisation, they are the only
thing standing between a restart and losing the lot.

## Quick start

Signing material is not in this repo and must not be committed. Point at local
files through `.env`:

    FC_PRIVATE_KEY=/absolute/path/to/signing.key
    FC_CERTIFICATE=/absolute/path/to/signing.der
    API_KEY=test
    SERVICE_URL=http://localhost:5603/

Then:

    docker compose up --build

The service answers on `http://localhost:5603`, bound to loopback only.

To generate a throwaway key for local work, which is what the CI smoke test
does:

    openssl ecparam -genkey -name prime256v1 -noout -out signing.key
    openssl req -new -x509 -key signing.key -out signing.crt -days 365 -subj "/CN=local-ds"
    openssl x509 -in signing.crt -outform der -out signing.der

Tokens signed by that key verify against nothing. Fine for exercising the API,
useless for anything a wallet will accept.

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

## Deployment

Behind nginx-proxy on the shared edge, at the root of the demo hostname:

    VIRTUAL_HOST=demo.eudiw.grnet.gr
    VIRTUAL_PATH=/
    VIRTUAL_DEST=/

The status list owns that name because it signs it into every token, and its
signing material on the box is named for it. The wallet provider sits under
`/wallet-provider/` on the same hostname and is unaffected: nginx prefers the
longer location match, so the prefix keeps winning and the status list catches
everything else.

`VIRTUAL_DEST=/` passes paths through unchanged rather than stripping a prefix,
because the app namespaces itself already. `app/status_list_endpoints.py`
registers its blueprint with `url_prefix="/token_status_list"`.

No TLS in the container. `run-statuslist-server.sh` passes `--cert` and `--key`
read from `/etc/letsencrypt`, which the VM needs and the container does not:
nginx-proxy terminates TLS and reaches the service over plain HTTP on the
internal network.

### Migrating the existing data

The running service on the EC2 box holds roughly 292K in `status_lists/` and
1.1M in `status_list_backup/`, 48 files, none of it in git. The signing key is
not in git either on `main`. Containerising without moving all of it first
destroys it.

1. Stop the flask process. It writes on every allocation, so copying from under
   a live service risks a torn read.
2. Copy both directories into the named volumes.
3. Copy the signing key and certificate to wherever the deploy stack mounts them
   from. Losing them means every token issued afterwards is signed by a
   different key, and every token issued before it stops verifying.
4. Start the container and confirm the existing lists are readable before
   removing the old process.
5. Keep a copy off the box until the container has been running long enough to
   trust.

### The port change

Tokens issued so far carry `:5603` inside the signature:

    "sub": "https://demo.eudiw.grnet.gr:5603/token_status_list/FC/..."

Behind the proxy the name arrives on 443 and `:5603` is no longer published, so
those stop resolving. They are development data expiring 2026-12-07, and the
decision recorded in the top-level `DOCKER.md` is to accept the break. The wallet
provider's `TOKENSTATUSLISTSERVICE_SERVICEURL` has to drop the port in the same
change.

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
