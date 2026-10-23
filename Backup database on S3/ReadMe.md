# Ежедневное создание бэкапов баз данных на Synology и в S3, а также способ восстановления

# Необхождимые ресурсы и расположение конфигов

* Бакет в S3
* Учётная запись для подключения к бакету
* Для корректного создания бэкапа и переноса его в S3 необходим сервер-прокси который будет выполнять скрипты. Необходимые компоненты:
  * postgresql-client - Создание и восстановление бэкапов PostgreSQL
  * mariadb-client или mysql-client - Создание и восстановление бэкапов MySQL
  * aws-cli - Загрузка бэкапов в S3
  * gzip - Сжатие и распаковка дампов MySQL
* Скрипты располагаются на прокси-сервере в каталоге `${SCRIPT_DIR}` (например `/scripts`):
  * `psql_backup.sh`, `psql_restore.sh` — для PostgreSQL
  * `mysql_backup.sh`, `mysql_restore.sh` — для MySQL/MariaDB
* Учётная запись для подключения к прокси-серверу по SSH
* Конфиги для подключения к S3 лежат в `/home/db-backup` (домашний каталог пользователя который используется для запуска скриптов)
* CI/CD — .gitlab-ci.yml

## Единая схема путей

| Назначение | Переменная | Значение по умолчанию |
|---|---|---|
| Корень всех бэкапов | `BACKUP_ROOT` | `/backups` |
| Подкаталог отдела + СУБД | `BACKUP_SUBDIR` | `psql` (для mysql — `mysql`) |
| Полный путь к бэкапам этой СУБД | вычисляется как `${BACKUP_ROOT}/${BACKUP_SUBDIR}` | `/backups/psql` |
| Логи отдела | `LOG_ROOT` | `/backups/logs` |
| Скрипты на сервере | `SCRIPT_DIR` | `/scripts` |

Пути могут меняться в зависимости от отдела — задаются переменными `BACKUP_SUBDIR` и `LOG_ROOT` (в schedule).

## Единые переменные запуска

Все 4 сценария (backup/restore × psql/mysql) используют **одинаковые имена переменных**:

| Переменная | Обязательна | Описание |
|---|---|---|
| `ACTION` | ✅ | `backup` или `restore` |
| `DATABASE_TYPE` | ✅ | `psql` или `mysql` |
| `DB_HOST` | ✅ | Хост БД |
| `DB_PORT` | ✅ | Порт БД (для psql — 5432, для mysql — 3306) |
| `DB_USER` | ✅ | Пользователь БД |
| `DB_NAME` | ✅ | Имя базы |
| `DB_PASSWORD` | ✅ | Пароль БД — **всегда через CI/CD masked, не через schedule** |
| `DB_TEMPLATE` | только restore | Префикс базы для поиска последнего бэкапа (если `BACKUP_DIR` пуст) |
| `BACKUP_DIR` | только restore | Конкретный путь к бэкапу. Пусто → последний по `DB_TEMPLATE` |
| `BACKUP_SUBDIR` | опц. | Переопределить подкаталог отдела/СУБД |
| `BACKUP_JOBS` | опц. | Параллелизм pg_dump/pg_restore (по умолчанию 8) |

`DB_PASSWORD` передаётся в скрипт **через переменную окружения**, а не аргументом — пароль не светится в `ps aux` на сервере.

---

## Создание бэкапов

Для создания бэкапа и его переноса в S3 используется скрипт `<type>_backup.sh` на прокси-сервере.

Скрипт запускает `pg_dump` (или `mysqldump`) с набором ключей, сохраняя бэкап в формате каталога (psql) или `.sql.gz` (mysql). После создания бэкапа происходит перенос данных с локального сервера в S3; последним действием сравнивается количество файлов (psql) или размер (mysql) в локальном каталоге и S3 для проверки целостности переноса.

Бэкапы создаются в каталог `${BACKUP_ROOT}/${BACKUP_SUBDIR}` (по умолчанию `/backups/psql`) в формате `<DB_NAME>_YYYYMMDD-HHMM` (psql — каталог) или `<DB_NAME>_YYYYMMDD-HHMM.sql.gz` (mysql — файл). Формат имени выбран так, чтобы `sort` давал хронологический порядок — это используется при восстановлении последнего бэкапа.

### Как создать задание

Перейти: **Build → Pipeline schedules → New schedule**.

