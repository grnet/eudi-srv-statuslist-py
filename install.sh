#!/usr/bin/env bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
pip install -r app/requirements.txt
