#!/usr/bin/env bats
# Self-update + release signature (1.0.0)

load helpers

setup() {
  pgctb_test_dirs
  # shellcheck disable=SC1091
  PGCTB_INSTALL_LIB_ONLY=1 source "${REPO_ROOT}/install.sh"
  eval "$(sed -n '/^pgctb_update() {/,/^}/p' "${REPO_ROOT}/install.sh")"
  T="$BATS_TEST_TMPDIR"
  PGCTB_INSTALL_DIR="${T}/opt/pgclocktb"
  PGCTB_BIN_LINK="${T}/bin/pgclock"
  PGCTB_LEGACY_BIN_LINK="${T}/bin/mrclock"
  PGCTB_LEGACY_INSTALL_DIR="${T}/opt/legacy"
  mkdir -p "${T}/opt"
  PGCTB_VERSION=1.0.0
  PGCTB_ASSUME_YES=1
}

make_tree() {
  # make_tree DIR VERSION
  mkdir -p "$1"
  cp -a "$REPO_ROOT/lib" "$REPO_ROOT/modules" "$REPO_ROOT/data" "$REPO_ROOT/install.sh" "$1/"
  echo "$2" >"$1/VERSION"
}

installed_version() { tr -d '[:space:]' <"${PGCTB_INSTALL_DIR}/VERSION"; }

@test "version comparison" {
  _pgctb_version_gt 1.0.1 1.0.0
  _pgctb_version_gt 1.10.0 1.9.9
  ! _pgctb_version_gt 1.0.0 1.0.0
  ! _pgctb_version_gt 0.10.0 1.0.0
}

@test "running from the installed tree never deletes it (regression)" {
  make_tree "${T}/src" 1.0.0
  _pgctb_install_persistent "${T}/src"
  _pgctb_install_persistent "$PGCTB_INSTALL_DIR"
  _pgctb_install_persistent "$PGCTB_INSTALL_DIR"
  _pgctb_have_tree "$PGCTB_INSTALL_DIR"
}

@test "update: up to date → nothing changes; check mode never installs" {
  make_tree "${T}/src" 1.0.0
  _pgctb_install_persistent "${T}/src"
  _pgctb_resolve_ref() { echo v1.0.0; }
  pgctb_update apply
  [ ! -d "${PGCTB_INSTALL_DIR}.prev" ]
  _pgctb_resolve_ref() { echo v1.1.0; }
  _pgctb_fetch_tree() { touch "${T}/fetched"; }
  pgctb_update check
  [ ! -f "${T}/fetched" ]
  [ "$(installed_version)" = 1.0.0 ]
}

@test "update installs the new tree atomically and rollback restores the old one" {
  make_tree "${T}/src" 1.0.0
  _pgctb_install_persistent "${T}/src"
  mkdir -p "${T}/pgclocktb-fetch.abc"
  make_tree "${T}/pgclocktb-fetch.abc/PGClockTB-v1.1.0" 1.1.0
  _pgctb_resolve_ref() { echo v1.1.0; }
  _pgctb_fetch_tree() { echo "${T}/pgclocktb-fetch.abc/PGClockTB-v1.1.0"; }
  pgctb_update apply
  [ "$(installed_version)" = 1.1.0 ]
  [ "$(tr -d '[:space:]' <"${PGCTB_INSTALL_DIR}.prev/VERSION")" = 1.0.0 ]
  [ ! -d "${T}/pgclocktb-fetch.abc" ]          # temp download cleaned up
  pgctb_update rollback
  [ "$(installed_version)" = 1.0.0 ]
}

@test "update refuses a tree with a syntax error or wrong version — installed tree untouched" {
  make_tree "${T}/src" 1.0.0
  _pgctb_install_persistent "${T}/src"
  _pgctb_resolve_ref() { echo v1.1.0; }
  mkdir -p "${T}/pgclocktb-fetch.x"
  make_tree "${T}/pgclocktb-fetch.x/t" 1.1.0
  echo 'if then fi (' >>"${T}/pgclocktb-fetch.x/t/lib/common.sh"
  _pgctb_fetch_tree() { echo "${T}/pgclocktb-fetch.x/t"; }
  run pgctb_update apply
  [ "$status" -ne 0 ]
  [ "$(installed_version)" = 1.0.0 ]
  mkdir -p "${T}/pgclocktb-fetch.y"
  make_tree "${T}/pgclocktb-fetch.y/t" 9.9.9
  _pgctb_fetch_tree() { echo "${T}/pgclocktb-fetch.y/t"; }
  run pgctb_update apply
  [ "$status" -ne 0 ]
  [ "$(installed_version)" = 1.0.0 ]
}

@test "update: failed download changes nothing" {
  make_tree "${T}/src" 1.0.0
  _pgctb_install_persistent "${T}/src"
  _pgctb_resolve_ref() { echo v1.1.0; }
  _pgctb_fetch_tree() { return 1; }
  run pgctb_update apply
  [ "$status" -ne 0 ]
  [ "$(installed_version)" = 1.0.0 ]
}

