#!/bin/sh
# Installs kurkik from the GitHub Releases of Pakisan/kurkik-app.
#
#   curl -fsSL <website>/install.sh | sh
#   curl -fsSL <website>/install.sh | sh -s -- --version=1.0.0-eap.1
#
# Options:
#   --version=VERSION   install this version (default: the one the website's version.txt names)
#   --no-path-update    leave shell configs and ~/.local/bin alone
#   --rewrite           unpack the version again even if it is already installed
#   --help              this text
#
# Environment:
#   KURKIK_VERSION      same as --version
#   KURKIK_HOME         where kurkik lives (default: ~/.kurkik)
#   KURKIK_VERSION_URL  where the current version is read from, instead of VERSION_URL below
#   KURKIK_BASE_URL     where the archive and checksums are fetched from instead of the GitHub release (for testing)
#
# Layout: $KURKIK_HOME/versions/<version>/, $KURKIK_HOME/current -> the active one, $KURKIK_HOME/bin/kurkik -> its launcher.
set -eu

REPO="Pakisan/kurkik-app"
# A plain text file holding the current version, e.g. 1.0.0-eap.1. Empty: ask the GitHub API for the newest release.
VERSION_URL="${KURKIK_VERSION_URL:-https://kurkik.pavelon.dev/version.txt}"
# The release key's primary fingerprint (40 hex digits) and where its public half is published. Only a signature made
# by exactly this key is accepted: a key already in the user's keyring, or one an attacker signs with, counts for
# nothing. Empty fingerprint = the key is not published yet, and the signature is not checked.
# (unset, not empty: an empty KURKIK_PGP_FINGERPRINT means "pin nothing", which the tests use)
PGP_FINGERPRINT="${KURKIK_PGP_FINGERPRINT-98E24FB7BBFF7ED258D5EAF1BFA6A9C8FBE45EDA}"
PGP_KEY_URL="${KURKIK_PGP_KEY_URL:-https://raw.githubusercontent.com/$REPO/master/kurkik-release.asc}"

HOME_DIR="${KURKIK_HOME:-$HOME/.kurkik}"
VERSIONS_DIR="$HOME_DIR/versions"
BIN_DIR="$HOME_DIR/bin"
ENV_POSIX="$HOME_DIR/env"
ENV_FISH="$HOME_DIR/env.fish"
# Already on PATH in many setups; a link there works in the terminal this script was started from.
LINK_DIR="$HOME/.local/bin"
MARKER="# Added by the kurkik installer"

VERSION="${KURKIK_VERSION:-}"
UPDATE_PATH=1
REWRITE=0

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'kurkik install: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
path_contains() { case ":$PATH:" in *":$1:"* | *":$1/:"*) return 0 ;; esac; return 1; }
show_path() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

usage() {
  cat <<'USAGE'
Usage: install.sh [--version=VERSION] [--no-path-update] [--rewrite] [--help]

  --version=VERSION   install this version (default: the one the website's version.txt names)
  --no-path-update    leave shell configs and ~/.local/bin alone
  --rewrite           unpack the version again even if it is already installed
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --version=*) VERSION="${arg#*=}" ;;
    --no-path-update) UPDATE_PATH=0 ;;
    --rewrite) REWRITE=1 ;;
    --help) usage; exit 0 ;;
    *) fail "unknown option $arg (try --help)" ;;
  esac
done
[ "$VERSION" = "latest" ] && VERSION=""

have curl || have wget || fail "curl or wget is required"
have unzip || fail "unzip is required"

work="$(mktemp -d)"
stage=""
trap 'rm -rf "$work" ${stage:+"$stage"}' EXIT INT TERM

# fetch URL FILE: on failure says why on stderr and returns 1, so a caller can decide whether it matters.
fetch() {
  _err="$work/fetch.err"
  _status=0
  if have curl; then
    curl -fsSL --max-time 300 -o "$2" "$1" 2>"$_err" || _status=$?
  else
    wget -nv -O "$2" "$1" 2>"$_err" || _status=$?
  fi
  [ "$_status" -eq 0 ] && return 0
  printf 'download failed: %s (exit %s)\n' "$1" "$_status" >&2
  [ -s "$_err" ] && sed -e 's/^/    /' -e '5q' "$_err" >&2
  return 1
}

case "$(uname -s)" in
  Darwin) os=osx ;;
  Linux) os=linux ;;
  *) fail "unsupported system $(uname -s); on Windows use Scoop or winget once published" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch=aarch_64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac
