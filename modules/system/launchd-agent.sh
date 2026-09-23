# shellcheck shell=bash

set -eu

launchctl=${NIX_DARWIN_LAUNCHCTL:-/bin/launchctl}
dscl=${NIX_DARWIN_DSCL:-/usr/bin/dscl}
id=${NIX_DARWIN_ID:-/usr/bin/id}
plist_buddy=${NIX_DARWIN_PLIST_BUDDY:-/usr/libexec/PlistBuddy}

uids=()
domains=()

add_uid() {
  local uid=$1
  local existing

  case "$uid" in
    '' | *[!0-9]*) return ;;
  esac

  for existing in "${uids[@]}"; do
    if [[ "$existing" == "$uid" ]]; then
      return
    fi
  done

  uids+=("$uid")
}

find_active_domains() {
  local directory_users
  local _name
  local uid
  local user

  # Local accounts cover GUI users even when they are not managed by nix-darwin.
  if directory_users=$("$dscl" . -list /Users UniqueID); then
    while read -r _name uid; do
      add_uid "$uid"
    done <<< "$directory_users"
  else
    echo "warning: could not enumerate local users" >&2
  fi

  # Explicitly configured users also cover accounts provided by a directory service.
  for user in "$@"; do
    if uid=$("$id" -u -- "$user" 2>/dev/null); then
      add_uid "$uid"
    fi
  done

  for uid in "${uids[@]}"; do
    if "$launchctl" print "gui/$uid" >/dev/null 2>&1; then
      domains+=("gui/$uid")
    fi
  done
}

bootout() {
  local domain=$1
  local label=$2
  local service="$domain/$label"

  if ! "$launchctl" print "$service" >/dev/null 2>&1; then
    return
  fi

  if ! "$launchctl" bootout "$service"; then
    # A logout can remove the domain while activation is in progress.
    if "$launchctl" print "$domain" >/dev/null 2>&1 \
      && "$launchctl" print "$service" >/dev/null 2>&1; then
      echo "failed to boot out $service" >&2
      return 1
    fi
  fi
}

bootstrap() {
  local domain=$1
  local label=$2
  local plist=$3
  local service="$domain/$label"

  # An unchanged plist may still need loading after a crash or manual bootout.
  if "$launchctl" print "$service" >/dev/null 2>&1; then
    return
  fi

  if ! "$launchctl" bootstrap "$domain" "$plist"; then
    # A concurrent login may load the agent before bootstrap completes.
    if "$launchctl" print "$service" >/dev/null 2>&1; then
      return
    fi

    # A concurrent logout leaves the plist for macOS to load at the next login.
    if ! "$launchctl" print "$domain" >/dev/null 2>&1; then
      return
    fi

    echo "failed to bootstrap $service" >&2
    return 1
  fi
}

bootout_legacy_system_agent() {
  local plist=$1

  # Older nix-darwin versions loaded global agents into the system domain.
  # Targeting the plist path avoids disturbing a daemon with the same label.
  "$launchctl" bootout system "$plist" >/dev/null 2>&1 || true
}

reconcile() {
  local source=$1
  local destination=$2
  shift 2

  local label
  local old_label=
  local domain
  local changed=false

  label=$("$plist_buddy" -c 'Print :Label' "$source")
  if [[ -e "$destination" ]]; then
    old_label=$("$plist_buddy" -c 'Print :Label' "$destination" 2>/dev/null || true)
  fi

  bootout_legacy_system_agent "$destination"
  find_active_domains "$@"

  if ! /usr/bin/cmp -s "$source" "$destination"; then
    changed=true
  fi

  if [[ "$changed" == true ]]; then
    # Changed agents are removed from each live GUI domain before replacement.
    if [[ -n "$old_label" ]]; then
      for domain in "${domains[@]}"; do
        bootout "$domain" "$old_label"
      done
    fi

    if [[ -e "$destination" ]]; then
      echo "reloading service $label" >&2
    else
      echo "creating service $label" >&2
    fi

    if [[ -L "$destination" ]]; then
      /bin/rm "$destination"
    fi
    /bin/cp -f "$source" "$destination"
  fi

  if (( ${#domains[@]} == 0 )); then
    # With no GUI login, installing the plist is enough; macOS loads it later.
    return
  fi

  for domain in "${domains[@]}"; do
    bootstrap "$domain" "$label" "$destination"
  done
}

remove() {
  local plist=$1
  local destination=$2
  shift 2

  local label
  local domain

  label=$("$plist_buddy" -c 'Print :Label' "$plist")
  bootout_legacy_system_agent "$destination"
  find_active_domains "$@"

  for domain in "${domains[@]}"; do
    bootout "$domain" "$label"
  done

  if [[ -e "$destination" || -L "$destination" ]]; then
    /bin/rm -f "$destination"
  fi
}

if (( $# < 3 )) || [[ "$1" != reconcile && "$1" != remove ]]; then
  echo "usage: $0 {reconcile SOURCE|remove PLIST} DESTINATION [USER ...]" >&2
  exit 2
fi

command=$1
shift
"$command" "$@"
