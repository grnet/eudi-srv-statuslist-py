#!/usr/bin/env bash

if [ -f ".config.hostname" ]; then
    HOST=$(cat .config.hostname)
    TLS="--cert=/etc/letsencrypt/live/${HOST}/fullchain.pem --key=/etc/letsencrypt/live/${HOST}/privkey.pem"
else
    echo "WARNING: no file .config.hostname, skipping TLS setup"
    TLS=
fi

if [ -f ".config.ip" ]; then
    IP=$(<.config.ip)
else
    echo "Missing server setup: .config.ip"
    exit
fi

source .venv/bin/activate
echo "Running in branch: "$(git rev-parse --abbrev-ref HEAD)
FLASK_RUN_PORT=5603
echo "Host: ${HOST}:${FLASK_RUN_PORT}"

export API_key=test
export FC_PRIVATE_KEY=$(realpath demo.eudiw.grnet.gr_5603.key)
export FC_CERTIFICATE=$(realpath demo.eudiw.grnet.gr_5603.crt.der)
mkdir -p status_lists
export STATUS_LISTS_DIR=$(realpath status_lists)
mkdir -p status_list_backup
export STATUS_LIST_BACKUP_DIR=$(realpath status_list_backup)

set -x
flask --app app run ${TLS} --host="${IP}" --port ${FLASK_RUN_PORT}