# --- signatures with real GnuPG ----------------------------------------------

gen_key() {
  # gen_key HOME NAME → prints fingerprint
  mkdir -p "$1" && chmod 700 "$1"
  gpg --homedir "$1" --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "$2 <$2@example.invalid>" ed25519 sign 1d >/dev/null 2>&1
  gpg --homedir "$1" --batch --with-colons --list-keys | awk -F: '/^fpr:/{print $10; exit}'
}

release_assets() {
  # release_assets DIR SIGNER_HOME → archive + SHA256SUMS (+ .asc when signer given)
  mkdir -p "$1"
  echo payload >"$1/PGClockTB-v1.1.0.tar.gz"
  (cd "$1" && sha256sum PGClockTB-v1.1.0.tar.gz >SHA256SUMS)
  if [[ -n "${2:-}" ]]; then
    gpg --homedir "$2" --batch --yes --pinentry-mode loopback --passphrase '' \
      --detach-sign -a -o "$1/SHA256SUMS.asc" "$1/SHA256SUMS" >/dev/null 2>&1
  fi
}

@test "pinned release key: good signature accepted, other key / missing .asc refused" {
  command -v gpg >/dev/null || skip "gpg missing"
  local rel att fp
  rel="${T}/gnupg-release"; att="${T}/gnupg-attacker"
  fp="$(gen_key "$rel" release)"
  gen_key "$att" attacker >/dev/null
  [ -n "$fp" ] || skip "gpg could not generate a key here"
  PGCTB_RELEASE_FPR="$fp"
  PGCTB_RELEASE_PUBKEY="$(gpg --homedir "$rel" --batch --armor --export "$fp")"
  release_assets "${T}/good" "$rel"
  _pgctb_verify_release_assets "${T}/good/PGClockTB-v1.1.0.tar.gz" v1.1.0 "${T}/good"
  release_assets "${T}/evil" "$att"
  run _pgctb_verify_release_assets "${T}/evil/PGClockTB-v1.1.0.tar.gz" v1.1.0 "${T}/evil"
  [ "$status" -ne 0 ]
  release_assets "${T}/nosig"
  run _pgctb_verify_release_assets "${T}/nosig/PGClockTB-v1.1.0.tar.gz" v1.1.0 "${T}/nosig"
  [ "$status" -ne 0 ]
}

@test "unpinned build: checksum enforced; signature not claimed; REQUIRE_SIGNATURE refuses" {
  PGCTB_RELEASE_FPR=""
  PGCTB_GPG_FINGERPRINT=""
  release_assets "${T}/a"
  run _pgctb_verify_release_assets "${T}/a/PGClockTB-v1.1.0.tar.gz" v1.1.0 "${T}/a"
  [ "$status" -eq 0 ]
  [[ "$output" != *"signature OK"* ]]
  echo tampered >"${T}/a/PGClockTB-v1.1.0.tar.gz"
  run _pgctb_verify_release_assets "${T}/a/PGClockTB-v1.1.0.tar.gz" v1.1.0 "${T}/a"
  [ "$status" -ne 0 ]
  release_assets "${T}/b"
  PGCTB_REQUIRE_SIGNATURE=1 run _pgctb_verify_release_assets "${T}/b/PGClockTB-v1.1.0.tar.gz" v1.1.0 "${T}/b"
  [ "$status" -ne 0 ]
}

@test "pin-release-key.sh embeds a key that then verifies releases (and can re-pin)" {
  command -v gpg >/dev/null || skip "gpg missing"
  local rel fp work
  rel="${T}/gnupg-pin"
  fp="$(gen_key "$rel" pin)"
  [ -n "$fp" ] || skip "gpg could not generate a key here"
  work="${T}/repo"
  mkdir -p "$work/scripts"
  cp "$REPO_ROOT/install.sh" "$work/"
  cp "$REPO_ROOT/scripts/pin-release-key.sh" "$work/scripts/"
  "$work/scripts/pin-release-key.sh" "$fp" --homedir "$rel"
  "$work/scripts/pin-release-key.sh" "$fp" --homedir "$rel"      # idempotent
  bash -n "$work/install.sh"
  [ "$(grep -c 'BEGIN PGP PUBLIC KEY BLOCK' "$work/install.sh")" -eq 1 ]
  # The pinned build verifies a release signed by that key
  PGCTB_RELEASE_FPR="" PGCTB_RELEASE_PUBKEY=""
  # shellcheck disable=SC1090
  PGCTB_INSTALL_LIB_ONLY=1 source "$work/install.sh"
  [ "$PGCTB_RELEASE_FPR" = "$fp" ]
  release_assets "${T}/rel" "$rel"
  _pgctb_verify_release_assets "${T}/rel/PGClockTB-v1.1.0.tar.gz" v1.1.0 "${T}/rel"
}
