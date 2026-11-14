#!/bin/bash
# يعيد بناء قاعدة اختبار محلية ويطبق المحاكاة + كل الـmigrations
P="psql -h /tmp/pg -p 5544 -U postgres -v ON_ERROR_STOP=1 -q"
cd "$(dirname "$0")/.."
psql -h /tmp/pg -p 5544 -U postgres -q -c "drop database if exists gk" -c "create database gk" 2>/dev/null
$P -d gk -f test/supabase_shim.sql || exit 1
for f in supabase/migrations/*.sql; do echo "== $f"; $P -d gk -f "$f" || exit 1; done
