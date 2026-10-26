#!/bin/sh
# Init container entrypoint: publish the step scripts into the shared emptyDir
# that the db2 container mounts at /scripts.
#
# The scripts ship in an image pinned per DB2Version
# (DB2Version.spec.initContainer.image), so a version that needs a different
# command sequence gets a different init image - with no version branching in
# operator code. That is why this indirection exists.
set -eu

DEST=/scripts

rm -rf "${DEST:?}"/*
cp -a /tmp/scripts/. "$DEST"/
chmod +x "$DEST"/*.sh

echo "published to ${DEST}:"
ls -1 "$DEST"
