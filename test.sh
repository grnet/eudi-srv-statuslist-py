#!/usr/bin/env bash

echo Taking...
curl -X POST \
  'http://127.0.0.1:5603/token_status_list/take' \
  -H 'X-API-Key: dev-secret' \
  --data-urlencode 'country=FC' \
  --data-urlencode 'doctype=eu.europa.ec.eudi.pid.1' \
  --data-urlencode 'expiry_date=2027-12-31' \
  -o take.json

ID=$(cat take.json | jq -r .identifier_list.id)
URI=$(cat take.json | jq -r .identifier_list.uri)

echo "ID=${ID}, URI=${URI}"

echo Getting...
curl -G \
  'http://127.0.0.1:5603/token_status_list/get' \
  --data-urlencode "uri=${URI}" \
  --data-urlencode "idx=${ID}"
