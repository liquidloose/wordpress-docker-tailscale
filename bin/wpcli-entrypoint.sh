#!/bin/sh
# my-wpcli container entrypoint: wait for WordPress + DB, install plugins from a list, then hand off to sh or CLI args.
set -eu

# Optional overrides (set in compose or `docker compose run -e ...`).
PLUGINS_FILE="${WPCLI_PLUGINS_FILE:-/bin/wp-plugins.txt}"
WP_PATH="${WP_CLI_PATH:-/var/www/html}"

cd "$WP_PATH"

# Set WPCLI_SKIP_BOOTSTRAP=1 on `docker compose run -e ...` to skip wait + plugin install (faster one-off wp commands).
if [ "${WPCLI_SKIP_BOOTSTRAP:-0}" = "1" ]; then
	if [ "$#" -eq 0 ]; then
		exec /bin/sh
	fi
	exec "$@"
fi

# Wait until WordPress tables exist. Do not use `wp db check` here: it invokes mariadb-check, which often fails
# against mysql:latest with "TLS/SSL error: self-signed certificate" while mysqli (used by wp core is-installed) works.
wait_for_wp_ready() {
	i=0
	max="${WPCLI_BOOTSTRAP_TIMEOUT:-180}"
	while [ "$i" -lt "$max" ]; do
		if wp core is-installed >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	echo "wpcli-entrypoint: timed out after ${max}s; diagnostics:" >&2
	wp core is-installed >&2 || true
	return 1
}

# One WordPress.org slug per line in PLUGINS_FILE; # and blank lines ignored. Safe to re-run (install or activate only).
install_plugins_from_file() {
	[ -f "$PLUGINS_FILE" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | tr -d '\r')
		case "$line" in ''|\#*) continue ;; esac
		if wp plugin is-installed "$line" >/dev/null 2>&1; then
			wp plugin activate "$line" >/dev/null 2>&1 || true
			continue
		fi
		echo "wpcli-entrypoint: installing plugin '$line'..."
		if ! wp plugin install "$line" --activate; then
			echo "wpcli-entrypoint: failed to install or activate '$line' (wrong slug, network, or permissions?)" >&2
		fi
	done <"$PLUGINS_FILE"
}

if wait_for_wp_ready; then
	install_plugins_from_file
else
	echo "wpcli-entrypoint: skipping plugin install (database or WordPress core not ready)." >&2
fi

# No args (e.g. `compose up` on my-wpcli): drop into an interactive shell. Otherwise run the passed command (e.g. `wp plugin list`).
if [ "$#" -eq 0 ]; then
	exec /bin/sh
fi
exec "$@"
