#!/usr/bin/env bash

output=$(gcloud config config-helper --format=json | jq -c '.')
token=$(echo ${output} | jq -r '.credential.id_token')
expiry=$(echo ${output} | jq -r '.credential.token_expiry')

output='{"kind":"ExecCredential","apiVersion":"client.authentication.k8s.io/v1beta1","spec":{"interactive":false},"status":{"expirationTimestamp":"","token":""}}'
output=$(echo ${output} | jq ".status.token=\"${token}\"" | jq ".status.expirationTimestamp=\"${expiry}\"")
echo ${output}

