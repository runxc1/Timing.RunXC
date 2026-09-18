#!/bin/bash
# Post-Init Script mit Retry-Logik

if [ -n "$DB_PASSWORD" ]; then export PGPASSWORD="$DB_PASSWORD"; else export PGPASSWORD='local-dev-password-123'; fi
if [ -n "$SUPABASE_DB_HOST" ]; then DB_HOST="$SUPABASE_DB_HOST"; else DB_HOST='runxctiming-supabase-db'; fi
DB_USER='supabase_admin'
MAX_RETRIES=30
RETRY_INTERVAL=2

echo "[Post-Init] Warte auf Datenbankverbindung..."

for i in $(seq 1 $MAX_RETRIES); do
    if pg_isready -h $DB_HOST -U $DB_USER -q; then
        echo "[Post-Init] Datenbank ist bereit (Versuch $i)"
        break
    fi
    echo "[Post-Init] Warte auf Datenbank... (Versuch $i/$MAX_RETRIES)"
    sleep $RETRY_INTERVAL
done

# Zusätzliche Wartezeit damit GoTrue die Tabellen erstellen kann
echo "[Post-Init] Warte 10 Sekunden für GoTrue Migrationen..."
sleep 10

echo "[Post-Init] Führe Basis-SQL aus..."
psql -h $DB_HOST -U $DB_USER -d postgres -v new_password="$PGPASSWORD" -f /scripts/post_init.sql

# Migrations ausführen falls vorhanden (muss NACH GoTrue laufen wegen auth.users)
if [ -f /scripts/migrations.sql ]; then
    echo "[Post-Init] Führe Migrations aus..."
    psql -h $DB_HOST -U $DB_USER -d postgres -f /scripts/migrations.sql
    if [ $? -eq 0 ]; then
        echo "[Post-Init] Migrations erfolgreich"
    else
        echo "[Post-Init] WARNUNG: Migrations hatten Fehler"
    fi
fi

# User-SQL ausführen falls vorhanden
if [ -f /scripts/users.sql ]; then
    echo "[Post-Init] Führe User-SQL aus..."
    psql -h $DB_HOST -U $DB_USER -d postgres -f /scripts/users.sql
fi

echo "[Post-Init] Erfolgreich abgeschlossen"