if [ "$os" = linux ] && ls /lib/ld-musl-* >/dev/null 2>&1 && [ ! -e /lib64/ld-linux-x86-64.so.2 ] && [ ! -e /lib/ld-linux-aarch64.so.1 ]; then
  fail "this looks like a musl system (Alpine); the bundled runtime needs glibc"
fi
platform="$os-$arch"

resolve_version() {
  if [ -n "$VERSION_URL" ] && fetch "$VERSION_URL" "$work/version.txt"; then
    _v="$(tr -d '[:space:]' <"$work/version.txt")"
    # Only a version id: an HTML error page must not become a path.
    if printf '%s' "$_v" | grep -qE '^[0-9][0-9A-Za-z.+-]*$'; then printf '%s' "$_v"; return 0; fi
    warn "$VERSION_URL did not hold a version; asking GitHub instead"
  fi
  # /releases/latest skips prereleases, and an EAP is one: take the newest of the list.
  fetch "https://api.github.com/repos/$REPO/releases?per_page=1" "$work/releases.json" || return 1
  sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' "$work/releases.json" | head -n 1
}

if [ -z "$VERSION" ]; then
  VERSION="$(resolve_version)" || true
  [ -n "$VERSION" ] || fail "could not find the current version; check your network or pass --version=<VERSION>"
fi
case "$VERSION" in *[!0-9A-Za-z.+-]* | "") fail "not a version: $VERSION" ;; esac

say "Platform: $platform"
say "Version:  $VERSION"
say "Into:     $(show_path "$HOME_DIR")"
say ""

# --- a kurkik that is already there -------------------------------------------------------------------------------

