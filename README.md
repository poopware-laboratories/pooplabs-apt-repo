# Poop Labs APT Repository

A flat APT package feed for Debian packages and jailbreak packages maintained by [Poopware Laboratories](https://github.com/poopware-laboratories).

The landing page, with one-tap add links and the current package list, is at <https://poopware-laboratories.github.io/pooplabs-apt-repo/>.

## Add to a jailbroken iOS device

Add this source in Cydia under **Sources → Edit → Add** (Sileo and Zebra work too):

`https://poopware-laboratories.github.io/pooplabs-apt-repo/`

The iOS packages in this feed use the `iphoneos-arm` architecture.

## Add to Debian or Ubuntu

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://poopware-laboratories.github.io/pooplabs-apt-repo/pooplabs.gpg -o /etc/apt/keyrings/pooplabs.gpg
echo 'deb [signed-by=/etc/apt/keyrings/pooplabs.gpg] https://poopware-laboratories.github.io/pooplabs-apt-repo/ ./' | sudo tee /etc/apt/sources.list.d/pooplabs.list
sudo apt update
```

APT picks packages compatible with the machine's architecture.

> The feed is signed only once the `APT_GPG_PRIVATE_KEY` secret is configured (see below). Until then `pooplabs.gpg` does not exist and the feed is unsigned; the landing page shows the matching instructions (`deb [trusted=yes] … ./`). Use `trusted=yes` only if you trust the repository and its maintainers.

## How the feed is built

`scripts/build-feed.sh` builds everything GitHub Pages serves. You can run it locally (needs `dpkg-dev`, `jq`, `python3`, `gpg`): `SKIP_UPSTREAM=1 OUT_DIR=/tmp/site scripts/build-feed.sh`.

It:

1. validates `debs/` — control data must be readable, files must be named `<package>_<version>_<architecture>.deb`, and a package/version/architecture can appear only once;
2. imports packages from other repositories listed in `upstream.json` (currently the latest stable Poopterm `amd64` release), verifying the asset's SHA-256 digest when GitHub provides one. If an upstream is unreachable, the copy already published is kept;
3. keeps only the newest version of each package/architecture (`KEEP_VERSIONS`);
4. writes `Packages` (`.gz`, `.bz2`, `.xz`) and a `Release` with MD5Sum, SHA1 and SHA256;
5. signs the feed (`InRelease`, `Release.gpg`) and publishes the public key (`pooplabs.gpg`, `pooplabs.gpg.asc`) when `APT_GPG_PRIVATE_KEY` is set;
6. renders `index.html` from `scripts/index.template.html` and the package list.

The workflow runs on pushes to `main`, on demand, and hourly; the hourly run only deploys when the package index changed. Pull requests run `.github/workflows/validate.yml`, which builds the feed without publishing it.

## Publish a package

1. Put the `.deb` directly in `debs/`, named `<package>_<version>_<architecture>.deb`.
2. **Always bump the version.** APT and Cydia treat an unchanged version as unchanged, so replacing a file under the same version never reaches users who already installed it.
3. Open a pull request. Merging to `main` publishes it.

To import a package from another repository's releases, add it to `upstream.json` (`package`, `repo`, and an `asset_pattern` regex).

## One-time setup

1. Open **Settings → Pages** and set the build and deployment source to **GitHub Actions**.
2. Run `scripts/generate-signing-key.sh` on a trusted machine and add the printed private key as the repository secret `APT_GPG_PRIVATE_KEY` (and `APT_GPG_PASSPHRASE` if you set a passphrase). The next workflow run signs the feed. Keep a backup of the key: if you lose it, every user must re-import a new one.
3. Recommended: protect `main` (require pull requests and the *Validate APT feed* check), since pushes to it publish to users.
