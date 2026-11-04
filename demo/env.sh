# Source this for a demo shell: the installed kurkik, with its own files under demo/.state rather than in your home -
# the user connections file, the trust records, the keychain index. Your ~/.config/kurkik is not read or written.
#
#   source demo/env.sh
if [ -n "${ZSH_VERSION:-}" ]; then here=${(%):-%x}; else here=${BASH_SOURCE[0]}; fi
KURKIK_DEMO=$(cd "$(dirname "$here")" && pwd)
export KURKIK_DEMO
export KURKIK_CONFIG="$KURKIK_DEMO/.state/connections.yaml"
export XDG_CONFIG_HOME="$KURKIK_DEMO/.state/config"
# Where a sync keeps the snapshot and the rollback it writes before changing anything.
export XDG_STATE_HOME="$KURKIK_DEMO/.state/state"
# LocalStack takes any secret key; the access key id, in the connections file, picks the account.
export KURKIK_DEMO_SECRET=test

unset here
# The installed one, from install.sh (~/.kurkik/bin, linked into ~/.local/bin when that is on the PATH).
if [ -x "$HOME/.kurkik/bin/kurkik" ] && ! command -v kurkik > /dev/null; then PATH="$HOME/.kurkik/bin:$PATH"; export PATH; fi
if command -v kurkik > /dev/null; then
  kurkik version 2> /dev/null | head -n 2
else
  echo "kurkik is not installed. Install it, then source this again:" >&2
  echo "  curl -fsSL https://kurkik.pavelon.dev/install.sh | sh" >&2
  return 1 2> /dev/null || exit 1
fi