is_ours() {
  [ "$1" = "$BIN_DIR/kurkik" ] && return 0
  [ -L "$1" ] || return 1
  case "$(readlink "$1")" in "$HOME_DIR"/*) return 0 ;; esac
  return 1
}

existing="$(command -v kurkik 2>/dev/null || true)"
if [ -n "$existing" ] && ! is_ours "$existing"; then
  warn "another kurkik is already on your PATH: $existing"
  if have brew && brew list --formula kurkik >/dev/null 2>&1; then
    say "         It is Homebrew's; update that one with 'brew upgrade kurkik'. Two installs do not share updates."
  fi
  say "         Which one runs depends on PATH order: 'command -v kurkik' tells, 'kurkik version' shows its runtime."
  say ""
fi

# The PGP signature proves the archive is the author's. It needs gpg; with gpg and a pinned key it is required: a
# missing or bad signature stops the install. Checked in a keyring of its own, holding only the pinned key.
verify_signature() {
  if ! have gpg; then
    say "Signature not checked: gpg is not installed"
    return 0
  fi
  if [ -z "$PGP_FINGERPRINT" ]; then
    warn "signature not checked: this installer has no release key to check it against"
    return 0
  fi
  _gnupg="$work/gnupg"
  mkdir -m 700 "$_gnupg"
  fetch "$PGP_KEY_URL" "$work/release-key.asc" || fail "could not fetch the release key from $PGP_KEY_URL"
  gpg --homedir "$_gnupg" --batch --quiet --import "$work/release-key.asc" 2>/dev/null || fail "the release key could not be imported"
  gpg --homedir "$_gnupg" --batch --with-colons --fingerprint 2>/dev/null | grep '^fpr:' | grep -qi ":$PGP_FINGERPRINT:" ||
    fail "the key at $PGP_KEY_URL is not the release key (fingerprint $PGP_FINGERPRINT)"
  fetch "$base/$archive.asc" "$work/$archive.asc" 2>/dev/null || fail "no signature ($archive.asc) in release v$VERSION"
  _status="$(gpg --homedir "$_gnupg" --batch --status-fd 1 --verify "$work/$archive.asc" "$work/$archive" 2>/dev/null || true)"
  # VALIDSIG <signing key> ... <primary key fingerprint>: the last field is the key the release is pinned to.
  printf '%s\n' "$_status" | grep '^\[GNUPG:\] GOODSIG ' >/dev/null &&
    printf '%s\n' "$_status" | grep '^\[GNUPG:\] VALIDSIG ' | awk '{print $NF}' | grep -qi "^$PGP_FINGERPRINT\$" ||
    fail "the signature on $archive is not the release key's"
  say "Signature ok"
}

# --- download, verify, unpack -------------------------------------------------------------------------------------

final="$VERSIONS_DIR/$VERSION"
previous="$(basename "$(readlink "$HOME_DIR/current" 2>/dev/null || true)")"

if [ -d "$final" ] && [ "$REWRITE" -eq 0 ]; then
  say "kurkik $VERSION is already unpacked; switching to it (--rewrite unpacks it again)"
else
  archive="kurkik-$VERSION-$platform.zip"
  base="${KURKIK_BASE_URL:-https://github.com/$REPO/releases/download/v$VERSION}"

  say "Downloading $archive"
  fetch "$base/$archive" "$work/$archive" || fail "no $archive in release v$VERSION"

  # The checksum list JReleaser publishes next to the archives.
  fetch "$base/checksums_sha256.txt" "$work/checksums_sha256.txt" || fail "no checksums_sha256.txt in release v$VERSION"
  expected="$(grep " $archive\$" "$work/checksums_sha256.txt" | awk '{print $1}' | head -n 1)"
  [ -n "$expected" ] || fail "$archive is not in checksums_sha256.txt"
  if have sha256sum; then actual="$(sha256sum "$work/$archive" | awk '{print $1}')"; else actual="$(shasum -a 256 "$work/$archive" | awk '{print $1}')"; fi
  [ "$expected" = "$actual" ] || fail "checksum mismatch for $archive"
  say "Checksum ok"

  verify_signature

  # Unpacked beside its destination, then renamed into place: a running install never sees half a directory.
  mkdir -p "$VERSIONS_DIR"
  stage="$VERSIONS_DIR/.new.$$"
  rm -rf "$stage"
  mkdir "$stage"
  unzip -q "$work/$archive" -d "$stage"
  # The archive holds one directory, kurkik-<version>-<platform>.
  inner="$(ls "$stage" | head -n 1)"
  [ -x "$stage/$inner/bin/kurkik" ] || fail "$archive does not hold bin/kurkik"
  [ "$REWRITE" -eq 1 ] && rm -rf "$final"
  mv "$stage/$inner" "$final"
  rmdir "$stage"
  stage=""
fi

# --- switch to it -------------------------------------------------------------------------------------------------

ln -sfn "versions/$VERSION" "$HOME_DIR/current"
mkdir -p "$BIN_DIR"
ln -sfn "$HOME_DIR/current/bin/kurkik" "$BIN_DIR/kurkik"

# Older versions go; the one before this stays, to go back to.
for dir in "$VERSIONS_DIR"/*; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  [ "$name" = "$VERSION" ] || [ "$name" = "$previous" ] || rm -rf "$dir"
done

# --- PATH ---------------------------------------------------------------------------------------------------------

# Activation snippets the shell configs source; safe to source again, and a deleted $HOME_DIR leaves the configs harmless.
{
  echo "$MARKER"
  echo "# Activation snippet for POSIX shells (bash, zsh, sh, dash, ksh). Safe to source again."
  printf 'case ":$PATH:" in\n    *":%s:"*) ;;\n    *) export PATH="$PATH:%s" ;;\nesac\n' "$BIN_DIR" "$BIN_DIR"
} >"$ENV_POSIX"
{
  echo "$MARKER"
  echo "# Activation snippet for fish. Safe to source again."
  printf 'if not contains -- "%s" $PATH\n    set -gx PATH $PATH "%s"\nend\n' "$BIN_DIR" "$BIN_DIR"
} >"$ENV_FISH"

# Whether a shell config already sources one of the snippets, by absolute, ~/ or $HOME/ path.
mentions_install() {
  [ -f "$1" ] || return 1
  for _f in "$ENV_POSIX" "$ENV_FISH"; do
    grep -qF -e "$_f" "$1" 2>/dev/null && return 0
    case "$_f" in
      "$HOME"/*)
        grep -qF -e "~${_f#"$HOME"}" "$1" 2>/dev/null && return 0
        grep -qF -e "\$HOME${_f#"$HOME"}" "$1" 2>/dev/null && return 0
        ;;
    esac
  done
  return 1
}

updated=""
configured=""
note_file() {
  case " $updated $configured " in *" $2 "*) return 0 ;; esac
  case "$1" in updated) updated="$updated $2" ;; *) configured="$configured $2" ;; esac
}

add_posix_source() {
  if mentions_install "$1"; then note_file configured "$1"; return 0; fi
  mkdir -p "$(dirname "$1")"
  printf '\n%s\nif [ -f "%s" ]; then\n    . "%s"\nfi\n' "$MARKER" "$ENV_POSIX" "$ENV_POSIX" >>"$1"
  note_file updated "$1"
}

add_fish_source() {
  _file="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/kurkik.fish"
  if mentions_install "$_file"; then note_file configured "$_file"; return 0; fi
  mkdir -p "$(dirname "$_file")"
  printf '%s\nif test -f "%s"\n    source "%s"\nend\n' "$MARKER" "$ENV_FISH" "$ENV_FISH" >"$_file"
  note_file updated "$_file"
}

# The login file bash reads: a new ~/.bash_profile would hide a ~/.profile created later.
bash_login_file() {
  for _c in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    [ -f "$_c" ] && { printf '%s' "$_c"; return 0; }
  done
  printf '%s' "$HOME/.profile"
}

manual=""
update_path() {
  shells=" "
  _login="$(basename "${SHELL:-}")"
  [ -n "$_login" ] && shells="$shells$_login "
  [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/fish" ] && shells="${shells}fish "
  [ -f "${ZDOTDIR:-$HOME}/.zshrc" ] && shells="${shells}zsh "
  { [ -f "$HOME/.bashrc" ] || [ -f "$HOME/.bash_profile" ] || [ -f "$HOME/.bash_login" ]; } && shells="${shells}bash "
  [ -f "$HOME/.profile" ] && shells="${shells}sh "

  for shell in $shells; do
    case "$shell" in
      fish) add_fish_source ;;
      zsh) add_posix_source "${ZDOTDIR:-$HOME}/.zshrc" ;;
      bash)
        add_posix_source "$(bash_login_file)"
        add_posix_source "$HOME/.bashrc"
        ;;
      sh | dash | ash | ksh | ksh93 | mksh) add_posix_source "$HOME/.profile" ;;
      *) manual="$manual $shell" ;;
    esac
  done
  # Nothing known: ~/.profile is read by every login shell that follows POSIX.
  [ -z "$updated$configured" ] && add_posix_source "$HOME/.profile"
  return 0
}

linked=0
if [ "$UPDATE_PATH" -eq 1 ]; then
  if path_contains "$BIN_DIR"; then
    say "$(show_path "$BIN_DIR") is already in PATH"
  else
    update_path
    for f in $updated; do say "Updated $(show_path "$f")"; done
    for f in $configured; do say "$(show_path "$f") is already set up"; done
    for s in $manual; do warn "cannot set up PATH for '$s'; add $BIN_DIR to it yourself"; done
  fi

  # A link where PATH already looks makes it work in this terminal. Only our own earlier link is replaced.
  if path_contains "$LINK_DIR" && ! path_contains "$BIN_DIR"; then
    link="$LINK_DIR/kurkik"
    if [ -L "$link" ] && ! is_ours "$link" ; then
      warn "not linking $(show_path "$link"): it points to $(readlink "$link")"
    elif [ -e "$link" ] && [ ! -L "$link" ]; then
      warn "not linking $(show_path "$link"): a file with that name already exists"
    else
      mkdir -p "$LINK_DIR"
      ln -sfn "$BIN_DIR/kurkik" "$link"
      say "Linked $(show_path "$link")"
      linked=1
    fi
  fi
fi

# --- done ---------------------------------------------------------------------------------------------------------

say ""
started="$("$BIN_DIR/kurkik" --version 2>/dev/null)" || warn "kurkik was installed but did not start; try '$BIN_DIR/kurkik doctor'"
say "Installed kurkik $VERSION"
# A time-limited release says when it stops working, which somebody installing it late should know before relying on it.
ends="$(printf '%s\n' "${started:-}" | sed -n 's/^ends: //p' | head -n 1)"
if [ -n "$ends" ]; then
  say "It is a time-limited release: it stops working at $ends. A newer one comes out before then."
fi
if path_contains "$BIN_DIR" || [ "$linked" -eq 1 ]; then
  say "Run: kurkik --help"
else
  case "$(basename "${SHELL:-sh}")" in
    fish) activate="source $(show_path "$ENV_FISH")" ;;
    *) activate=". $(show_path "$ENV_POSIX")" ;;
  esac
  say "To use it in this terminal, run: $activate"
  say "Then: kurkik --help"
fi
