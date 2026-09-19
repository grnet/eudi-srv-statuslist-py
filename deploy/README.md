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

**3. The data must be migrated.** See below. Deploying before this means the
service starts with empty volumes and begins allocating indices from zero,
against lists that already exist elsewhere.

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

## Migrating from the VM

The running service holds roughly 292K in `status_lists/` and 1.5M in
`status_list_backup/`, 48 files, plus a signing key. None of it is in git on
`main`. Containerising without moving it first destroys it.

Order matters.

    # 1. Stop the flask process. It writes on every allocation, so copying from
    #    under a live service risks a torn read. It runs in a pts session, so
    #    find it rather than assuming a service unit.
    ssh target
    pgrep -af 'flask --app app'
    kill <pid>

    # 2. Take a copy off the box first, before touching anything.
    scp -r target:~/eudi-srv-statuslist-py/status_lists ./backup-status_lists
    scp -r target:~/eudi-srv-statuslist-py/status_list_backup ./backup-status_list_backup
    scp target:~/eudi-srv-statuslist-py/demo.eudiw.grnet.gr_5603.key ./
    scp target:~/eudi-srv-statuslist-py/demo.eudiw.grnet.gr_5603.crt.der ./

    # 3. Put the signing material where the stack expects it.
    ssh target mkdir -p /home/ubuntu/statuslist-keys
    scp demo.eudiw.grnet.gr_5603.key target:/home/ubuntu/statuslist-keys/signing.key
    scp demo.eudiw.grnet.gr_5603.crt.der target:/home/ubuntu/statuslist-keys/signing.der
    ssh target chmod 600 /home/ubuntu/statuslist-keys/signing.key

    # 4. Create the volumes and load the data. Run the deploy once first so the
    #    volumes exist, then stop the container before writing into them.
    ssh target
    docker stop eudiw-statuslist
    docker run --rm -v eudiw-statuslist_status-lists:/dest \
      -v ~/eudi-srv-statuslist-py/status_lists:/src:ro \
      alpine sh -c 'cp -a /src/. /dest/'
    docker run --rm -v eudiw-statuslist_status-list-backup:/dest \
      -v ~/eudi-srv-statuslist-py/status_list_backup:/src:ro \
      alpine sh -c 'cp -a /src/. /dest/'
    docker start eudiw-statuslist

    # 5. Confirm an existing list reads back before removing anything.

Keep the copies off the box until the container has been running long enough to
trust.

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