Для каждого задания указать:
- **Interval Pattern** — Custom;
- время запуска в формате cron;
- Variables (см. таблицу ниже).

### Переменные в schedule (calendar)

| Переменная | Пример | Обязательна | Описание |
|---|---|---|---|
| `ACTION` | `backup` | ✅ | Включает job бэкапа |
| `DATABASE_TYPE` | `psql` | ✅ | `psql` или `mysql` |
| `DB_HOST` | `c-<идентификатор_кластера>.rw.mdb.yandexcloud.net` | ✅ | Хост БД |
| `DB_PORT` | `5432` | ✅ | Порт БД |
| `DB_USER` | `postgres` | ✅ | Пользователь БД |
| `DB_NAME` | `postgres` | ✅ | Имя базы |
| `BACKUP_SUBDIR` | `psql` | опц. | Если отличается от дефолта |
| `BACKUP_JOBS` | `8` | опц. | Параллелизм pg_dump |

> ⚠️ **`DB_PASSWORD` в schedule не задаётся.** В cron variables нельзя masked — значение было бы видно в UI. Пароль хранится в CI/CD Variables (masked + protected), GitLab подставит его автоматически.

### Где хранится `DB_PASSWORD`, если у каждой базы свой пароль

Одно имя переменной, разные значения — через **Environment Scope**:

1. В `.gitlab-ci.yml` в job бэкапа и restore добавлено `environment: name: db/$DB_NAME`.
2. В **Settings → CI/CD → Variables** создаются несколько записей с **одинаковым Key `DB_PASSWORD`**, но разным `Environment scope`:

| Key | Value | Environment scope | Masked | Expanded |
|---|---|---|---|---|
| `DB_PASSWORD` | пароль_jira | `db/jira` | ✅ | ✅ |
| `DB_PASSWORD` | пароль_confluence | `db/confluence` | ✅ | ✅ |
| `DB_PASSWORD` | пароль_mattermost | `db/mattermost` | ✅ | ✅ |

При запуске job с `DB_NAME=jira` подставится пароль для jira.

> **Free tier:** Environment Scope недоступен. Тогда используются отдельные переменные `DB_PASSWORD_<DB_NAME>` (masked + Expanded), а в `.gitlab-ci.yml` выполняется `case "$DB_NAME" in ...` для выбора нужной. В schedule `DB_PASSWORD` не задаётся.

### Результат работы job

Вывод в консоль и лог-файл в `${LOG_ROOT}` (`/backups/logs`):

```log
=======================Data Backup=======================
Начало создания бэкапа базы <DB_NAME>
Начало создания бэкапа - 30.05.2025 16:11:03
Хост: <DB_HOST>
Пользователь: <DB_USER>
Каталог бэкапа: <BACKUP_ROOT>/<BACKUP_SUBDIR>/<DB_NAME>_<YYYYMMDD-HHMM>
=======================Start Backup=======================
Запуск pg_dump...
=======================Data S3=======================
Начало загрузки бэкапа в S3
Бакет: <S3_BUCKET>
S3 путь: s3://<S3_BUCKET>/<DB_NAME>_<YYYYMMDD-HHMM>
=======================Start S3=======================
Бэкап успешно загружен в S3
Локальные файлы: 10939, S3 размер: 10939
Целостность бэкапа подтверждена (размеры совпадают)
Процесс резервного копирования успешно завершен
Время завершения - 30.05.2025 20:07:42
=======================End Backup=======================
```

---

## Восстановление бэкапов

Для восстановления используется скрипт `<type>_restore.sh` на прокси-сервере.

Скрипт сначала находит нужный бэкап (указанный `BACKUP_DIR` или последний по `DB_TEMPLATE`), затем запускает `pg_restore` (psql) или `mysql < gunzip` (mysql). При восстановлении psql каскадно удаляются зависимости `mchar` — единственная допустимая ошибка, которая не считается провалом.

### Как запустить восстановление

**Build → Pipelines → New pipeline**. В параметрах pipeline заполнить переменные:

