#!/bin/bash
set -uo pipefail

: "${DB_PASSWORD:?DB_PASSWORD is required}"

if [ $# -lt 6 ]; then
    echo "Usage: DB_PASSWORD=... $0 <DB_HOST> <DB_PORT> <DB_USER> <DB_NAME> <DB_TEMPLATE> <BACKUP_PATH> [BACKUP_DIR] [BACKUP_JOBS]" >&2
    exit 1
fi

DB_HOST="$1"
DB_PORT="$2"
DB_USER="$3"
DB_NAME="$4"
DB_TEMPLATE="$5"
BACKUP_PATH="$6"
BACKUP_DIR="${7:-}"
BACKUP_JOBS="${8:-8}"
LOG_ROOT="${LOG_ROOT:-/mnt/backups/sysops/logs}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESTORE_LOG="${LOG_ROOT}/restore_${DB_NAME}_${TIMESTAMP}.log"

mkdir -p "$LOG_ROOT" || { echo "Невозможно создать каталог логов" >&2; exit 1; }

# ---- Выбор бэкапа ----
if [ -n "$BACKUP_DIR" ]; then

    echo "Указан конкретный бекап:"
    echo "$BACKUP_DIR"

    if [ ! -d "$BACKUP_DIR" ]; then
        echo "Ошибка: Указанный каталог не найден:"
        echo "$BACKUP_DIR"
        exit 1
    fi

    LATEST_BACKUP="$BACKUP_DIR"
    echo "Используется указанный бекап: $LATEST_BACKUP"

else

    echo "Поиск последнего бэкапа для базы: $DB_TEMPLATE"

    LATEST_BACKUP=$(
        find "$BACKUP_PATH" -maxdepth 1 -type d -name "${DB_TEMPLATE}_*" 2>/dev/null \
        | sort | tail -n 1
    )

    if [ -z "$LATEST_BACKUP" ]; then
        echo "ОШИБКА: Бэкап для базы $DB_TEMPLATE не найден в $BACKUP_PATH"
        exit 1
    fi

    echo "Найден последний бэкап: $LATEST_BACKUP"

fi

{
echo "=======================Data Restore======================="
echo "$(date) - Начало восстановления $DB_NAME"
echo "Источник бэкапа: $LATEST_BACKUP"
echo "Хост: $DB_HOST"
echo "Пользователь: $DB_USER"
echo "Порт: $DB_PORT"
echo "Лог-файл: $RESTORE_LOG"
echo "=======================Start Restore======================="

echo "Запуск pg_restore..."

set +e
PGPASSWORD="$DB_PASSWORD" pg_restore \
    --dbname "$DB_NAME" \
    --host "$DB_HOST" \
    --username "$DB_USER" \
    --port "$DB_PORT" \
    --format=d \
    --no-owner \
    --no-privileges \
    --clean \
    --if-exists \
    --jobs "$BACKUP_JOBS" \
    "$LATEST_BACKUP" >> "$RESTORE_LOG" 2>&1
restore_status=$?
set -e

REAL_ERRORS=$(grep "ERROR:" "$RESTORE_LOG" | grep -v "DROP EXTENSION IF EXISTS mchar" | wc -l)

if [ "$restore_status" -eq 0 ] || { grep -q "DROP EXTENSION IF EXISTS mchar" "$RESTORE_LOG" && [ "$REAL_ERRORS" -eq 0 ]; }; then
    echo "Процесс восстановления успешно завершен"
    echo "Время завершения - $(date '+%d.%m.%Y %H:%M:%S')"

    if grep -q "WARNING:" "$RESTORE_LOG"; then
        WARN_MSG=$(grep -m1 "WARNING:" "$RESTORE_LOG")
        echo "ПРЕДУПРЕЖДЕНИЕ: $WARN_MSG"
    fi

    echo "=======================Success Restore======================="
    RESULT=0
else
    ERR_MSG=$(grep -A1 "ERROR:" "$RESTORE_LOG" | grep -v "DROP EXTENSION IF EXISTS mchar" | head -n 2 | tr '\n' ' ')
    echo "ОШИБКА: Восстановление завершено с кодом $restore_status"
    echo "Детали: $ERR_MSG"
    echo "=======================Error Restore======================="
    RESULT=1
fi

} | tee -a "$RESTORE_LOG"

exit $RESULT