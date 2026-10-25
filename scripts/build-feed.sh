#!/usr/bin/env bash
# Builds the APT feed into $OUT_DIR (default: _site) from debs/*.deb plus the
# packages listed in upstream.json.
#
# Environment:
#   OUT_DIR              output directory (default: _site)
#   KEEP_VERSIONS        versions kept per package/architecture (default: 1)
#   FEED_URL             published feed URL, used for fallbacks and change detection
#   GH_TOKEN             optional token for GitHub API requests
#   APT_GPG_PRIVATE_KEY  optional armored private key; when set the feed is signed
#   APT_GPG_PASSPHRASE   optional passphrase for that key
#   SKIP_UPSTREAM        set to 1 to skip importing upstream packages
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD

OUT_DIR=$(realpath -m "${OUT_DIR:-_site}")
KEEP_VERSIONS=${KEEP_VERSIONS:-1}
FEED_URL=${FEED_URL:-https://poopware-laboratories.github.io/pooplabs-apt-repo}
SKIP_UPSTREAM=${SKIP_UPSTREAM:-0}

log() { printf '%s\n' "$*" >&2; }
warn() { if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::warning::$*"; else log "warning: $*"; fi; }
die() { if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::error::$*"; else log "error: $*"; fi; exit 1; }

field() { dpkg-deb -f "$1" "$2"; }

# debs/ must be well formed: readable control data, <pkg>_<version>_<arch>.deb
# file names, and no package/version/architecture published twice.
validate_repo_debs() {
  local f pkg ver arch expected seen=$'\n' key
  for f in debs/*.deb; do
    pkg=$(field "$f" Package) || die "$f: unreadable control data"
    ver=$(field "$f" Version)
    arch=$(field "$f" Architecture)
    [[ -n "$pkg" && -n "$ver" && -n "$arch" ]] || die "$f: missing Package, Version or Architecture"
    expected="${pkg}_${ver#*:}_${arch}.deb"
    [[ "$(basename "$f")" == "$expected" ]] || die "$f: file name must be $expected"
    key="$pkg $ver $arch"
    [[ "$seen" != *$'\n'"$key"$'\n'* ]] || die "$f: duplicate package $key"
    seen+="$key"$'\n'
  done
}

# Prints the live asset digest check result; fails on mismatch.
verify_digest() {
  local file=$1 expected=$2 actual
  [[ -z "$expected" ]] && return 1
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  [[ "sha256:$actual" == "$expected" ]] || die "$(basename "$file"): checksum mismatch (expected $expected, got sha256:$actual)"
}

# Fall back to the copy of an upstream package that is already published.
carry_over() {
  local package=$1 filename
  filename=$(curl -fsSL --retry 3 "$FEED_URL/Packages" 2>/dev/null |
    awk -v p="$package" 'BEGIN{RS="";FS="\n"} {n="";f=""; for(i=1;i<=NF;i++){if($i~/^Package: /)n=substr($i,10); if($i~/^Filename: /)f=substr($i,11)} if(n==p)print f}' |
    tail -n 1) || true
  if [[ -n "$filename" && "$filename" =~ ^debs/[0-9A-Za-z._+~-]+\.deb$ ]]; then
    if curl -fsSL --retry 3 "$FEED_URL/$filename" -o "$OUT_DIR/$filename"; then
      warn "Kept the previously published $filename for $package"
      return 0
    fi
  fi
  warn "No previously published copy of $package is available"
}

import_upstream() {
  local entry package repo pattern api=() name url digest tmp
  [[ -n "${GH_TOKEN:-}" ]] && api=(-H "Authorization: Bearer $GH_TOKEN")
  tmp=$(mktemp)
  while IFS= read -r entry; do
    package=$(jq -r .package <<<"$entry")
    repo=$(jq -r .repo <<<"$entry")
    pattern=$(jq -r .asset_pattern <<<"$entry")
    if ! curl -fsSL --retry 3 "${api[@]}" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "https://api.github.com/repos/$repo/releases/latest" -o "$tmp"; then
      warn "Could not query the latest $repo release"
      carry_over "$package"
      continue
    fi
    name=$(jq -r --arg re "$pattern" '[.assets[] | select(.name | test($re))] | first | .name // empty' "$tmp")
    if [[ -z "$name" ]]; then
      warn "The latest $repo release has no asset matching $pattern"
      carry_over "$package"
      continue
    fi
    url=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .browser_download_url' "$tmp")
    digest=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .digest // empty' "$tmp")
    [[ "$url" == https://github.com/"$repo"/* ]] || die "Unexpected download URL for $name: $url"
    if ! curl -fLsS --retry 3 "$url" -o "$OUT_DIR/debs/$name"; then
      warn "Could not download $name"
      carry_over "$package"
      continue
    fi
    if ! verify_digest "$OUT_DIR/debs/$name" "$digest"; then
      warn "$name: the release publishes no checksum, so the download is unverified"
    fi
    [[ "$(field "$OUT_DIR/debs/$name" Package)" == "$package" ]] || die "$name: Package field is not $package"
  done < <(jq -c '.[]' upstream.json)
  rm -f "$tmp"
}

# Keep only the newest $KEEP_VERSIONS versions of each package/architecture.
prune_old_versions() {
  local f pkg arch ver group
  declare -A groups=()
  for f in "$OUT_DIR"/debs/*.deb; do
    group="$(field "$f" Package) $(field "$f" Architecture)"
    groups[$group]+="$(field "$f" Version) $f"$'\n'
  done
  for group in "${!groups[@]}"; do
    local -a files=() versions=()
    while read -r ver f; do
      [[ -n "$f" ]] || continue
      versions+=("$ver"); files+=("$f")
    done <<<"${groups[$group]}"
    # selection sort, newest first, using dpkg's version ordering
    local i j n=${#files[@]}
    for ((i = 0; i < n; i++)); do
      for ((j = i + 1; j < n; j++)); do
        if dpkg --compare-versions "${versions[j]}" gt "${versions[i]}"; then
          ver=${versions[i]}; versions[i]=${versions[j]}; versions[j]=$ver
          f=${files[i]}; files[i]=${files[j]}; files[j]=$f
        fi
      done
    done
    for ((i = KEEP_VERSIONS; i < n; i++)); do
      log "Pruning ${files[i]} (superseded)"
      rm -f "${files[i]}"
    done
  done
}

write_release() {
  local archs file size
  archs=$(for f in debs/*.deb; do dpkg-deb -f "$f" Architecture; done | sort -u | paste -sd ' ' -)
  {
    cat <<RELEASE
Origin: poopware-laboratories
Label: Poop Labs APT Repository
Suite: stable
Codename: stable
Architectures: $archs
Components: main
Description: Debian and jailbreak packages maintained by poopware-laboratories
Date: $(date -Ru)
RELEASE
    local algo
    for algo in MD5Sum:md5sum SHA1:sha1sum SHA256:sha256sum; do
      printf '%s:\n' "${algo%%:*}"
      for file in Packages Packages.gz Packages.bz2 Packages.xz; do
        size=$(wc -c <"$file" | tr -d ' ')
        printf ' %s %s %s\n' "$(${algo##*:} "$file" | cut -d' ' -f1)" "$size" "$file"
      done
    done
  } >Release
}

sign_release() {
  local home pass=()
  home=$(mktemp -d)
  chmod 700 "$home"
  export GNUPGHOME=$home
  printf '%s\n' "$APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
  [[ -n "${APT_GPG_PASSPHRASE:-}" ]] && pass=(--pinentry-mode loopback --passphrase "$APT_GPG_PASSPHRASE")
  gpg --batch --yes --quiet "${pass[@]}" --clearsign -o InRelease Release
  gpg --batch --yes --quiet "${pass[@]}" --armor --detach-sign -o Release.gpg Release
  gpg --batch --yes --quiet --armor --export -o pooplabs.gpg.asc
  gpg --batch --yes --quiet --export -o pooplabs.gpg
  rm -rf "$home"
}

main() {
  shopt -s nullglob
  local repo_debs=(debs/*.deb)
  ((${#repo_debs[@]} > 0)) || die "No .deb packages found directly in debs/"
  validate_repo_debs

  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR/debs"
  cp "${repo_debs[@]}" "$OUT_DIR/debs/"
  [[ "$SKIP_UPSTREAM" == 1 ]] || import_upstream
  prune_old_versions

  local packages=("$OUT_DIR"/debs/*.deb)
  ((${#packages[@]} > 0)) || die "No .deb packages are available to publish"

  (
    cd "$OUT_DIR"
    dpkg-scanpackages --multiversion debs /dev/null >Packages 2>scan.log || { cat scan.log >&2; exit 1; }
    cat scan.log >&2
    rm scan.log
    [[ -s Packages ]] || die "dpkg-scanpackages produced an empty Packages file"
    gzip -9c Packages >Packages.gz
    bzip2 -9c Packages >Packages.bz2
    xz -9c Packages >Packages.xz
    write_release
    signed=0
    if [[ -n "${APT_GPG_PRIVATE_KEY:-}" ]]; then
      sign_release
      signed=1
    else
      warn "APT_GPG_PRIVATE_KEY is not set; publishing an unsigned feed"
    fi
    cp "$ROOT/CydiaIcon.png" CydiaIcon.png
    python3 "$ROOT/scripts/render-index.py" --packages Packages --url "$FEED_URL" \
      --signed "$signed" --template "$ROOT/scripts/index.template.html" >index.html
    touch .nojekyll
  )

  # Tell the workflow whether the package set differs from what is live.
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    local live changed=true
    live=$(curl -fsSL --retry 2 "$FEED_URL/Packages" 2>/dev/null | sha256sum | cut -d' ' -f1) || live=
    [[ "$live" == "$(sha256sum "$OUT_DIR/Packages" | cut -d' ' -f1)" ]] && changed=false
    echo "changed=$changed" >>"$GITHUB_OUTPUT"
  fi
  log "Feed written to $OUT_DIR"
}

main "$@"
