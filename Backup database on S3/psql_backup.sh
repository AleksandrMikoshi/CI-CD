#!/bin/bash
set -uo pipefail

: "${DB_PASSWORD:?DB_PASSWORD is required}"

if [ $# -lt 5 ]; then
    echo "Usage: DB_PASSWORD=... $0 <DB_HOST> <DB_PORT> <DB_USER> <DB_NAME> <BACKUP_PATH> [S3_BUCKET] [BACKUP_JOBS]" >&2
    exit 1
fi

DB_HOST="$1"
DB_PORT="$2"
DB_USER="$3"
DB_NAME="$4"
BACKUP_PATH="$5"
S3_BUCKET="${6:-}"
BACKUP_JOBS="${7:-8}"
LOG_ROOT="${LOG_ROOT:-/mnt/backups/sysops/logs}"

TIMESTAMP=$(date +%Y%m%d-%H%M)
BACKUP_NAME="${DB_NAME}_${TIMESTAMP}"
BACKUP_DIR="${BACKUP_PATH}/${BACKUP_NAME}"
BACKUP_LOG="${LOG_ROOT}/pg_backup_${DB_NAME}_${TIMESTAMP}.log"
S3_LOG="${LOG_ROOT}/s3_upload_${DB_NAME}_${TIMESTAMP}.log"

mkdir -p "$BACKUP_PATH" "$LOG_ROOT" || {
    echo "$(date '+%d.%m.%Y %H:%M:%S') - Не удалось создать каталоги" >&2
    exit 1
}

{
    echo " "
    echo " "
    echo "=======================Data Backup======================="
    echo "Начало создания бэкапа базы $DB_NAME"
    echo "Начало создания бэкапа - $(date '+%d.%m.%Y %H:%M:%S')"
    echo "Хост: $DB_HOST"
    echo "Пользователь: $DB_USER"
    echo "Каталог бэкапа: $BACKUP_DIR"
    echo "=======================Start Backup======================="

    echo "Запуск pg_dump..."
    PGPASSWORD="$DB_PASSWORD" pg_dump \
        --host "$DB_HOST" \
        --port "$DB_PORT" \
        --username "$DB_USER" \
        --dbname "$DB_NAME" \
        --format d \
        --jobs "$BACKUP_JOBS" \
        --file "$BACKUP_DIR" \
        --no-owner \
        --no-privileges >> "$BACKUP_LOG" 2>&1

    DUMP_EXIT_CODE=$?
    if [ "$DUMP_EXIT_CODE" -ne 0 ]; then
        echo "ОШИБКА: pg_dump завершился с кодом $DUMP_EXIT_CODE"
        grep -A5 "ERROR:" "$BACKUP_LOG" >&2 || true
        exit "$DUMP_EXIT_CODE"
    fi

    echo "Бэкап успешно создан: $BACKUP_DIR"
    BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
    echo "Размер бэкапа: $BACKUP_SIZE"

    if [ -n "$S3_BUCKET" ]; then
        echo "=======================Data S3======================="
        echo "Начало загрузки бэкапа в S3"
        echo "Начало переноса бэкапа в S3 - $(date '+%d.%m.%Y %H:%M:%S')"
        echo "Бакет: $S3_BUCKET"
        echo "Локальный путь: $BACKUP_DIR"
        echo "S3 путь: s3://$S3_BUCKET/$BACKUP_NAME"
        echo "=======================Start S3======================="

        echo "Запуск aws s3 sync..."
        aws s3 sync "$BACKUP_DIR" "s3://$S3_BUCKET/$BACKUP_NAME" >> "$S3_LOG" 2>&1

        S3_EXIT_CODE=$?
        if [ "$S3_EXIT_CODE" -ne 0 ]; then
            echo "ОШИБКА: Загрузка в S3 не удалась (код $S3_EXIT_CODE)"
            grep -A5 -i "error" "$S3_LOG" >&2 || true
            exit "$S3_EXIT_CODE"
        fi

        echo "Бэкап успешно загружен в S3"
        echo "Проверка целостности..."

        LOCAL_FILES=$(find "$BACKUP_DIR" -type f | wc -l)
        S3_FILES=$(aws s3 ls "s3://$S3_BUCKET/$BACKUP_NAME/" --recursive | wc -l)

        echo "Локальные файлы: $LOCAL_FILES, S3 файлы: $S3_FILES"

        if [ "$LOCAL_FILES" -ne "$S3_FILES" ]; then
            echo "ОШИБКА: Несоответствие количества файлов"
            exit 1
        fi

        echo "Целостность бэкапа подтверждена"
    fi

    echo "Процесс резервного копирования успешно завершен"
    echo "Время завершения - $(date '+%d.%m.%Y %H:%M:%S')"
    echo "=======================End Backup======================="
    exit 0
} | tee -a "$BACKUP_LOG"