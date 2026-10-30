#!/usr/bin/env bash
# CI only: grants Accessibility access to the given programs, and to every
# ancestor of this shell, because macOS may hold any of them responsible for a
# request. It writes the TCC databases directly, which works only where System
# Integrity Protection allows it, as on GitHub-hosted macOS runners.
#
# Usage: ci-grant-accessibility.sh <program>...
set -euo pipefail

clients=()
for program in "$@"; do
    if [[ -e "$program" ]]; then
        clients+=("$(cd "$(dirname "$program")" && pwd -P)/$(basename "$program")")
    else
        echo "Skipping $program, which does not exist."
    fi
done
pid=$$
while [[ "$pid" -gt 1 ]]; do
    path="$(ps -o comm= -p "$pid" | sed 's/^ *//')"
    if [[ "$path" == /* ]]; then
        clients+=("$path")
    fi
    pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
done

now="$(date +%s)"
for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    if ! sudo test -f "$db"; then
        echo "No database at $db"
        continue
    fi
    for client in "${clients[@]}"; do
        if [[ "$client" == *"'"* ]]; then
            echo "Skipping $client, which has a quote in its path."
            continue
        fi
        sudo sqlite3 "$db" "INSERT OR REPLACE INTO access
            (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags, last_modified)
            VALUES ('kTCCServiceAccessibility', '$client', 1, 2, 4, 1, 'UNUSED', 0, $now);"
        echo "Granted in $db: $client"
    done
done

# tccd caches the databases.
sudo killall tccd 2> /dev/null || true
killall tccd 2> /dev/null || true
sleep 2
