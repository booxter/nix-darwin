{ config, pkgs, ... }:

let
  agentPlist = name: program: pkgs.writeText name ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>org.nixos.test-agent</string>
      <key>Program</key>
      <string>${program}</string>
    </dict>
    </plist>
  '';

  firstAgent = agentPlist "test-agent-first.plist" "/bin/first";
  secondAgent = agentPlist "test-agent-second.plist" "/bin/second";

  fakeLaunchctl = pkgs.writeShellScript "fake-launchctl" ''
    set -eu

    state=''${NIX_DARWIN_TEST_STATE:?}
    action=$1
    target=$2

    printf '%s %s %s\n' "$action" "$target" "''${3-}" >> "$state/log"

    case "$action" in
      print)
        uid=''${target#gui/}
        if [[ "$uid" == */* ]]; then
          uid=''${uid%%/*}
          test -e "$state/job-$uid"
        else
          test -e "$state/domain-$uid"
        fi
        ;;
      bootout)
        if [[ "$target" == system ]]; then
          rm -f "$state/legacy-system-job"
        else
          uid=''${target#gui/}
          uid=''${uid%%/*}
          rm -f "$state/job-$uid"
        fi
        ;;
      bootstrap)
        uid=''${target#gui/}
        test -f "$3"
        touch "$state/job-$uid"
        ;;
      *)
        exit 2
        ;;
    esac
  '';

  fakeDscl = pkgs.writeShellScript "fake-dscl" ''
    printf 'active 501\ninactive 502\n'
  '';

  fakeId = pkgs.writeShellScript "fake-id" ''
    printf '503\n'
  '';
in
{
  launchd.agents.test-agent.command = "/bin/test-agent";

  test = ''
    state=$TMPDIR/launchd-state
    destination=$TMPDIR/Library/LaunchAgents/org.nixos.test-agent.plist
    mkdir -p "$state" "$(dirname "$destination")"
    touch "$state/log" "$state/domain-501" "$state/legacy-system-job"

    export NIX_DARWIN_TEST_STATE="$state"
    export NIX_DARWIN_LAUNCHCTL=${fakeLaunchctl}
    export NIX_DARWIN_DSCL=${fakeDscl}
    export NIX_DARWIN_ID=${fakeId}

    manager=${config.system.build.launchdAgentManager}

    echo "checking initial agent bootstrap" >&2
    "$manager" reconcile ${firstAgent} "$destination"
    cmp ${firstAgent} "$destination"
    test ! -e "$state/legacy-system-job"
    test -e "$state/job-501"
    test ! -e "$state/job-502"
    test "$(grep -c '^bootstrap ' "$state/log")" -eq 1

    echo "checking unchanged loaded agent" >&2
    "$manager" reconcile ${firstAgent} "$destination"
    test "$(grep -c '^bootstrap ' "$state/log")" -eq 1

    echo "checking recovery of an unchanged missing agent" >&2
    rm "$state/job-501"
    "$manager" reconcile ${firstAgent} "$destination"
    test -e "$state/job-501"
    test "$(grep -c '^bootstrap ' "$state/log")" -eq 2

    echo "checking changed agent reload" >&2
    "$manager" reconcile ${secondAgent} "$destination"
    cmp ${secondAgent} "$destination"
    test -e "$state/job-501"
    grep '^bootout gui/501/org.nixos.test-agent ' "$state/log"
    test "$(grep -c '^bootstrap ' "$state/log")" -eq 3

    echo "checking activation without a GUI login" >&2
    rm "$state/domain-501" "$state/job-501"
    "$manager" reconcile ${firstAgent} "$destination"
    cmp ${firstAgent} "$destination"
    test ! -e "$state/job-501"
    test "$(grep -c '^bootstrap ' "$state/log")" -eq 3

    echo "checking agent removal from active domains" >&2
    touch "$state/domain-501" "$state/job-501" "$state/legacy-system-job"
    "$manager" remove ${firstAgent} "$destination"
    test ! -e "$destination"
    test ! -e "$state/job-501"
    test ! -e "$state/legacy-system-job"
  '';
}
