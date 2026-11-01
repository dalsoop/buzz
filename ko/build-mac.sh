#!/usr/bin/env bash
# Build, sign, notarize, and publish the Korean "Buzz KO" macOS app.
#
# Fork-only (dalsoop/buzz, branch `korean`). Reuses upstream's isolated demo
# build identity so Buzz KO installs beside the official Buzz without sharing
# its bundle ID, keychain entries, deep-link scheme, nest, or CLI name.
#
# One-time setup on the build Mac:
#   ko/build-mac.sh setup
#     - creates the Tauri updater key in ~/.buzz-ko/ (keep it; losing it means
#       installed apps can no longer auto-update)
#     - stores notarization credentials in the keychain profile "buzz-ko"
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
UPDATER_ENDPOINT="https://github.com/$REPO/releases/download/$LATEST_TAG/latest.json"
KEY_DIR="$HOME/.buzz-ko"
UPDATER_KEY="$KEY_DIR/updater.key"
NOTARY_PROFILE="buzz-ko"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/ko/dist"
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

cmd_setup() {
  require_macos
  mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
  # shellcheck disable=SC1091
  . ./bin/activate-hermit
  (cd desktop && pnpm install --frozen-lockfile)

  if [[ -f "$UPDATER_KEY" ]]; then
    echo "Updater key already exists: $UPDATER_KEY"
  else
    echo "Creating the updater signing key. Choose a password and keep it safe."
    (cd desktop && pnpm tauri signer generate -w "$UPDATER_KEY")
    chmod 600 "$UPDATER_KEY"
  fi

  echo
  echo "Signing identity: $(signing_identity)"
  echo
  echo "Storing notarization credentials in keychain profile '$NOTARY_PROFILE'."
  echo "Use an App Store Connect API key (.p8) or an Apple ID app-specific password."
  xcrun notarytool store-credentials "$NOTARY_PROFILE"
  echo
  echo "Setup complete. Back up $KEY_DIR somewhere safe."
}

cmd_build() {
  require_macos
  local version target identity product app_dir app dmg arch config
  version="$(resolve_version "${1:-}")"
  target="$(target_triple)"
  identity="$(signing_identity)"
  [[ -f "$UPDATER_KEY" && -f "$UPDATER_KEY.pub" ]] || die "run '$0 setup' first"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || die "notarization profile '$NOTARY_PROFILE' missing; run '$0 setup'"
  [[ -n "${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}" ]] || {
    read -rsp "Updater key password: " TAURI_SIGNING_PRIVATE_KEY_PASSWORD; echo
    export TAURI_SIGNING_PRIVATE_KEY_PASSWORD
  }
  export TAURI_SIGNING_PRIVATE_KEY="$UPDATER_KEY"

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
  ' "$config" "$(cat "$UPDATER_KEY.pub")" "$UPDATER_ENDPOINT"

  cargo build --release --target "$target" \
    -p buzz-acp -p buzz-agent -p buzz-backend-kubernetes -p buzz-dev-mcp \
    -p git-credential-nostr -p buzz-cli
  ./scripts/bundle-sidecars.sh "$target"

  (
    cd desktop
    BUZZ_BUILD_DEMO_SLUG="$slug" \
    BUZZ_UPDATER_PUBLIC_KEY="$(cat "$UPDATER_KEY.pub")" \
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
  publish) cmd_publish "${2:-}" ;;
  *) echo "Usage: $0 setup | build [version] | publish [version]" >&2; exit 2 ;;
esac
