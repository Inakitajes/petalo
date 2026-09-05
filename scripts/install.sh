#!/bin/sh
# One-command local installer for Petalo.
set -eu

cd "$(dirname "$0")/.."

step() { /usr/bin/printf '\n==> %s\n' "$1"; }

step "Building Petalo (release)"
./scripts/build-app.sh

app_destination="/Applications/Petalo.app"
if [ ! -w "/Applications" ]; then
    app_destination="$HOME/Applications/Petalo.app"
    /bin/mkdir -p "$HOME/Applications"
fi

step "Stopping the running Petalo instance (if any)"
if /usr/bin/pgrep -x Petalo >/dev/null 2>&1; then
    /usr/bin/pkill -x Petalo
    attempts=0
    while /usr/bin/pgrep -x Petalo >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 20 ]; then
            /usr/bin/printf 'error: Petalo did not exit; close it and re-run.\n' >&2
            exit 1
        fi
        /bin/sleep 0.25
    done
fi

step "Installing app to $app_destination"
/bin/rm -rf "$app_destination"
/usr/bin/ditto .build/Petalo.app "$app_destination"

step "Launching Petalo"
/usr/bin/open "$app_destination"

/usr/bin/printf '\nPetalo is installed. It does not install integrations or inspect sessions.\n'
