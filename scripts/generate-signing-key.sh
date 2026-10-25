#!/usr/bin/env bash
# Generates a signing key for the feed and prints the values to store as
# GitHub Actions secrets. Run it on a trusted machine; nothing is written to
# the repository.
#
#   APT_GPG_PRIVATE_KEY   the armored private key (printed below)
#   APT_GPG_PASSPHRASE    optional; only needed if you set one when prompted
set -euo pipefail

home=$(mktemp -d)
chmod 700 "$home"
export GNUPGHOME=$home
trap 'gpgconf --kill all 2>/dev/null || true; rm -rf "$home"' EXIT

gpg --quick-generate-key 'Poop Labs APT Repository <apt@poopware-laboratories.invalid>' rsa4096 sign 10y

fingerprint=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
echo
echo "Fingerprint: $fingerprint"
echo
echo "Add the following as the repository secret APT_GPG_PRIVATE_KEY"
echo "(Settings -> Secrets and variables -> Actions):"
echo
gpg --armor --export-secret-keys "$fingerprint"
