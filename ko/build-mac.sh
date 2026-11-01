#!/usr/bin/env bash
# Build, sign, notarize, and publish the Korean "Buzz KO" macOS app.
#
# Fork-only (dalsoop/buzz, branch `korean`). Reuses upstream's isolated demo
# build identity so Buzz KO installs beside the official Buzz without sharing
# its bundle ID, keychain entries, deep-link scheme, nest, or CLI name.
#
# Signing follows the usual Mac release setup: Developer ID from the login
# keychain, notarization through the existing "swift-app-mono" notarytool
# profile, and the updater private key delivered by sops from
# principal-secrets-mono (Bitwarden is the source of truth).
#
# One-time setup on the build Mac:
#   ko/build-mac.sh setup
#     - generates the Tauri updater key pair once, writes the public key to
#       ko/updater.pub, and tells you how to store the private key
#
# Each release:
#   ko/build-mac.sh build [version]     # build + sign + notarize -> ko/dist/
#   ko/build-mac.sh publish [version]   # upload ko/dist/ to GitHub Releases
#
# `version` defaults to desktop/package.json. Auto-update only installs a
# strictly higher semver, so a rebuild of the same upstream version needs a
# higher one (e.g. 0.5.29 after 0.5.28).

set -euo pipefail

REPO="dalsoop/buzz"
DEMO_NAME="KO"
# Fixed so every build keeps the same bundle ID and app data. Never change it:
# a new value makes macOS treat the next build as a different app.
BUILD_ID="71b620b49469dd59"
LATEST_TAG="buzz-ko-latest"
# The community relay Buzz KO connects to on first launch (same as the
# official app on our Macs). Without it the app falls back to ws://localhost:3000.
KO_RELAY_URL="${BUZZ_KO_RELAY_URL:-wss://buzz.ranode.net}"
UPDATER_ENDPOINT="https://github.com/$REPO/releases/download/$LATEST_TAG/latest.json"
NOTARY_PROFILE="${BUZZ_KO_NOTARY_PROFILE:-swift-app-mono}"
SECRETS_REPO="${BUZZ_KO_SECRETS_REPO:-$HOME/Documents/workspace/gitlab-saas/gujoai/infra/principal-secrets-mono}"
UPDATER_SECRET="secrets/macbook-tools/buzz-ko-tauri-updater-key.enc.yaml"
SOPS_IDENTITY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/macbook-se.txt}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/ko/dist"
UPDATER_PUB="$ROOT/ko/updater.pub"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "macOS에서 실행해야 해요 (Mac app builds need macOS)"
}

