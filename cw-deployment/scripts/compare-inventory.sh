#!/usr/bin/env bash
# Compare a source inventory with a Supabase destination inventory (db-inventory.sql).
#
#   bash scripts/compare-inventory.sh inventory-source-<ts>.txt inventory-dest-<ts>.txt
#
# Applies the documented, intentional differences and nothing else:
#   - role "authenticator" on the source  ==  "cw_authenticator" on Supabase
#   - "cw_loader" exists only on Supabase (new least-privilege loader role)
#   - extensions: every source extension must exist on Supabase; Supabase's own
#     pre-installed extensions (pgcrypto, pg_stat_statements, ...) are ignored
#   - the database line (collation/locale provider) is reported, not compared:
#     Supabase uses ICU en_US.UTF-8, the source libc en_US.utf8 (SUPABASE_MIGRATION.md §2)
# Everything else (tables, columns, PKs, indexes, functions, views, grants,
# role settings, and row counts when present) must be identical.
set -euo pipefail
src=${1:?source inventory}; dst=${2:?destination inventory}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

norm_src() { sed -E 's/\|authenticator(\||$)/|cw_authenticator\1/g' "$1" | grep -vE '^(db|ext)\|' | sort; }
norm_dst() { grep -vE '^(db|ext)\|' "$1" | grep -vE '^(role|roleconfig|member|grant)\|cw_loader\|' | sort; }

norm_src "$src" > "$tmp/s"; norm_dst "$dst" > "$tmp/d"
ext_ok=1

echo "== database line (informational)"
echo "   source: $(grep -E '^db\|' "$src" || echo -)"
echo "   dest:   $(grep -E '^db\|' "$dst" || echo -)"
echo "== extensions: every source extension must exist on Supabase (Supabase pre-installs others)"
for e in $(grep -E '^ext\|' "$src" | cut -d'|' -f2); do
  if grep -qE "^ext\|$e\|" "$dst"; then echo "   $e: present"; else echo "   $e: MISSING"; ext_ok=0; fi
done
echo "== cw_loader (Supabase only)"
grep -E '^(role|roleconfig|member|grant)\|cw_loader\|' "$dst" | sed 's/^/   /' || echo "   (none)"

echo "== counts"
for k in table coldef index constraint function view role roleconfig member grant rows hash; do
  printf '   %-11s source=%-5s dest=%s\n' "$k" "$(grep -c "^$k|" "$tmp/s" || true)" "$(grep -c "^$k|" "$tmp/d" || true)"
done

if diff -u "$tmp/s" "$tmp/d" > "$tmp/diff"; then
  [ "$ext_ok" = 1 ] || { echo "INVENTORY: EXTENSION MISSING ON SUPABASE"; exit 1; }
  echo "INVENTORY: IDENTICAL (after documented mappings)"
else
  echo "INVENTORY: DIFFERENT"; sed 's/^/   /' "$tmp/diff" | head -60; exit 1
fi
