#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${OUT_DIR:-"$ROOT/_site/rpm"}
mkdir -p "$OUT_DIR/packages"
api=()
[[ -z "${GH_TOKEN:-}" ]] || api=(-H "Authorization: Bearer $GH_TOKEN")
while IFS= read -r entry; do
  repo=$(jq -r .repo <<<"$entry")
  tag=$(jq -r .release_tag <<<"$entry")
  package=$(jq -r .package <<<"$entry")
  pattern=$(jq -r .asset_pattern <<<"$entry")
  release=$(curl -fsSL --retry 3 "${api[@]}" "https://api.github.com/repos/$repo/releases/tags/$tag")
  asset=$(jq -ce --arg pattern "$pattern" '[.assets[] | select(.name | test($pattern))] | if length==1 then .[0] else error("Expected one RPM release asset") end' <<<"$release")
  name=$(jq -r .name <<<"$asset")
  url=$(jq -r .browser_download_url <<<"$asset")
  digest=$(jq -r '.digest // empty' <<<"$asset")
  [[ "$name" =~ ^[A-Za-z0-9._+~-]+\.rpm$ && "$url" == https://github.com/"$repo"/* && "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
  curl -fLsS --retry 3 "$url" -o "$OUT_DIR/packages/$name"
  printf '%s  %s\n' "${digest#sha256:}" "$OUT_DIR/packages/$name" | sha256sum -c
  [[ "$(rpm -qp --qf '%{NAME}' "$OUT_DIR/packages/$name")" == "$package" ]]
done < <(jq -c '.[]' "$ROOT/rpm-upstream.json")
createrepo_c "$OUT_DIR"
cat > "$OUT_DIR/pooplabs.repo" <<'REPO'
[pooplabs]
name=Poop Labs RPM packages
baseurl=https://poopware-laboratories.github.io/pooplabs-apt-repo/rpm/
enabled=1
gpgcheck=0
REPO