| Переменная | Пример | По умолчанию | Описание |
|---|---|---|---|
| `ACTION` | `restore` | — | Включает job восстановления |
| `DATABASE_TYPE` | `psql` | `psql` | `psql` или `mysql` |
| `DB_NAME` | `postgres` | — | Имя базы **куда** будет восстановлен бэкап |
| `DB_HOST` | `c-<идентификатор_кластера>.rw.mdb.yandexcloud.net` | — | Хост БД |
| `DB_PORT` | `5432` | — | Порт БД |
| `DB_USER` | `postgres` | — | Пользователь БД |
| `DB_PASSWORD` | — | — | **Не задавать вручную** — берётся из CI/CD masked (по `environment: db/$DB_NAME`) |
| `DB_TEMPLATE` | `postgres` | `postgres` | Префикс базы для автопоиска последнего бэкапа |
| `BACKUP_DIR` | `/backups/psql/postgres_20261021-0015` | — | Необязательный. Если пусто — будет восстановлен самый свежий бэкап по `DB_TEMPLATE` |
| `BACKUP_SUBDIR` | `sysops/psql` | `sysops/psql` | Если у отдела другой подкаталог |

В зависимости от заполненных полей:
* `BACKUP_DIR` пуст → восстанавливается самый свежий бэкап по `DB_TEMPLATE`.
* `BACKUP_DIR` заполнен → восстанавливается указанный бэкап.

Job восстановления запускается **вручную** (`when: manual`) и только если заданы `DB_NAME`, `DB_HOST`, `DB_USER`, `DB_PASSWORD` и хотя бы одно из `DB_TEMPLATE` / `BACKUP_DIR`.

### Результат работы job

Вывод в консоль и лог-файл в `${LOG_ROOT}`:

```log
Поиск последнего бэкапа для базы: <DB_TEMPLATE>
Найден последний бэкап: /backups/psql/<DB_TEMPLATE>_<YYYYMMDD-HHMM>
=======================Data Restore=======================
Fri Feb 13 02:00:37 PM MSK 2026 - Начало восстановления <DB_NAME>
Источник бэкапа: /backups/psql/<DB_TEMPLATE>_<YYYYMMDD-HHMM>
Хост: <DB_HOST>
Пользователь: <DB_USER>
Порт: <DB_PORT>
Лог-файл: <LOG_ROOT>/restore_<DB_NAME>_<YYYYMMDD-HHMMSS>.log
=======================Start Restore=======================
Запуск pg_restore...
Процесс восстановления успешно завершен
Время завершения - 13.02.2026 14:02:59
=======================Success Restore=======================
```

---

## Глобальные переменные проекта (CI/CD Variables)

Задаются один раз в **Settings → CI/CD → Variables**:

| Key | Пример | Protected | Masked | Описание |
|---|---|---|---|---|
| `SSH_HOST` | `mdb-backup` | ✅ | — | Хост прокси-сервера |
| `SSH_USER` | `db-backup` | ✅ | — | Пользователь для ssh |
| `SSH_PRIVATE_KEY` | — | ✅ | ✅ | Ключ для ssh |
| `S3_BUCKET` | `backup-database` | ✅ | — | Бакет для выгрузки |
| `BACKUP_ROOT` | `/backups` | — | — | Корень бэкапов |
| `LOG_ROOT` | `/backups/logs` | — | — | Логи отдела |
| `SCRIPT_DIR` | `/backups/scripts` | — | — | Скрипты на сервере |
| `BACKUP_SUBDIR` | `psql` | — | — | Подкаталог отдела/СУБД |
| `DB_PASSWORD` (несколько с разным scope) | — | ✅ | ✅ | Пароли БД по `environment: db/<DB_NAME>` |

> `DB_DEFAULT_PORT` **не используется** — порт задаётся явно через `DB_PORT` в schedule / pipeline (дефолт в `variables.txt` — `5432`; для mysql переопределяется на `3306`).

## Требования к прокси-серверу

* В `${SCRIPT_DIR}` (`/scripts`) лежат `psql_backup.sh`, `psql_restore.sh`, `mysql_backup.sh`, `mysql_restore.sh` с `chmod +x`, владелец — `SSH_USER`.
* `${BACKUP_ROOT}/${BACKUP_SUBDIR}` и `${LOG_ROOT}` существуют и доступны на запись `SSH_USER`.
* `aws` CLI настроен для `SSH_USER` (если `S3_BUCKET` задан) — credentials/профиль.
* В `PATH`: `pg_dump`/`pg_restore` (для psql) или `mysqldump`/`mysql` + `gzip`/`gunzip` (для mysql).