#!/usr/bin/env bash

rm -rf .kcp/
./kcp/bin/kcp start \
  --run-controllers \
  --auto-publish-apis \
  --resources-to-sync="deployments.apps,statefulsets.apps,pods,services,secrets,persistentvolumeclaims"
