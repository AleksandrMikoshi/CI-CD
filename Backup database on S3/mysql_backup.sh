#!/bin/bash
set -uo pipefail

: "${DB_PASSWORD:?DB_PASSWORD is required}"

if [ $# -lt 5 ]; then
    echo "Usage: DB_PASSWORD=... $0 <DB_HOST> <DB_PORT> <DB_USER> <DB_NAME> <BACKUP_PATH> [S3_BUCKET]" >&2
    exit 1
fi

DB_HOST="$1"
DB_PORT="$2"
DB_USER="$3"
DB_NAME="$4"
BACKUP_PATH="$5"
S3_BUCKET="${6:-}"
LOG_ROOT="${LOG_ROOT:-/mnt/backups/sysops/logs}"

TIMESTAMP=$(date +%Y%m%d-%H%M)
BACKUP_NAME="${DB_NAME}_${TIMESTAMP}.sql.gz"
BACKUP_FILE="${BACKUP_PATH}/${BACKUP_NAME}"
BACKUP_LOG="${LOG_ROOT}/mysql_backup_${DB_NAME}_${TIMESTAMP}.log"
S3_LOG="${LOG_ROOT}/s3_upload_${DB_NAME}_${TIMESTAMP}.log"

mkdir -p "$BACKUP_PATH" "$LOG_ROOT" || {
    echo "$(date '+%d.%m.%Y %H:%M:%S') - Не удалось создать каталоги" >&2
    exit 1
}

{
    echo " "
    echo "=======================Data Backup======================="
    echo "Начало создания бэкапа базы $DB_NAME"
    echo "Начало создания бэкапа - $(date '+%d.%m.%Y %H:%M:%S')"
    echo "Хост: $DB_HOST"
    echo "Пользователь: $DB_USER"
    echo "Файл бэкапа: $BACKUP_FILE"
    echo "=======================Start Backup======================="

    echo "Запуск mysqldump..."
    MYSQL_PWD="$DB_PASSWORD" mysqldump \
        --host="$DB_HOST" \
        --port="$DB_PORT" \
        --user="$DB_USER" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --routines \
        --triggers \
        --events \
        --databases "$DB_NAME" \
        | gzip > "$BACKUP_FILE"

    DUMP_EXIT_CODE=${PIPESTATUS[0]}
    if [ "$DUMP_EXIT_CODE" -ne 0 ]; then
        echo "ОШИБКА: mysqldump завершился с кодом $DUMP_EXIT_CODE"
        exit "$DUMP_EXIT_CODE"
    fi

    echo "Бэкап успешно создан: $BACKUP_FILE"
    BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
    echo "Размер бэкапа: $BACKUP_SIZE"

    if [ -n "$S3_BUCKET" ]; then
        echo "=======================Data S3======================="
        echo "Начало загрузки бэкапа в S3"
        echo "Бакет: $S3_BUCKET"
        echo "S3 путь: s3://$S3_BUCKET/$BACKUP_NAME"
        echo "=======================Start S3======================="

        aws s3 cp "$BACKUP_FILE" "s3://$S3_BUCKET/$BACKUP_NAME" >> "$S3_LOG" 2>&1

        S3_EXIT_CODE=$?
        if [ "$S3_EXIT_CODE" -ne 0 ]; then
            echo "ОШИБКА: Загрузка в S3 не удалась (код $S3_EXIT_CODE)"
            exit "$S3_EXIT_CODE"
        fi

        echo "Бэкап успешно загружен в S3"

        LOCAL_SIZE=$(stat -c%s "$BACKUP_FILE")
        S3_SIZE=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$BACKUP_NAME" --query ContentLength --output text)

        echo "Локальный размер: $LOCAL_SIZE, S3 размер: $S3_SIZE"

        if [ "$LOCAL_SIZE" -ne "$S3_SIZE" ]; then
            echo "ОШИБКА: Несоответствие размера файла"
            exit 1
        fi
        echo "Целостность бэкапа подтверждена (размеры совпадают)"
    fi

    echo "Процесс резервного копирования успешно завершен"
    echo "Время завершения - $(date '+%d.%m.%Y %H:%M:%S')"
    echo "=======================End Backup======================="
    exit 0
} | tee -a "$BACKUP_LOG"