target_triple() {
  case "$(uname -m)" in
    arm64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

resolve_version() {
  local version="${1:-}"
  [[ -n "$version" ]] || version="$(node -p "require('./desktop/package.json').version")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z, got '$version'"
  echo "$version"
}

signing_identity() {
  local identity
  identity="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
  [[ -n "$identity" ]] || die "keychain has no 'Developer ID Application' certificate"
  echo "$identity"
}

# Decrypt one field of the updater secret. Values only ever go to stdout for
# capture; they never reach argv, logs, or the terminal.
updater_secret_field() {
  SOPS_AGE_KEY_FILE="$SOPS_IDENTITY" \
    sops decrypt --extract "[\"$1\"]" "$SECRETS_REPO/$UPDATER_SECRET"
}

cmd_setup() {
  require_macos
  echo "Signing identity: $(signing_identity)"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || die "notarytool keychain profile '$NOTARY_PROFILE' missing"
  echo "Notarization profile: $NOTARY_PROFILE"

  if [[ -f "$SECRETS_REPO/$UPDATER_SECRET" ]]; then
    [[ -f "$UPDATER_PUB" ]] || die "secret exists but ko/updater.pub is missing"
    updater_secret_field value >/dev/null || die "cannot decrypt $UPDATER_SECRET"
    echo "Updater key: $UPDATER_SECRET (decrypts OK)"
    echo "Setup complete."
    return
  fi

  [[ ! -f "$UPDATER_PUB" ]] || die "ko/updater.pub exists but $UPDATER_SECRET does not"
  # shellcheck disable=SC1091
  . ./bin/activate-hermit
  (cd desktop && pnpm install --frozen-lockfile)
  # Global so the EXIT trap still sees it after this function returns.
  SETUP_TMP="$(mktemp -d)"
  trap 'rm -rf "$SETUP_TMP"' EXIT
  local tmp="$SETUP_TMP"
  echo "Generating the Tauri updater key pair. Choose a password."
  (cd desktop && pnpm tauri signer generate -w "$tmp/updater.key")
  cp "$tmp/updater.key.pub" "$UPDATER_PUB"
  cat <<EOM

Public key written to ko/updater.pub — commit it on the korean branch.

Store the private key before this shell exits (the temp copy is deleted):
  1. Bitwarden: new item "buzz-ko tauri updater key" with fields
       value    = contents of $tmp/updater.key
       password = the password you just chose
  2. In $SECRETS_REPO:
       environment-secret-broker sync   ->  $UPDATER_SECRET
       (and the matching principals/sources.json entries)
Press Enter when both are done.
EOM
  read -r
  updater_secret_field value >/dev/null || die "cannot decrypt $UPDATER_SECRET yet"
  echo "Setup complete."
}

cmd_build() {
  require_macos
  local version target identity product app_dir app dmg arch config
  version="$(resolve_version "${1:-}")"
  target="$(target_triple)"
  identity="$(signing_identity)"
  [[ -f "$UPDATER_PUB" ]] || die "ko/updater.pub missing; run '$0 setup' first"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || die "notarytool keychain profile '$NOTARY_PROFILE' missing"
  TAURI_SIGNING_PRIVATE_KEY="$(updater_secret_field value)" \
    || die "cannot decrypt $UPDATER_SECRET; run '$0 setup' first"
  TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$(updater_secret_field password)" \
    || die "cannot decrypt the password field of $UPDATER_SECRET"
  export TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD

  # shellcheck disable=SC1091
  . ./bin/activate-hermit
  just desktop-install-ci

  # Version is patched only for this build and restored afterwards.
  local restore=(desktop/package.json desktop/src-tauri/tauri.conf.json desktop/src-tauri/Cargo.toml desktop/src-tauri/Cargo.lock)
  trap 'git checkout -- "${restore[@]}" 2>/dev/null || true' EXIT
  (cd desktop && node scripts/set-version-from-tag.mjs "$version")

  config="$(mktemp "${TMPDIR:-/tmp}/buzz-ko-config.XXXXXX")"
  local identity_json
  identity_json="$(node desktop/scripts/demo-build-config.mjs "$DEMO_NAME" "$config" "$BUILD_ID")"
  local slug
  slug="$(node -e 'console.log(JSON.parse(process.argv[1]).slug)' "$identity_json")"
  product="$(node -e 'console.log(JSON.parse(process.argv[1]).productName)' "$identity_json")"
  # Layer the release-only settings (updater, minimum macOS) on the KO identity.
  node -e '
    const fs = require("node:fs");
    const [path, pubkey, endpoint] = process.argv.slice(1);
    const c = JSON.parse(fs.readFileSync(path, "utf8"));
    c.bundle = { ...c.bundle, createUpdaterArtifacts: true, macOS: { minimumSystemVersion: "10.15" } };
    c.plugins = { ...c.plugins, updater: { pubkey, endpoints: [endpoint] } };
    fs.writeFileSync(path, JSON.stringify(c, null, 2) + "\n");
  ' "$config" "$(cat "$UPDATER_PUB")" "$UPDATER_ENDPOINT"

  cargo build --release --target "$target" \
    -p buzz-acp -p buzz-agent -p buzz-backend-kubernetes -p buzz-dev-mcp \
    -p git-credential-nostr -p buzz-cli
  ./scripts/bundle-sidecars.sh "$target"

  (
    cd desktop
    BUZZ_BUILD_DEMO_SLUG="$slug" \
    VITE_BUZZ_DEFAULT_LANGUAGE=ko \
    BUZZ_RELAY_URL="$KO_RELAY_URL" \
    BUZZ_BUILD_AUTO_CONNECT_DEFAULT_RELAY=1 \
    BUZZ_UPDATER_PUBLIC_KEY="$(cat "$UPDATER_PUB")" \
    BUZZ_UPDATER_ENDPOINT="$UPDATER_ENDPOINT" \
    CMAKE_POLICY_VERSION_MINIMUM=3.5 \
    MACOSX_DEPLOYMENT_TARGET=10.15 \
    CMAKE_OSX_DEPLOYMENT_TARGET=10.15 \
      pnpm tauri build --features mesh-llm --target "$target" \
        --bundles app --no-sign --config "$config"
  )
  rm -f "$config"

  app_dir="desktop/src-tauri/target/$target/release/bundle/macos"
  app="$app_dir/$product.app"
  [[ -d "$app" ]] || die "app bundle not found: $app"

  # The checked-in Info.plist names the app "Buzz"; give the bundle its own name.
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $product" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $product" "$app/Contents/Info.plist"

  # Sign nested executables first, then the bundle, all with hardened runtime.
  while IFS= read -r -d '' bin; do
    codesign --force --timestamp --options runtime \
      --entitlements desktop/src-tauri/Entitlements.plist \
      --sign "$identity" "$bin"
  done < <(find "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources" \
             -type f \( -perm -u+x -o -name '*.dylib' \) -print0 2>/dev/null)
  codesign --force --timestamp --options runtime \
    --entitlements desktop/src-tauri/Entitlements.plist \
    --sign "$identity" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  desktop/scripts/verify-macos-entitlements.sh "$app"

  arch="${target%%-*}"; [[ "$arch" == "x86_64" ]] && arch=x64
  rm -rf "$DIST" && mkdir -p "$DIST"
  dmg="$DIST/Buzz_KO_${version}_${arch}.dmg"
  VOL_NAME="$product" desktop/scripts/package-macos-dmg.sh "$app" "$dmg"
  codesign --force --timestamp --sign "$identity" "$dmg"

  echo "Notarizing (this can take several minutes)…"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  # Staple the app too, so the updater archive passes Gatekeeper offline.
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=4 "$app"

  # Updater archive from the signed, stapled app, signed with the updater key.
  local archive="$DIST/Buzz_KO_${version}_${arch}.app.tar.gz"
  (cd "$app_dir" && tar -czf "$archive" "$product.app")
  (cd desktop && pnpm tauri signer sign "$archive")

  node -e '
    const fs = require("node:fs");
    const [dist, version, arch, repo, archive] = process.argv.slice(1);
    const name = require("node:path").basename(archive);
    const platform = arch === "x64" ? "darwin-x86_64" : "darwin-aarch64";
    fs.writeFileSync(`${dist}/latest.json`, JSON.stringify({
      version,
      pub_date: new Date().toISOString(),
      platforms: {
        [platform]: {
          signature: fs.readFileSync(`${archive}.sig`, "utf8").trim(),
          url: `https://github.com/${repo}/releases/download/ko-v${version}/${name}`,
        },
      },
    }, null, 2) + "\n");
  ' "$DIST" "$version" "$arch" "$REPO" "$archive"

  echo
  echo "Built $product $version:"
  ls -1 "$DIST"
}

# Unsigned-for-distribution build for trying Buzz KO on our own Macs: ad-hoc
# signature, no notarization, no updater. Same identity as the real build, so
# a later signed install replaces it in place.
cmd_test_build() {
  require_macos
  local target product app config identity_json slug
  target="$(target_triple)"
  # shellcheck disable=SC1091
  . ./bin/activate-hermit
  just desktop-install-ci

  config="$(mktemp "${TMPDIR:-/tmp}/buzz-ko-config.XXXXXX")"
  identity_json="$(node desktop/scripts/demo-build-config.mjs "$DEMO_NAME" "$config" "$BUILD_ID")"
  slug="$(node -e 'console.log(JSON.parse(process.argv[1]).slug)' "$identity_json")"
  product="$(node -e 'console.log(JSON.parse(process.argv[1]).productName)' "$identity_json")"

  cargo build --release --target "$target" \
    -p buzz-acp -p buzz-agent -p buzz-backend-kubernetes -p buzz-dev-mcp \
    -p git-credential-nostr -p buzz-cli
  ./scripts/bundle-sidecars.sh "$target"
  (
    cd desktop
    BUZZ_BUILD_DEMO_SLUG="$slug" \
    VITE_BUZZ_DEFAULT_LANGUAGE=ko \
    BUZZ_RELAY_URL="$KO_RELAY_URL" \
    BUZZ_BUILD_AUTO_CONNECT_DEFAULT_RELAY=1 \
    CMAKE_POLICY_VERSION_MINIMUM=3.5 \
      pnpm tauri build --features mesh-llm --target "$target" \
        --bundles app --no-sign --config "$config"
  )
  rm -f "$config"

  app="desktop/src-tauri/target/$target/release/bundle/macos/$product.app"
  [[ -d "$app" ]] || die "app bundle not found: $app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $product" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $product" "$app/Contents/Info.plist"
  codesign --force --deep --sign - "$app"
  codesign --verify --deep --strict "$app"

  mkdir -p "$ROOT/ko/dist-test"
  rm -f "$ROOT/ko/dist-test/Buzz_KO_test.zip"
  ditto -c -k --keepParent "$app" "$ROOT/ko/dist-test/Buzz_KO_test.zip"
  echo "Built $ROOT/ko/dist-test/Buzz_KO_test.zip"
}

cmd_publish() {
  local version tag
  version="$(resolve_version "${1:-}")"
  tag="ko-v$version"
  [[ -f "$DIST/latest.json" ]] || die "nothing to publish; run '$0 build' first"
  grep -q "\"version\": \"$version\"" "$DIST/latest.json" \
    || die "ko/dist was built for a different version"

  gh release create "$tag" -R "$REPO" --target korean \
    --title "Buzz KO $version" \
    --notes "Korean build of Buzz $version. Download the .dmg and drag Buzz KO to Applications." \
    "$DIST"/*.dmg "$DIST"/*.app.tar.gz "$DIST"/*.app.tar.gz.sig

  # The installed apps poll this fixed tag for latest.json.
  gh release view "$LATEST_TAG" -R "$REPO" >/dev/null 2>&1 \
    || gh release create "$LATEST_TAG" -R "$REPO" --target korean --prerelease \
         --title "Buzz KO update feed" --notes "Auto-update manifest for Buzz KO."
  gh release upload "$LATEST_TAG" -R "$REPO" --clobber "$DIST/latest.json"

  echo "Published https://github.com/$REPO/releases/tag/$tag"
}

case "${1:-}" in
  setup) cmd_setup ;;
  build) cmd_build "${2:-}" ;;
  test-build) cmd_test_build ;;
  publish) cmd_publish "${2:-}" ;;
  *) echo "Usage: $0 setup | build [version] | test-build | publish [version]" >&2; exit 2 ;;
esac
