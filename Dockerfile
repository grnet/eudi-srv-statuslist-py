# install.md says "tested with Python 3.10", but that is the oldest version
# anyone wrote down, not a constraint: nothing declares requires-python, and the
# VM runs 3.14.4 today. 3.10 reaches end of life in October 2026.
#
# 3.13 verified here: dependencies install, the service starts, and it issues an
# index and reads it back.
FROM python:3.13-slim

WORKDIR /app

# curl is for the healthcheck. No build-essential: every dependency in
# app/requirements.txt ships a wheel for this platform.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Dependencies before source, so editing the app does not reinstall them.
COPY app/requirements.txt ./app/requirements.txt
RUN python -m pip install --upgrade pip \
    && pip install --no-cache-dir -r app/requirements.txt

COPY . .

# The renewal thread and the endpoints both write here. Declared so the image
# runs standalone; compose replaces them with named volumes, which is what keeps
# issued lists across a restart.
ENV STATUS_LISTS_DIR=/data/status_lists \
    STATUS_LIST_BACKUP_DIR=/data/status_list_backup
RUN mkdir -p "$STATUS_LISTS_DIR" "$STATUS_LIST_BACKUP_DIR"

EXPOSE 5603

# No TLS here, unlike run-statuslist-server.sh, which passes --cert and --key
# read from /etc/letsencrypt. nginx-proxy terminates TLS and reaches this over
# plain HTTP on the internal network.
#
# 0.0.0.0 rather than the host's private IP: inside a container the only address
# that works is every address.
#
# flask run is the development server and says so on startup. Accepted for now,
# see TODO.md; gunicorn is the change when this stops being a demo.
CMD ["flask", "--app", "app", "run", "--host=0.0.0.0", "--port=5603"]
