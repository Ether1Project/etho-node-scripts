#!/usr/bin/env bash
# Etho Protocol v3.0.0 upgrade for Debian/Ubuntu.
# Usage: bash upgrade-debian.sh -n gatewaynode -u USER_TOKEN -w WALLET_ADDRESS
set -euo pipefail

if [[ $(uname -m) != x86_64 || $(getconf LONG_BIT) != 64 ]]; then
  echo 'This Etho Protocol release requires 64-bit x86 Linux (AMD64).' >&2
  exit 1
fi

_user="${SUDO_USER:-$(id -un)}"
_group="$(id -gn "$_user")"
_home="$(getent passwd "$_user" | cut -d: -f6)"
_nodetype=""
_usertoken=""
_wallet=""

if [[ -z "$_home" || "$_home" != /* || "$_home" == / ]]; then
  echo "Unable to resolve the node user's home directory." >&2
  exit 1
fi

while getopts ":n:u:w:" opt; do
  case $opt in
    n) _nodetype="$OPTARG"
    ;;
    u) _usertoken="$OPTARG"
    ;;
    w) _wallet="$OPTARG"
    ;;
    :) echo "Option -$OPTARG requires an argument" >&2
    exit 1
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    exit 1
    ;;
  esac

  case $OPTARG in
    -*) echo "Option $opt needs a valid argument"
    exit 1
    ;;
  esac
done
shift "$((OPTIND - 1))"

if [[ $# -ne 0 || -z "$_usertoken" || -z "$_wallet" ]]; then
  echo "Usage: bash upgrade-debian.sh -n gatewaynode|masternode|servicenode -u USER_TOKEN -w WALLET_ADDRESS" >&2
  exit 1
fi
case "$_nodetype" in
  gatewaynode|masternode|servicenode) ;;
  *) echo "Invalid node type: $_nodetype" >&2; exit 1 ;;
esac
# Values are embedded in systemd ExecStart below; reject ambiguous characters.
for value in "$_home" "$_usertoken" "$_wallet"; do
  if [[ "$value" == *[[:space:]\"\\%\$\']* ]]; then
    echo "Home, token and wallet must not contain whitespace, quotes, backslashes, percent or dollar signs." >&2
    exit 1
  fi
done
if [[ -d "$_home/.ether1" && -d "$_home/.etho" ]]; then
  echo "Both .ether1 and .etho exist; resolve the active data directory before upgrading." >&2
  exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"

if [ "$_nodetype" = "gatewaynode" ] ; then
  echo "ethoFS Gateway Node Setup Initiated"
fi
if [ "$_nodetype" = "masternode" ] ; then
  echo "ethoFS Masternode Setup Initiated"
fi
if [ "$_nodetype" = "servicenode" ] ; then
  echo "ethoFS Service Node Setup Initiated"
fi

echo '**************************'
echo 'Installing misc dependencies'
echo '**************************'
# install dependencies
sudo apt-get update
sudo apt-get install systemd libcap2-bin ca-certificates wget procps -y

echo '**************************'
echo 'Installing ETHO Protocol Node binary'
echo '**************************'
# Allow a local geth beside this script for offline installs.
# Stage the binary before stopping any services.
LOCAL_GETH="$script_dir/geth"
if [[ -f "$LOCAL_GETH" && ! -L "$LOCAL_GETH" ]]; then
  echo "Using local geth binary from $LOCAL_GETH"
  cp -- "$LOCAL_GETH" "$work_dir/geth"
else
  geth_archive="$work_dir/etho-linux-3.0.0.tar.gz"
  wget -O "$geth_archive" https://github.com/Ether1Project/Ethoprotocol/releases/download/V3.0.0/etho-linux-3.0.0.tar.gz
  printf '%s  %s\n' '2dc4aa2d37ac4bad6241c5d0352e2ce6468abfa6cd6f83ec696e24dc06624783' "$geth_archive" | sha256sum -c -
  tar -xzf "$geth_archive" -C "$work_dir" --no-same-owner geth
fi

[[ -f "$work_dir/geth" && ! -L "$work_dir/geth" ]] || {
  echo "The v3 download does not contain a regular geth binary." >&2
  exit 1
}
chmod +x "$work_dir/geth"
# DefaultDataDir can rename .ether1 even for 'version'; use an isolated HOME.
mkdir "$work_dir/probe"
env HOME="$work_dir/probe" "$work_dir/geth" version > "$work_dir/version"
if ! grep -Eq '^Version: 3\.0\.0([-.]|$)' "$work_dir/version"; then
  echo "The downloaded geth binary is not v3.0.0." >&2
  exit 1
fi

existing_repo="$_home/.etho/ethofs"
if [[ -d "$_home/.ether1" ]]; then
  existing_repo="$_home/.ether1/ethofs"
fi
migration_binary=""
if [[ -f "$existing_repo/config" ]]; then
  [[ -f "$existing_repo/version" ]] || {
    echo "Existing ethoFS repository has no version file; refusing to reinitialize it." >&2
    exit 1
  }
  repo_version=$(cat "$existing_repo/version")
  if [[ "$repo_version" == 11 ]]; then
    # Prefer an offline tool beside this script, just like the local geth.
    # Stage the tool before stopping any services.
    local_migration="$script_dir/fs-repo-11-to-12"
    if [[ -f "$local_migration" && ! -L "$local_migration" ]]; then
      echo "Using local ethoFS migration tool from $local_migration"
      cp -- "$local_migration" "$work_dir/fs-repo-11-to-12"
      migration_binary="$work_dir/fs-repo-11-to-12"
    else
      migration_archive="$work_dir/ethoprotocol-migration-linux-amd64.tar.gz"
      migration_url='https://github.com/Ether1Project/etho-node-scripts/releases/download/v1.0.0/ethoprotocol-migration-linux-amd64.tar.gz'
      echo 'Preparing ethoFS repository migration (11 -> 12)'
      if ! timeout 45 wget --timeout=15 --tries=2 -O "$migration_archive" "$migration_url"; then
        echo 'Migration download unavailable. Put fs-repo-11-to-12 beside this script and rerun.' >&2
        exit 1
      fi
      printf '%s  %s\n' '635a4841b9338eec9aebebb5321515a6a298ba125d8ae0c3292a21802e2be9ba' "$migration_archive" | sha256sum -c -
      # The release also bundles an installer. Extract only the migration tool.
      tar -xzf "$migration_archive" -C "$work_dir" --no-same-owner fs-repo-11-to-12
      migration_binary="$work_dir/fs-repo-11-to-12"
    fi
    [[ -f "$migration_binary" && ! -L "$migration_binary" ]] || {
      echo 'Migration archive does not contain a regular migration binary.' >&2
      exit 1
    }
  elif [[ "$repo_version" =~ ^[0-9]+$ ]] && (( 10#$repo_version >= 12 )); then
    echo "ethoFS repository version $repo_version skips migration."

    # The released geth v3.0.0 rejects repository formats newer than 12.
    if (( 10#$repo_version > 12 )); then
      echo "This geth release cannot open ethoFS repository version $repo_version. Use a compatible geth build." >&2
      exit 1
    fi
  else
    echo "Unsupported ethoFS repository version: $repo_version." >&2
    exit 1
  fi
fi

echo '**************************'
echo 'Configuring QUIC UDP buffer limits'
echo '**************************'
# quic-go recommends at least 7.5 MB for both socket buffer limits.
# Keep higher limits already configured by the administrator.
udp_receive_max=$(sysctl -n net.core.rmem_max)
udp_send_max=$(sysctl -n net.core.wmem_max)
[[ "$udp_receive_max" =~ ^[0-9]+$ && "$udp_send_max" =~ ^[0-9]+$ ]] || {
  echo 'Unable to read UDP socket buffer limits.' >&2
  exit 1
}
if ((udp_receive_max < 7500000)); then udp_receive_max=7500000; fi
if ((udp_send_max < 7500000)); then udp_send_max=7500000; fi
printf 'net.core.rmem_max=%s\nnet.core.wmem_max=%s\n' "$udp_receive_max" "$udp_send_max" > "$work_dir/99-ethoprotocol-udp.conf"
sudo install -d /etc/sysctl.d
sudo install -m 0644 "$work_dir/99-ethoprotocol-udp.conf" /etc/sysctl.d/99-ethoprotocol-udp.conf
if ! sudo sysctl -p /etc/sysctl.d/99-ethoprotocol-udp.conf; then
  echo 'Warning: UDP limits could not be applied. In a restricted container, configure them on the host.' >&2
fi

echo '**************************'
echo 'Stopping old node services'
echo '**************************'
for service in ether1node ethoprotocol ipfs ethoFS; do
  if sudo systemctl cat "$service.service" > /dev/null 2>&1; then
    sudo systemctl stop "$service.service"
    sudo systemctl disable "$service.service"
  fi
done
sudo rm -f /etc/systemd/system/ether1node.service
sudo rm -f /etc/systemd/system/ethoprotocol.service
sudo rm -f /etc/systemd/system/ipfs.service
sudo rm -f /etc/systemd/system/ethoFS.service
sudo rm -f /usr/sbin/ipfs /usr/sbin/ethoFS
# Preserve existing .ipfs data; v3 runs its embedded storage under .etho/ethofs.

# Rename existing .ether1 folder to .etho before starting v3.0.0.
if [[ -d "$_home/.ether1" && ! -d "$_home/.etho" ]]; then
  echo "Renaming $_home/.ether1 to $_home/.etho..."
  sudo mv -- "$_home/.ether1" "$_home/.etho"
fi
sudo install -d -o "$_user" -g "$_group" "$_home/.etho"
# v3 uses public IPFS peers. Retain a copy of the old private swarm key.
if [[ -f "$_home/.etho/ethofs/swarm.key" ]]; then
  sudo mv -- "$_home/.etho/ethofs/swarm.key" "$_home/.etho/ethofs/swarm.key.pre-v3-$(date +%s)"
fi
sudo install -m 0755 "$work_dir/geth" /usr/sbin/geth

if [[ -n "$migration_binary" ]]; then
  sudo install -d /usr/local/bin
  sudo install -m 0755 "$migration_binary" /usr/local/bin/fs-repo-11-to-12
  if ! sudo -u "$_user" -H /usr/local/bin/fs-repo-11-to-12 -path="$_home/.etho/ethofs" -verbose=true; then
    echo 'ethoFS repository migration failed; initialization and configuration were not run.' >&2
    exit 1
  fi
  [[ $(cat "$_home/.etho/ethofs/version") == 12 ]] || {
    echo 'Migration did not produce repository version 12; stopping before configuration.' >&2
    exit 1
  }
fi

verify_ethofs_repo() {
  # Upstream initialization may exit zero and print success even after migration
  # fails. An existing config alone does not prove the repository can be opened.
  [[ -f "$_home/.etho/ethofs/config" && -f "$_home/.etho/ethofs/version" ]] &&
    [[ $(cat "$_home/.etho/ethofs/version") == 12 ]] || {
      echo 'ethoFS initialization/migration failed: repository must be version 12.' >&2
      exit 1
    }
}

echo '**************************'
echo 'Initiating (Geth, IPFS & ethoFS)'
echo '**************************'

if [ "$_nodetype" = "gatewaynode" ] ; then
  sudo setcap CAP_NET_BIND_SERVICE=+eip /usr/sbin/geth
  sudo -u "$_user" -H /usr/sbin/geth --syncmode=snap --cache=512 --datadir="$_home/.etho" --ethofs=gn --ethofsUser="$_usertoken" --ethofsWallet="$_wallet" --ethofsInit
  verify_ethofs_repo
  sleep 7
  sudo -u "$_user" -H /usr/sbin/geth --syncmode=snap --cache=512 --datadir="$_home/.etho" --ethofs=gn --ethofsUser="$_usertoken" --ethofsWallet="$_wallet" --ethofsConfig 2>&1 | tee "$work_dir/ethofs-config.log"
  grep -q 'ethoFS configuration successful' "$work_dir/ethofs-config.log" || { echo 'ethoFS configuration failed.' >&2; exit 1; }
  sleep 7
  cat > "$work_dir/ethoprotocol.service" << EOL
  [Unit]
  Description=ETHO Gateway Node
  After=network.target

  [Service]

  User=$_user
  Group=$_group

  Environment=HOME=$_home
  Type=simple
  Restart=always

  ExecStart=/usr/sbin/geth --syncmode=snap --cache=512 --datadir=$_home/.etho --ethofs=gn --ethofsUser=$_usertoken --ethofsWallet=$_wallet

  [Install]
  WantedBy=default.target
EOL
  sudo install -m 0600 "$work_dir/ethoprotocol.service" /etc/systemd/system/ethoprotocol.service
  sudo systemctl daemon-reload
  sudo systemctl enable ethoprotocol && sudo systemctl start ethoprotocol
  sudo systemctl restart ethoprotocol
  sudo systemctl status ethoprotocol --no-pager --full
fi

if [ "$_nodetype" = "masternode" ] ; then
  sudo -u "$_user" -H /usr/sbin/geth --syncmode=snap --cache=512 --datadir="$_home/.etho" --ethofs=mn --ethofsUser="$_usertoken" --ethofsWallet="$_wallet" --ethofsInit
  verify_ethofs_repo
  sleep 7
  sudo -u "$_user" -H /usr/sbin/geth --syncmode=snap --cache=512 --datadir="$_home/.etho" --ethofs=mn --ethofsUser="$_usertoken" --ethofsWallet="$_wallet" --ethofsConfig 2>&1 | tee "$work_dir/ethofs-config.log"
  grep -q 'ethoFS configuration successful' "$work_dir/ethofs-config.log" || { echo 'ethoFS configuration failed.' >&2; exit 1; }
  sleep 7
  cat > "$work_dir/ethoprotocol.service" << EOL
  [Unit]
  Description=ETHO Masternode
  After=network.target

  [Service]

  User=$_user
  Group=$_group

  Environment=HOME=$_home
  Type=simple
  Restart=always

  ExecStart=/usr/sbin/geth --syncmode=snap --cache=512 --datadir=$_home/.etho --ethofs=mn --ethofsUser=$_usertoken --ethofsWallet=$_wallet

  [Install]
  WantedBy=default.target
EOL
  sudo install -m 0600 "$work_dir/ethoprotocol.service" /etc/systemd/system/ethoprotocol.service
  sudo systemctl daemon-reload
  sudo systemctl enable ethoprotocol && sudo systemctl start ethoprotocol
  sudo systemctl restart ethoprotocol
  sudo systemctl status ethoprotocol --no-pager --full
fi

if [ "$_nodetype" = "servicenode" ] ; then
  sudo -u "$_user" -H /usr/sbin/geth --syncmode=snap --cache=512 --datadir="$_home/.etho" --ethofs=sn --ethofsUser="$_usertoken" --ethofsWallet="$_wallet" --ethofsInit
  verify_ethofs_repo
  sleep 7
  sudo -u "$_user" -H /usr/sbin/geth --syncmode=snap --cache=512 --datadir="$_home/.etho" --ethofs=sn --ethofsUser="$_usertoken" --ethofsWallet="$_wallet" --ethofsConfig 2>&1 | tee "$work_dir/ethofs-config.log"
  grep -q 'ethoFS configuration successful' "$work_dir/ethofs-config.log" || { echo 'ethoFS configuration failed.' >&2; exit 1; }
  sleep 7
  cat > "$work_dir/ethoprotocol.service" << EOL
  [Unit]
  Description=ETHO Service Node
  After=network.target

  [Service]

  User=$_user
  Group=$_group

  Environment=HOME=$_home
  Type=simple
  Restart=always

  ExecStart=/usr/sbin/geth --syncmode=snap --cache=512 --datadir=$_home/.etho --ethofs=sn --ethofsUser=$_usertoken --ethofsWallet=$_wallet

  [Install]
  WantedBy=default.target
EOL
  sudo install -m 0600 "$work_dir/ethoprotocol.service" /etc/systemd/system/ethoprotocol.service
  sudo systemctl daemon-reload
  sudo systemctl enable ethoprotocol && sudo systemctl start ethoprotocol
  sudo systemctl restart ethoprotocol
  sudo systemctl status ethoprotocol --no-pager --full
fi

echo '**************************'
echo 'Setup Complete'
echo '**************************'
