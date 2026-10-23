#!/bin/bash
set -uo pipefail

: "${DB_PASSWORD:?DB_PASSWORD is required}"

if [ $# -lt 6 ]; then
    echo "Usage: DB_PASSWORD=... $0 <DB_HOST> <DB_PORT> <DB_USER> <DB_NAME> <DB_TEMPLATE> <BACKUP_PATH> [BACKUP_DIR]" >&2
    exit 1
fi

DB_HOST="$1"
DB_PORT="$2"
DB_USER="$3"
DB_NAME="$4"
DB_TEMPLATE="$5"
BACKUP_PATH="$6"
BACKUP_DIR="${7:-}"
LOG_ROOT="${LOG_ROOT:-/mnt/backups/sysops/logs}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESTORE_LOG="${LOG_ROOT}/mysql_restore_${DB_NAME}_${TIMESTAMP}.log"

mkdir -p "$LOG_ROOT" || { echo "Невозможно создать каталог логов" >&2; exit 1; }

# ---- Выбор бэкапа ----
if [ -n "$BACKUP_DIR" ]; then

    echo "Указан конкретный бекап:"
    echo "$BACKUP_DIR"

    if [ ! -f "$BACKUP_DIR" ]; then
        echo "Ошибка: Указанный файл не найден:"
        echo "$BACKUP_DIR"
        exit 1
    fi

    LATEST_BACKUP="$BACKUP_DIR"
    echo "Используется указанный бекап: $LATEST_BACKUP"

else

    echo "Поиск последнего бэкапа для базы: $DB_TEMPLATE"

    LATEST_BACKUP=$(
        find "$BACKUP_PATH" -maxdepth 1 -type f -name "${DB_TEMPLATE}_*.sql.gz" 2>/dev/null \
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

echo "Запуск mysql < gunzip..."

set +e
gunzip -c "$LATEST_BACKUP" | MYSQL_PWD="$DB_PASSWORD" mysql \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user="$DB_USER" \
    "$DB_NAME" >> "$RESTORE_LOG" 2>&1
gunzip_status=${PIPESTATUS[0]}
mysql_status=${PIPESTATUS[1]}
set -e

if [ "$gunzip_status" -ne 0 ]; then
    echo "ОШИБКА: gunzip завершился с кодом $gunzip_status"
    RESULT=1
elif [ "$mysql_status" -ne 0 ]; then
    echo "ОШИБКА: mysql завершился с кодом $mysql_status"
    ERR_MSG=$(grep -i "error" "$RESTORE_LOG" | head -n 2 | tr '\n' ' ')
    echo "Детали: $ERR_MSG"
    RESULT=1
else
    echo "Процесс восстановления успешно завершен"
    echo "Время завершения - $(date '+%d.%m.%Y %H:%M:%S')"
    echo "=======================Success Restore======================="
    RESULT=0
fi

} | tee -a "$RESTORE_LOG"

exit $RESULT