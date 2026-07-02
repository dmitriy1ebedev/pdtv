#!/bin/bash
#===============================================================================
# pdtv — Обработчик входящих документов: распаковка, ПДТВ
# Версия: 1.1
# Совместимость: Astra Linux 1.7+ , Alt Linux 10.4+
#===============================================================================
#
# Copyright 2026 Dmitriy Lebedev
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#===============================================================================
#
# НАЗНАЧЕНИЕ
# ----------
#   Скрипт обрабатывает вложения, скачанные с веб-почты (Roundcube), и
#   формирует ПДТВ — текстовый «лист подтверждения получения». ПДТВ содержит
#   перечень принятых файлов с размерами и отправляется обратно отправителю
#   как подтверждение, что электронное письмо дошло до адресата.
#
#   Почему ZIP обрабатывается первым: Roundcube отдаёт несколько вложений
#   одной кнопкой «скачать всё» в виде ZIP, а одиночное вложение — как есть.
#   Поэтому ZIP распаковывается, и в ПДТВ попадают сами файлы, а не архив.
#
# ЧТО ДЕЛАЕТ (модули, каждый можно включить/выключить — см. блок «МОДУЛИ»)
# -----------------------------------------------------------------------
#   M2  blanks    — упаковывает бланки (doc/docx/txt/odt) в ZIP.
#   M3  unzip     — распаковывает ZIP из «Входящих» в «Загрузку».
#   M4  pdtv      — формирует ПДТВ — перечень полученных файлов.
#   M5  extract   — распаковывает архивы (zip/7z/rar/tar/gz/bz2/xz…),
#                   включая «архив в архиве» (рекурсивно).
#                   ПОРЯДОК ВЫПОЛНЕНИЯ: M2→M3→M4→M5.
#   M6  cleanup   — очищает «Загрузку», возвращает остаток, выставляет права.
#   M7  open      — открывает результат (Отработанные/<дата> и Входящие).
#
# КАК ВЫКЛЮЧИТЬ МОДУЛЬ
# --------------------
#   • Постоянно: в блоке «МОДУЛИ» ниже поставьте ENABLE_*=false.
#   • Разово из CLI: --no-blanks --no-unzip --no-pdtv --no-extract
#                    --no-cleanup --no-chmod --no-open
#   • Запустить только нужное: --only pdtv,extract
#   • Пропустить часть:        --skip blanks,chmod
#   • Список модулей и их статус: --list-modules
#
# ТРЕБОВАНИЯ
# ----------
#   bash >= 4    — интерпретатор (НЕ dash)
#   find sed sort paste grep tr wc coreutils — стандартный набор
#   zip unzip    — упаковка/распаковка ZIP (этап пропускается при отсутствии)
#   7z           — архивы 7z/rar/zip, запасной экстрактор
#   tar gzip bzip2 xz — tar/gz/bz2/xz (этапы пропускаются при отсутствии)
#   getent       — чтение ФИО из GECOS (опционально)
#   zenity       — графический запрос дежурного при запуске по ярлыку (опц.)
#   xdg-open     — открытие файлов (опционально, только в GUI-сессии)
#   numfmt       — человекочитаемый размер (опционально)
#
# ИСПОЛЬЗОВАНИЕ
# ------------
#   bash pdtv.sh                       — полный прогон
#   bash pdtv.sh --dry-run             — показать действия БЕЗ изменений на диске
#   bash pdtv.sh --verbose             — подробный лог
#   bash pdtv.sh -d 31.12.2026         — задать рабочую дату
#   bash pdtv.sh --root /путь          — другой корневой каталог
#   bash pdtv.sh --officer "Иванов И.И." — задать дежурного вручную
#   bash pdtv.sh --only pdtv           — выполнить только формирование ПДТВ
#   bash pdtv.sh --no-open             — не открывать файлы в конце
#   bash pdtv.sh --no-chmod            — не менять права
#   bash pdtv.sh --help                — полная справка
#
# ЗАПУСК ПО ЯРЛЫКУ (.desktop)
# ---------------------------
#   Exec=bash /полный/путь/pdtv.sh
#   Terminal=true      ← чтобы видеть лог и (при необходимости) ввести дежурного.
#   По умолчанию в конце ждём Enter (PAUSE_ON_EXIT=auto), чтобы окно не закрылось.
#
#===============================================================================

# === Блок: строгий режим bash ===
# -E (errtrace) — чтобы ловушка ERR срабатывала и внутри функций.
set -Eeuo pipefail

# === Блок: версия ===
VERSION="1.1"

#===============================================================================
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  БЫСТРАЯ НАСТРОЙКА — чаще всего меняют ИМЕННО ЭТО (откуда/куда)            ║
# ╚══════════════════════════════════════════════════════════════════════════╝
# Эти же значения можно задать в окне настроек (по ярлыку) или ключами CLI —
# тогда введённое попадёт в ярлык. Здесь — значения «по умолчанию».
#===============================================================================

# ── ГЛАВНОЕ: РАБОЧАЯ ПАПКА (корень) ──────────────────────────────────────────
# Внутри неё скрипт работает с подпапками: «Входящие», «ПДТВ», «! Отработанные».
# Сменить можно здесь, ключом --root или в окне настроек (первое поле).
ROOT="/DOCS/Общая"                   # корень (переопределяется: --root / GUI)

DATE="$(date +%d.%m.%Y)"             # рабочая дата (переопределяется: --date / GUI)

#--- ТЕКСТЫ ПДТВ (подставьте свои формулировки) -------------------------------
OTKUDA="Из Москвы"                   # строка «откуда» (первая строка ПДТВ)

# Подпись ПДТВ — ровно одна последняя строка: ФИО дежурного. Берётся из GECOS
# (поле в /etc/passwd) или из того, что оператор ввёл в окне настроек. Плейсхолдер
# {фио} подставляется автоматически.
SIGNATURE="{фио}"

#--- ДЕЖУРНЫЙ (подпись ПДТВ) --------------------------------------------------
# Цепочка приоритетов: --officer  >  DUTY_OFFICER  >  GECOS  >  запрос у пользователя
DUTY_OFFICER=""                      # ФИО дежурного вручную (пусто → GECOS/запрос)

#--- ПОВЕДЕНИЕ ----------------------------------------------------------------
CHMOD_MODE="777"                     # права на общий каталог (775 — безопаснее)
OPEN_LIMIT=10                        # макс. число одновременно открываемых файлов
SHOW_HUMAN_SIZE=false                # true → добавлять (КиБ/МиБ) в перечень ПДТВ; по умолчанию только байты
MAX_NEST_DEPTH=5                     # глубина распаковки «архив в архиве» (защита от циклов/бомб)
KEEP_ARCHIVES=false                  # true → исходные архивы не удалять, а переносить в Отработанные
PAUSE_ON_EXIT=false                  # auto|true|false — ждать Enter в конце (по умолчанию НЕ ждём; включается ключом --pause)
MONTH_GROUPING=true                  # true → внутри каталогов уровень месяца «01 Январь/<дата>»
USE_COLOR=auto                       # auto|true|false — цветной вывод (auto: TTY и без NO_COLOR)
QUIET=false                          # true → только предупреждения, ошибки и итоговая сводка

#--- НАБОРЫ РАСШИРЕНИЙ (используются во всех модулях из одного места) ----------
DOC_EXTS=( doc docx txt odt )                       # «бланки»: пакуются и переносятся
OPEN_EXTS=( doc docx txt odt pdf ods xlsx )         # что открывать в конце
# Архивы для распаковки. Поддержаны и составные расширения (tar.gz и т.п.).
ARCHIVE_EXTS=( 7z zip rar tar tar.gz tgz tar.bz2 tbz tbz2 tar.xz txz gz bz2 xz )
LIST_EXCLUDE_EXTS=( pdf ods zip rar 7z tar gz bz2 xz gpg pgp ) # исключить из имени файла ПДТВ
# ZIP-контейнеры, которые НЕ являются архивами для распаковки: офисные документы
# (OOXML/ODF) внутри — обычный ZIP (сигнатура PK), поэтому распознавание архива
# ПО СОДЕРЖИМОМУ ложно срабатывало бы и потрошило документ в кучу xml. Их расширения
# исключаем из _is_archive_file ДО проверки сигнатуры.
ZIPLIKE_DOC_EXTS=( docx docm dotx dotm xlsx xlsm xltx pptx pptm potx \
                   odt ods odp odg odf ott ots otp epub )

#===============================================================================
# МОДУЛИ — главный выключатель каждого этапа (true = включён)
#===============================================================================
ENABLE_ARCHIVE_BLANKS=true   # M2   упаковка бланков doc/docx/txt/odt → zip
ENABLE_UNPACK_ZIP=true       # M3   распаковка zip из «Входящих» → «Загрузка»
ENABLE_PDTV=true             # M4   формирование листа ПДТВ
ENABLE_EXTRACT=true          # M5   распаковка архивов (+вложенные)
ENABLE_CLEANUP=true          # M6   финальная очистка / возврат остатка
ENABLE_CHMOD=true            # M6   выставление прав (часть очистки)
ENABLE_OPEN=true             # M7   открытие результатов

#--- ПЕРЕКЛЮЧАТЕЛИ РЕЖИМА (меняются ключами CLI) ------------------------------
VERBOSE=false                        # подробный лог             (--verbose)
DRY_RUN=false                        # холостой прогон           (--dry-run)

#===============================================================================
# СЛУЖЕБНЫЕ ГЛОБАЛЬНЫЕ (не менять)
#===============================================================================
FIO=""                                      # итоговое ФИО для подписи
GEC_FIO=""; GECOS_FULL=""                    # значения из GECOS
OFFICER_CLI=""                              # ФИО из CLI/конфига (--officer)
_ROOT_FROM_CLI=false                        # был ли ROOT задан ключом --root
# Файл сохранённых настроек окна (рабочая папка, ФИО дежурного).
# Заполняется при запуске через окно и подставляется при следующем старте.
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pdtv/config"
declare -a _PRED=() _OPEN_PRED=() _DOC_PRED=() _ARC_PRED=() _EXCL_PRED=()
PERIOD=""; OTRABOTKA_P=""; PDTV_P=""        # период-каталог (месяц/дата) — заполняет init_paths

# Палитра (заполняется setup_colors; по умолчанию пусто = без цвета)
C_RESET=''; C_DIM=''; C_BLD=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYA=''; C_MAG=''

# Счётчики для итоговой сводки
declare -A STATS=(
    [zip]=0 [arc_ok]=0 [arc_fail]=0 [blanks]=0 [warn]=0
)

#===============================================================================
# UI: ЦВЕТА И ЛОГИРОВАНИЕ
#===============================================================================
# Поддержка стандарта NO_COLOR (https://no-color.org) и авто-определения TTY.
setup_colors() {
    local on=false
    case "$USE_COLOR" in
        true)  on=true ;;
        false) on=false ;;
        auto)  [[ -t 1 && -z "${NO_COLOR:-}" ]] && on=true ;;
    esac
    if [[ "$on" == true ]]; then
        C_RESET=$'\e[0m'; C_DIM=$'\e[2m';  C_BLD=$'\e[1m'
        C_RED=$'\e[31m';  C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
        C_BLU=$'\e[34m';  C_CYA=$'\e[36m'; C_MAG=$'\e[35m'
    fi
}

_ts() { printf '%s%s%s' "$C_DIM" "$(date +'%H:%M:%S')" "$C_RESET"; }

# Обычная строка лога (приглушается в --quiet)
log()  { [[ "$QUIET" == true ]] && return 0; printf '%s %s\n' "$(_ts)" "$*"; }
# Заголовок этапа: step M1 "Описание"
step() { [[ "$QUIET" == true ]] && return 0
         printf '%s %s▸ [%s]%s %s%s%s\n' "$(_ts)" "$C_BLU$C_BLD" "$1" "$C_RESET" "$C_BLD" "$2" "$C_RESET"; }
ok()   { [[ "$QUIET" == true ]] && return 0; printf '%s   %s✓%s %s\n' "$(_ts)" "$C_GRN" "$C_RESET" "$*"; }
note() { [[ "$QUIET" == true ]] && return 0; printf '%s   %s•%s %s\n' "$(_ts)" "$C_CYA" "$C_RESET" "$*"; }
vlog() { [[ "$VERBOSE" == true ]] && printf '%s %s[V]%s %s\n' "$(_ts)" "$C_MAG" "$C_RESET" "$*" >&2 || true; }
warn() { STATS[warn]=$(( STATS[warn] + 1 ))
         printf '%s %s⚠ %s%s\n' "$(_ts)" "$C_YEL" "$*" "$C_RESET" >&2; }
die()  { printf '%s %s✗ ОШИБКА: %s%s\n' "$(_ts)" "$C_RED$C_BLD" "$*" "$C_RESET" >&2; exit 1; }

#===============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
#===============================================================================

# Удалить пробелы по краям (чистый bash, без подпроцессов)
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Русское название месяца по номеру 01..12 → «Январь» … «Декабрь»
month_name_ru() {
    local m=$(( 10#$1 ))   # 10# — трактовать «08»,«09» как десятичные, а не восьмеричные
    local -a names=( '' Январь Февраль Март Апрель Май Июнь
                        Июль Август Сентябрь Октябрь Ноябрь Декабрь )
    (( m >= 1 && m <= 12 )) && printf '%s' "${names[$m]}" || printf 'Месяц'
}

# Русское согласование: ru_plural <n> <1> <2-4> <5-0>  →  ru_plural 3 файл файла файлов
ru_plural() {
    local n="$1" one="$2" few="$3" many="$4"
    local n100=$(( n % 100 )) n10=$(( n % 10 ))
    if   (( n100 >= 11 && n100 <= 14 )); then printf '%s' "$many"
    elif (( n10 == 1 ));                 then printf '%s' "$one"
    elif (( n10 >= 2 && n10 <= 4 ));      then printf '%s' "$few"
    else                                      printf '%s' "$many"; fi
}

# Человекочитаемый размер
human_size() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%sB' "$1"
    else
        printf '%sB' "$1"
    fi
}

# Определить тип файла по «магическим» байтам (без оглядки на расширение).
# Печатает короткий тег: zip|7z|rar|gzip|bzip2|xz|pdf или пусто (неизвестно).
# Нужно для файлов БЕЗ говорящего расширения — например, вложенный архив с «чужим»
# расширением, который по имени не распознать.
_sniff_kind() {
    local f="$1" sig
    sig="$(head -c 8 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    case "$sig" in
        504b0304*|504b0506*|504b0708*) printf 'zip'   ;;   # PK..  (zip/odt/docx)
        377abcaf271c*)                 printf '7z'    ;;   # 7z\xBC\xAF'..
        526172211a07*)                 printf 'rar'   ;;   # Rar!\x1A\x07
        1f8b*)                         printf 'gzip'  ;;
        425a68*)                       printf 'bzip2' ;;   # BZh
        fd377a585a00*)                 printf 'xz'    ;;   # \xFD7zXZ\0
        25504446*)                     printf 'pdf'   ;;   # %PDF
        *)                             printf ''      ;;
    esac
}

# Это файл-архив, который можно распаковать? Сначала по расширению (быстро), затем
# ПО СОДЕРЖИМОМУ — чтобы поймать архив с «чужим»/неговорящим расширением. PDF и
# прочие НЕ-архивы сюда не попадают (_sniff_kind для них вернёт не-архивный тег).
_is_archive_file() {
    local f="$1" low ext _ze
    low="${f,,}"
    case "$low" in
        *.7z|*.zip|*.rar|*.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tbz2|*.tar.xz|*.txz|*.gz|*.bz2|*.xz)
            return 0 ;;
    esac
    # Офисные документы (docx/odt/xlsx…) — это ZIP-контейнеры (сигнатура PK), но
    # распаковывать их нельзя: иначе в каталог высыпется их внутренний xml-«скелет».
    # Исключаем по расширению ДО проверки сигнатуры.
    ext="${low##*.}"
    for _ze in "${ZIPLIKE_DOC_EXTS[@]}"; do
        [[ "$ext" == "$_ze" ]] && return 1
    done
    case "$(_sniff_kind "$f")" in
        zip|7z|rar|gzip|bzip2|xz) return 0 ;;
    esac
    return 1
}

# Локаль UTF-8 — критично для регистронезависимого поиска кириллицы (-iname "О*")
ensure_utf8_locale() {
    case "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" in
        *UTF-8*|*utf8*|*Utf8*) return 0 ;;
    esac
    local loc avail
    avail="$(locale -a 2>/dev/null || true)"
    for loc in ru_RU.UTF-8 ru_RU.utf8 C.UTF-8 C.utf8 en_US.UTF-8; do
        if printf '%s\n' "$avail" | grep -qx "$loc"; then
            export LC_ALL="$loc"; vlog "Локаль: $LC_ALL"; return 0
        fi
    done
    warn "UTF-8 локаль не найдена — шаблоны кириллицы («О*») могут срабатывать неточно"
    return 0
}

# Построить предикаты find по расширениям → в массив _PRED.
# Пример: build_name_pred doc txt  →  ( -iname '*.doc' -o -iname '*.txt' )
# Поддерживает составные расширения: build_name_pred tar.gz → ( -iname '*.tar.gz' )
build_name_pred() {
    _PRED=( '(' )
    local first=true e
    for e in "$@"; do
        if [[ "$first" == true ]]; then _PRED+=( -iname "*.$e" ); first=false
        else                            _PRED+=( -o -iname "*.$e" ); fi
    done
    _PRED+=( ')' )
}

# Безопасное удаление списка файлов (учитывает dry-run)
_rm_list() {
    (( $# )) || return 0
    if [[ "$DRY_RUN" == true ]]; then
        local f; for f in "$@"; do [[ -n "$f" ]] && log "[would] rm: $f"; done
        return 0
    fi
    rm -f -- "$@" 2>/dev/null || true
}

# Безопасное перемещение файлов в каталог (с резервом -b, учитывает dry-run)
_mv_into() {
    local dir="$1"; shift
    (( $# )) || return 0
    if [[ "$DRY_RUN" == true ]]; then
        local f; for f in "$@"; do [[ -n "$f" ]] && log "[would] mv → ${dir##*/}/: ${f##*/}"; done
        return 0
    fi
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || true
    # --backup=numbered: при совпадении имён НЕ перетираем, а сохраняем все версии
    # (напр. несколько «ПДТВ_1.txt» за день → ПДТВ_1.txt, ПДТВ_1.txt.~1~, …)
    mv --backup=numbered -t "$dir" -- "$@" 2>/dev/null || true
}

# Выполнить команду с учётом dry-run.
# Терпимо к ошибкам: не роняем весь скрипт (set -e/ERR) из-за частного сбоя
# (напр. chmod на чужих файлах). Неуспех логируется предупреждением.
run() {
    if [[ "$DRY_RUN" == true ]]; then log "[would] $*"; return 0; fi
    "$@" || { local rc=$?; warn "команда вернула код $rc: $*"; return 0; }
}

# Открыть файл в фоне, не роняя прогон. Подсубшелл с «|| true» гасит ошибку
# xdg-open (нет DISPLAY/обработчика), иначе фоновая задача дёргала бы ERR-trap.
open_bg() {
    command -v xdg-open >/dev/null 2>&1 || return 0
    ( xdg-open "$1" >/dev/null 2>&1 || true ) &
    return 0
}

#===============================================================================
# ИНИЦИАЛИЗАЦИЯ ПУТЕЙ И ПРЕДИКАТОВ (после разбора аргументов)
#===============================================================================
init_paths() {
    PDTV="$ROOT/ПДТВ"
    VHOD="$ROOT/Входящие"
    OTRABOTKA="$VHOD/! Отработанные"
    CHMOD_TARGET="$ROOT"

    # Период-каталог: с уровнем месяца «01 Январь/12.01.2026» или просто «12.01.2026».
    # Месяц берём из DATE (формат ДД.ММ.ГГГГ); при нераспознанном формате — без месяца.
    PERIOD="$DATE"
    if [[ "$MONTH_GROUPING" == true ]]; then
        local mm="${DATE#*.}"; mm="${mm%%.*}"   # средняя группа ДД.[ММ].ГГГГ
        if [[ "$mm" =~ ^[0-9]{1,2}$ ]]; then
            PERIOD="$(printf '%02d' "$((10#$mm))") $(month_name_ru "$mm")/$DATE"
        else
            warn "Не удалось определить месяц из даты «$DATE» — уровень месяца пропущен"
        fi
    fi
    OTRABOTKA_P="$OTRABOTKA/$PERIOD"            # период-каталог в «Отработанных»
    PDTV_P="$PDTV/$PERIOD"                      # период-каталог в «ПДТВ»
    ZAGRUZKA="$OTRABOTKA_P/Загрузка"

    build_name_pred "${OPEN_EXTS[@]}";         _OPEN_PRED=( "${_PRED[@]}" )
    build_name_pred "${DOC_EXTS[@]}";          _DOC_PRED=( "${_PRED[@]}" )
    build_name_pred "${ARCHIVE_EXTS[@]}";      _ARC_PRED=( "${_PRED[@]}" )
    build_name_pred "${LIST_EXCLUDE_EXTS[@]}"; _EXCL_PRED=( "${_PRED[@]}" )
}

#===============================================================================
# ОПРЕДЕЛЕНИЕ ДЕЖУРНОГО: --officer > DUTY_OFFICER > GECOS > запрос
#===============================================================================

# Чтение ФИО из GECOS (/etc/passwd, поле 5) → GEC_FIO
read_gecos() {
    GEC_FIO=""; GECOS_FULL=""
    local user info
    user="${USER:-$(id -un 2>/dev/null || whoami)}"
    command -v getent >/dev/null 2>&1 || { vlog "getent недоступен — GECOS пропущен"; return 0; }
    info="$(getent passwd "$user" 2>/dev/null || true)"
    [[ -z "$info" ]] && return 0
    GECOS_FULL="$(printf '%s' "$info" | cut -d: -f5 || true)"
    [[ -z "$GECOS_FULL" ]] && return 0

    # Разбор по запятым БЕЗ порчи $@ и БЕЗ glob-раскрытия
    local -a parts=()
    local oldifs="$IFS"
    IFS=','
    read -r -a parts <<< "$GECOS_FULL"
    IFS="$oldifs"

    [[ ${#parts[@]} -ge 1 ]] && GEC_FIO="$(trim "${parts[0]}")"
    return 0
}

# Загрузить сохранённые настройки окна (рабочая папка, ФИО) и применить
# их как значения по умолчанию. Приоритет: ключи CLI > сохранённый конфиг > дефолт/GECOS.
# Файл читаем построчно (KEY=значение), БЕЗ source — чтобы ничего не исполнялось.
load_config() {
    [[ -r "$CONFIG_FILE" ]] || return 0
    local k v
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        k="$(trim "${k%$'\r'}")"; [[ -z "$k" || "$k" == \#* ]] && continue
        v="$(trim "$v")"
        case "$k" in
            ROOT)     [[ "$_ROOT_FROM_CLI" == false && -n "$v" ]] && ROOT="${v%/}" ;;
            OFFICER)  [[ -z "$OFFICER_CLI" && -n "$v" ]] && OFFICER_CLI="$v" ;;
        esac
    done < "$CONFIG_FILE"
    vlog "Загружены настройки: $CONFIG_FILE (ROOT='$ROOT', OFFICER='$OFFICER_CLI')"
}

# Сохранить текущие настройки окна, чтобы подставить при следующем запуске.
save_config() {
    local dir; dir="$(dirname "$CONFIG_FILE")"
    mkdir -p "$dir" 2>/dev/null || { warn "  не удалось создать каталог настроек: $dir"; return 0; }
    {
        printf '# pdtv — сохранённые настройки окна (правится автоматически)\n'
        printf 'ROOT=%s\n'     "$ROOT"
        printf 'OFFICER=%s\n'  "$OFFICER_CLI"
    } > "$CONFIG_FILE" 2>/dev/null || { warn "  не удалось сохранить настройки: $CONFIG_FILE"; return 0; }
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    vlog "Настройки сохранены: $CONFIG_FILE"
}

# Интерактивный запрос ФИО (zenity в GUI, иначе terminal). Заполняет FIO.
prompt_officer() {
    local val=""
    if [[ -n "${DISPLAY:-}" ]] && command -v zenity >/dev/null 2>&1; then
        znt --entry --title "ПДТВ — дежурный" \
            --text "Введите ФИО дежурного:" \
            --entry-text "${GEC_FIO}" || true
        val="$ZNT_OUT"
    elif [[ -t 0 && -t 1 ]]; then
        printf 'Введите ФИО дежурного (Enter — пропустить): ' >&2
        IFS= read -r val || true
    else
        vlog "Нет TTY/zenity — интерактивный запрос дежурного пропущен"
        return 0
    fi
    val="$(trim "$val")"
    [[ -n "$val" ]] && FIO="$val"
    return 0
}

# Собрать подпись по цепочке приоритетов
resolve_officer() {
    read_gecos

    # ФИО: config → flag (перебивает config) → GECOS (если ещё пусто)
    FIO=""
    [[ -n "$DUTY_OFFICER" ]] && FIO="$DUTY_OFFICER"
    [[ -n "$OFFICER_CLI"  ]] && FIO="$OFFICER_CLI"
    [[ -z "$FIO" ]] && FIO="$GEC_FIO"

    # Если ФИО так и не определилось — спросить у пользователя
    [[ -z "$FIO" ]] && prompt_officer
    [[ -z "$FIO" ]] && warn "ФИО дежурного не задано — подпись ПДТВ будет неполной"
    return 0
}

#===============================================================================
# МОДУЛЬ M1 — Подготовка окружения
#===============================================================================
prepare_environment() {
    step M1 "Подготовка окружения"

    run mkdir -p "$PDTV_P" "$ZAGRUZKA"

    # Очистка Отработанные/<дата> от всего, кроме .zip
    local -a junk=()
    mapfile -d '' junk < <(find "$OTRABOTKA_P" -maxdepth 1 -type f '!' -iname '*.zip' -print0 2>/dev/null || true)
    _rm_list "${junk[@]:-}"

    # Перенос текстовых файлов из ПДТВ → ПДТВ/<дата>
    local -a txts=()
    mapfile -d '' txts < <(find "$PDTV" -maxdepth 1 -type f -iname '*.txt' -print0 2>/dev/null || true)
    _mv_into "$PDTV_P" "${txts[@]:-}"
    return 0
}

#===============================================================================
# МОДУЛЬ M2 — Упаковка бланков в ZIP
#===============================================================================
archive_documents() {
    step M2 "Упаковка бланков"
    command -v zip >/dev/null 2>&1 || { warn "  zip не найден — этап пропущен"; return 0; }
    local -a files=()
    mapfile -d '' files < <(find "$VHOD" -maxdepth 1 -type f "${_DOC_PRED[@]}" -print0 2>/dev/null || true)
    (( ${#files[@]} )) || { vlog "  Бланков нет"; return 0; }
    local f
    for f in "${files[@]}"; do
        if [[ "$DRY_RUN" == true ]]; then log "[would] zip -m: ${f##*/}"; STATS[blanks]=$(( STATS[blanks] + 1 )); continue; fi
        if zip -r -j -m -q "${f%.*}.zip" "$f" >/dev/null 2>&1; then
            STATS[blanks]=$(( STATS[blanks] + 1 ))
        else
            warn "  ошибка упаковки: ${f##*/}"
        fi
    done
    return 0
}

#===============================================================================
# МОДУЛЬ M3 — Распаковка ZIP из Входящих → Загрузка
#===============================================================================
unpack_and_move() {
    step M3 "Распаковка ZIP и приём архивов"

    # 1) ZIP из «Входящих» → распаковать в «Загрузку», исходники в «Отработанные».
    if command -v unzip >/dev/null 2>&1; then
        local -a zips=()
        mapfile -d '' zips < <(find "$VHOD" -maxdepth 1 -type f -iname '*.zip' -print0 2>/dev/null || true)
        if (( ${#zips[@]} )); then
            local z
            for z in "${zips[@]}"; do
                if [[ "$DRY_RUN" == true ]]; then log "[would] unzip → Загрузка: ${z##*/}"; continue; fi
                # -o : перезаписывать без запроса (иначе unzip зависает на вводе)
                unzip -q -o -d "$ZAGRUZKA" -- "$z" >/dev/null 2>&1 || warn "  ошибка распаковки: ${z##*/}"
            done
            _mv_into "$OTRABOTKA_P" "${zips[@]}"
            STATS[zip]=$(( STATS[zip] + ${#zips[@]} ))
        else
            vlog "  ZIP нет"
        fi
    else
        warn "  unzip не найден — ZIP из «Входящих» не распакованы"
    fi

    # 2) Прочие архивы (7z/rar/tar/gz/bz2/xz…) из «Входящих» → перенести в
    #    «Загрузку», чтобы их распаковал модуль M5 (в т.ч. вложенные).
    #    Делаем это только если M5 включён, иначе очистка их удалит.
    if [[ "$ENABLE_EXTRACT" == true ]]; then
        local -a others=()
        mapfile -d '' others < <(find "$VHOD" -maxdepth 1 -type f "${_ARC_PRED[@]}" '!' -iname '*.zip' -print0 2>/dev/null || true)
        if (( ${#others[@]} )); then
            if [[ "$DRY_RUN" == true ]]; then
                local o; for o in "${others[@]}"; do log "[would] принять в Загрузку: ${o##*/}"; done
            else
                vlog "  Принято архивов в Загрузку: ${#others[@]}"
            fi
            _mv_into "$ZAGRUZKA" "${others[@]}"
        fi
    fi
    return 0
}

#===============================================================================
# МОДУЛЬ M4 — Формирование ПДТВ
#===============================================================================
generate_pdtv() {
    step M4 "Формирование ПДТВ"

    # Имя бланка из имён НЕ-архивных файлов, через '_'
    local blank
    blank="$(find "$ZAGRUZKA" -maxdepth 1 -type f '!' "${_EXCL_PRED[@]}" -printf '%f\n' 2>/dev/null \
            | sed 's/\.[^.]*$//' | LC_ALL=C sort | paste -sd '_' || true)"
    [[ -z "$blank" ]] && blank="без_бланков"

    # Защита от превышения лимита имени файла (~255 байт)
    local fname="ПДТВ_${blank}.txt"
    while (( $(LC_ALL=C printf '%s' "$fname" | wc -c) > 200 )); do
        blank="${blank%?}"
        [[ -z "$blank" ]] && { blank="список"; fname="ПДТВ_${blank}.txt"; break; }
        fname="ПДТВ_${blank}….txt"
    done
    local pdtv_file="$PDTV/$fname"

    local file_count
    file_count="$(find "$ZAGRUZKA" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ' || true)"
    [[ -z "$file_count" ]] && file_count=0

    # Подпись: последняя строка ПДТВ — ФИО дежурного ({фио}). Лишние пробелы чистим.
    local sign="$SIGNATURE"
    sign="${sign//\{фио\}/$FIO}"
    sign="$(printf '%s\n' "$sign" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')"

    if [[ "$DRY_RUN" == true ]]; then
        log "[would] записать ПДТВ: $pdtv_file (файлов: $file_count)"
    else
        {
            printf '\xef\xbb\xbf'                              # BOM
            printf '%s\n' "$OTKUDA"
            printf 'Получен(ы) %s %s\n' "$file_count" "$(ru_plural "$file_count" файл файла файлов)"

            # Перечень: по размеру (возрастание). Разделитель — TAB (надёжнее '|')
            { find "$ZAGRUZKA" -maxdepth 1 -type f -printf '%s\t%f\n' 2>/dev/null || true; } \
                | LC_ALL=C sort -n -k1,1 \
                | while IFS=$'\t' read -r size filename; do
                    if [[ "$SHOW_HUMAN_SIZE" == true ]]; then
                        printf '"%s" - %s байт (%s)\n' "$filename" "$size" "$(human_size "$size")"
                    else
                        printf '"%s" - %s байт\n' "$filename" "$size"
                    fi
                  done

            printf 'Дата %s Время %s\n' "$DATE" "$(date +'%H:%M')"
            printf '%s\n' "$sign"
        } > "$pdtv_file"
        log "  ПДТВ: $pdtv_file"
        [[ "$ENABLE_OPEN" == true ]] && open_bg "$pdtv_file"
    fi

    # Перенос бланков doc/docx/txt/odt → Отработанные/<дата>
    local -a blanks=()
    mapfile -d '' blanks < <(find "$ZAGRUZKA" -maxdepth 1 -type f "${_DOC_PRED[@]}" -print0 2>/dev/null || true)
    _mv_into "$OTRABOTKA_P" "${blanks[@]:-}"
    return 0
}

#===============================================================================
# МОДУЛЬ M5 — Распаковка архивов (включая «архив в архиве»)
#===============================================================================
# Поддержаны: zip, 7z, rar, tar, tar.gz/tgz, tar.bz2/tbz, tar.xz/txz, gz, bz2, xz.
# «Архив в архиве» обрабатывается рекурсивно (до MAX_NEST_DEPTH уровней).

# Куда деть исходный архив после УСПЕШНОЙ распаковки: переносим в
# «Отработанные/<месяц>/<дата>» (исходник сохраняется рядом с разобранным содержимым).
_post_source() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    _mv_into "$OTRABOTKA_P" "$f"
}

# Распаковка через 7z (без пароля). Возврат: 0=ок, 2=неудача.
_sevenzip() {
    local f="$1" out="$2"
    command -v 7z >/dev/null 2>&1 || { warn "  7z не найден — пропуск: ${f##*/}"; return 2; }
    if 7z e -y -p"" -o"$out" -- "$f" >/dev/null 2>&1; then _post_source "$f"; return 0; fi
    return 2
}

# Декомпрессор одиночных файлов (gz/bz2/xz). Возврат: 0=ок, 2=ошибка/нет утилиты.
# Исходник сохраняем (-k) и переносим в «Отработанные».
_decompress() {
    local tool="$1" f="$2"
    command -v "$tool" >/dev/null 2>&1 || { warn "  $tool не найден — пропуск: ${f##*/}"; return 2; }
    "$tool" -dk -- "$f" >/dev/null 2>&1 || return 2
    _mv_into "$OTRABOTKA_P" "$f"
    return 0
}

# Распаковать один архив по расширению. Возврат: 0=ок, 2=неудача.
extract_archive() {
    local f="$1" out="$2"
    local low="${f,,}"
    case "$low" in
        *.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tbz2|*.tar.xz|*.txz)
            command -v tar >/dev/null 2>&1 || { warn "  tar не найден — пропуск: ${f##*/}"; return 2; }
            tar -xf "$f" -C "$out" >/dev/null 2>&1 || return 2   # GNU/bsdtar сами определяют сжатие
            _post_source "$f"; return 0 ;;
        *.gz)   _decompress gzip  "$f"; return $? ;;
        *.bz2)  _decompress bzip2 "$f"; return $? ;;
        *.xz)   _decompress xz    "$f"; return $? ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1 && unzip -q -o -d "$out" -- "$f" >/dev/null 2>&1; then
                _post_source "$f"; return 0
            fi
            _sevenzip "$f" "$out"; return $? ;;
        *.7z|*.rar)
            _sevenzip "$f" "$out"; return $? ;;
        *)
            # Расширение неизвестно — распознаём архив ПО СОДЕРЖИМОМУ. 7z вскрывает
            # zip/7z/rar/gz/bz2/xz по сигнатуре, расширение ему не важно.
            local kind; kind="$(_sniff_kind "$f")"
            case "$kind" in
                zip|7z|rar|gzip|bzip2|xz)
                    _sevenzip "$f" "$out"; return $? ;;
            esac
            # Сигнатуры в начале нет — пробуем tar (plain/сжатый: tar сам определит
            # компрессию по содержимому, расширение не нужно).
            if command -v tar >/dev/null 2>&1 && tar -tf "$f" >/dev/null 2>&1; then
                tar -xf "$f" -C "$out" >/dev/null 2>&1 || return 2
                _post_source "$f"; return 0
            fi
            # Последняя попытка — 7z по содержимому (cab/iso/др. поддерживаемые форматы).
            if command -v 7z >/dev/null 2>&1 && 7z l -- "$f" >/dev/null 2>&1; then
                _sevenzip "$f" "$out"; return $?
            fi
            warn "  неизвестный тип архива: ${f##*/}"; return 2 ;;
    esac
}

handle_archives() {
    (( ${_DEEP_PASS:-0} == 0 )) && step M5 "Распаковка архивов"

    # Хотя бы один экстрактор должен быть в наличии
    if ! command -v 7z >/dev/null 2>&1 && ! command -v unzip >/dev/null 2>&1 \
       && ! command -v tar >/dev/null 2>&1 && ! command -v gzip >/dev/null 2>&1; then
        warn "  ни 7z/unzip/tar/gzip не найдено — этап пропущен"; return 0
    fi

    # DRY-RUN: показать архивы одним проходом, без рекурсии
    if [[ "$DRY_RUN" == true ]]; then
        local -a all0=()
        mapfile -d '' all0 < <(find "$ZAGRUZKA" -maxdepth 1 -type f -print0 2>/dev/null || true)
        local a0; for a0 in "${all0[@]:-}"; do
            [[ -n "$a0" ]] && _is_archive_file "$a0" && log "[would] извлечь: ${a0##*/}"
        done
        return 0
    fi

    local bad_arc="$PDTV/НЕ_РАСПАКОВАНО.txt"

    # ТОЛЬКО распаковка (с поддержкой «архив в архиве»).
    local depth=0
    while (( depth < MAX_NEST_DEPTH )); do
        # Архивы ищем не только по расширению, но и ПО СОДЕРЖИМОМУ — чтобы поймать
        # архив с неговорящим расширением.
        local -a allf=() arcs=()
        mapfile -d '' allf < <(find "$ZAGRUZKA" -maxdepth 1 -type f -print0 2>/dev/null || true)
        local _af; for _af in "${allf[@]:-}"; do
            [[ -n "$_af" ]] && _is_archive_file "$_af" && arcs+=( "$_af" )
        done
        (( ${#arcs[@]} == 0 )) && break        # архивов не осталось

        (( depth > 0 )) && vlog "  Вложенность, уровень $depth (архивов: ${#arcs[@]})"
        local a name rc
        for a in "${arcs[@]}"; do
            name="${a##*/}"
            log "  Архив: $name"
            rc=0; extract_archive "$a" "$ZAGRUZKA" || rc=$?
            case "$rc" in
                0) ok "распакован: $name"; STATS[arc_ok]=$(( STATS[arc_ok] + 1 )) ;;
                2) warn "    ошибка распаковки: $name"; printf '%s\n' "$name" >> "$bad_arc"
                   _mv_into "$OTRABOTKA_P" "$a"; STATS[arc_fail]=$(( STATS[arc_fail] + 1 )) ;;
            esac
        done
        depth=$(( depth + 1 ))
    done

    # Предупредить, если после лимита глубины архивы всё ещё остались
    local -a stillall=() still=()
    mapfile -d '' stillall < <(find "$ZAGRUZKA" -maxdepth 1 -type f -print0 2>/dev/null || true)
    local _sf; for _sf in "${stillall[@]:-}"; do
        [[ -n "$_sf" ]] && _is_archive_file "$_sf" && still+=( "$_sf" )
    done
    (( ${#still[@]} )) && warn "  достигнут предел вложенности ($MAX_NEST_DEPTH) — осталось архивов: ${#still[@]}"
    return 0
}

#===============================================================================
# Глубокая распаковка ВЛОЖЕННОГО (M5 в цикле)
#===============================================================================
# ПДТВ (M4) формируется ДО этого шага — по ПОЛУЧЕННЫМ файлам (как пришли). Здесь же
# добываем их содержимое: распаковываем архивы (M5) до стабилизации набора файлов в
# «Загрузке». Это раскрывает цепочки «архив в архиве» → итоговые файлы, которые затем
# финальная очистка (M6) перенесёт во «Входящие».
deep_extract() {
    [[ "$ENABLE_EXTRACT" == true ]] || return 0
    local pass=0 prev="" cur
    while (( pass < MAX_NEST_DEPTH )); do
        _DEEP_PASS="$pass"
        handle_archives                                       # M5
        cur="$(find "$ZAGRUZKA" -type f -printf '%s\t%p\n' 2>/dev/null | LC_ALL=C sort || true)"
        [[ "$cur" == "$prev" ]] && break        # набор файлов стабилизировался
        prev="$cur"; pass=$(( pass + 1 ))
    done
    unset _DEEP_PASS
    return 0
}

#===============================================================================
# МОДУЛЬ M6 — Финальная очистка
#===============================================================================
final_cleanup() {
    step M6 "Финальная очистка"

    # Удаление оставшихся архивов из Загрузки
    local -a leftover=()
    mapfile -d '' leftover < <(find "$ZAGRUZKA" -maxdepth 1 -type f "${_ARC_PRED[@]}" -print0 2>/dev/null || true)
    _rm_list "${leftover[@]:-}"

    # Перенос остатка → Входящие. РЕКУРСИВНО (без -maxdepth): архивы нередко
    # распаковываются во вложенную папку — иначе извлечённые файлы (напр. PDF)
    # остались бы в «Загрузке» и пропали при её удалении, а не открылись бы.
    local -a rest=()
    mapfile -d '' rest < <(find "$ZAGRUZKA" -type f -print0 2>/dev/null || true)
    _mv_into "$VHOD" "${rest[@]:-}"

    # Удаление каталога Загрузка
    if [[ "$DRY_RUN" == true ]]; then
        log "[would] rm -r: $ZAGRUZKA"
    else
        rm -rf -- "$ZAGRUZKA" 2>/dev/null || true
    fi
    # Права (chmod) вынесены в отдельный шаг apply_permissions, который идёт ПОСЛЕ
    # открытия файлов: chmod -R по общему каталогу может быть долгим, и оператор не
    # должен ждать его завершения, пока откроются окна с документами.
    return 0
}

#===============================================================================
# МОДУЛЬ chmod — Раздача прав (ОТДЕЛЬНО и ПОСЛЕ открытия файлов)
#===============================================================================
apply_permissions() {
    step chmod "Раздача прав"
    if [[ ! -d "$CHMOD_TARGET" ]]; then
        warn "  Каталог не найден, права не изменены: $CHMOD_TARGET"; return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log "[would] chmod -R $CHMOD_MODE $CHMOD_TARGET"; return 0
    fi
    # На общем каталоге часть файлов принадлежит другим — chmod на них вернёт
    # ненулевой код. Это штатно: глушим, чтобы не ронять прогон.
    chmod -R "$CHMOD_MODE" "$CHMOD_TARGET" 2>/dev/null \
        || note "часть файлов не сменила права (чужой владелец) — норма для общего каталога"
    log "  Права $CHMOD_MODE: $CHMOD_TARGET"
    return 0
}

#===============================================================================
# МОДУЛЬ M7 — Открытие файлов
#===============================================================================
open_files() {
    local dir="$1" count=0
    [[ -d "$dir" ]] || return 0
    local -a files=()
    mapfile -d '' files < <(find "$dir" -maxdepth 1 -type f "${_OPEN_PRED[@]}" -print0 2>/dev/null | sort -z || true)
    local f
    for f in "${files[@]:-}"; do
        [[ -z "$f" ]] && continue
        (( count < OPEN_LIMIT )) || break
        if [[ "$DRY_RUN" == true ]]; then
            log "[would] open: ${f##*/}"
        else
            open_bg "$f"
        fi
        count=$(( count + 1 ))
    done
    return 0
}

open_documents() {
    step M7 "Открытие файлов"
    open_files "$OTRABOTKA_P"
    open_files "$VHOD"
    return 0
}

#===============================================================================
# УПРАВЛЕНИЕ МОДУЛЯМИ (--only / --skip / --list-modules)
#===============================================================================
# Имена модулей для CLI: blanks unzip pdtv extract cleanup chmod open
set_module() {
    local n="$1" v="$2"
    case "$n" in
        blanks)  ENABLE_ARCHIVE_BLANKS=$v ;;
        unzip)   ENABLE_UNPACK_ZIP=$v ;;
        pdtv)    ENABLE_PDTV=$v ;;
        extract) ENABLE_EXTRACT=$v ;;
        cleanup) ENABLE_CLEANUP=$v ;;
        chmod)   ENABLE_CHMOD=$v ;;
        open)    ENABLE_OPEN=$v ;;
        *)       die "Неизвестный модуль: '$n' (см. --list-modules)" ;;
    esac
}

all_modules() { printf '%s\n' blanks unzip pdtv extract cleanup chmod open; }

set_modules_csv() {  # set_modules_csv <true|false> <csv>
    local v="$1" csv="$2" item
    csv="${csv//,/ }"
    for item in $csv; do set_module "$item" "$v"; done
}

list_modules() {
    printf 'Модули (имя — статус):\n'
    local m var st
    for m in $(all_modules); do
        case "$m" in
            blanks)  var=$ENABLE_ARCHIVE_BLANKS ;;
            unzip)   var=$ENABLE_UNPACK_ZIP ;;
            pdtv)    var=$ENABLE_PDTV ;;       extract) var=$ENABLE_EXTRACT ;;
            cleanup) var=$ENABLE_CLEANUP ;;    chmod)  var=$ENABLE_CHMOD ;;
            open)    var=$ENABLE_OPEN ;;
        esac
        [[ "$var" == true ]] && st="включён" || st="выключен"
        printf '  %-9s — %s\n' "$m" "$st"
    done
}

#===============================================================================
# СПРАВКА / ВЕРСИЯ / РАЗБОР АРГУМЕНТОВ
#===============================================================================
show_help() {
    cat << 'HELPEOF'
pdtv - Обработчик входящих документов (распаковка, ПДТВ)

ИСПОЛЬЗОВАНИЕ:
    pdtv [ОПЦИИ]

ОБЩИЕ ОПЦИИ:
    -d, --date ДАТА       Рабочая дата ДД.ММ.ГГГГ (по умолчанию — сегодня)
        --root ПУТЬ       Корневой каталог (по умолчанию /DOCS/Общая)
        --dry-run         Показать действия БЕЗ изменений на диске
        --verbose         Подробный лог
        --pause           Ждать Enter в конце (удобно для запуска по ярлыку)
        --no-pause        Не ждать Enter в конце
        --quiet           Только предупреждения, ошибки и итоговая сводка
        --color           Принудительно цветной вывод
        --no-color        Отключить цвет (также действует переменная NO_COLOR)
        --month           Уровень месяца в каталогах: «01 Январь/<дата>»
        --no-month        Без уровня месяца: только «<дата>»
    -h, --help            Эта справка
    -v, --version         Версия

ДЕЖУРНЫЙ (подпись ПДТВ):
        --officer ФИО     Задать ФИО дежурного вручную (перебивает GECOS)

АРХИВЫ:
        --max-depth N     Глубина распаковки «архив в архиве» (по умолчанию 5)
        --keep-archives   Не удалять исходные архивы, а переносить в Отработанные

ГРАФИЧЕСКИЙ РЕЖИМ (Zenity):
        --gui             Принудительно открыть окно настроек
        --no-gui          Никогда не открывать окно (только CLI)
        --make-shortcut   Создать ярлык на рабочем столе с текущей
                          конфигурацией и выйти (без обработки)
                          В графике окно появляется автоматически при
                          запуске по ярлыку (без терминала).

УПРАВЛЕНИЕ МОДУЛЯМИ:
        --only СПИСОК     Выполнить ТОЛЬКО эти модули (через запятую)
        --skip СПИСОК     Пропустить эти модули (через запятую)
        --list-modules    Показать модули и их статус, выйти
        --no-blanks       Не упаковывать бланки в zip
        --no-unzip        Не распаковывать zip из «Входящих»
        --no-pdtv         Не формировать лист ПДТВ
        --no-extract      Не распаковывать архивы
        --no-cleanup      Не выполнять финальную очистку
        --no-chmod        Не выставлять права доступа
        --no-open         Не открывать файлы в конце

    Имена модулей: blanks unzip pdtv extract cleanup chmod open

ПРИМЕРЫ:
    pdtv
    pdtv --dry-run --verbose
    pdtv -d 31.12.2026
    pdtv --officer "Иванов И.И."
    pdtv --only pdtv,extract
    pdtv --skip blanks,chmod
    pdtv --root /mnt/docs --no-chmod
HELPEOF
}

show_version() { echo "pdtv версия $VERSION"; }

parse_args() {
    while (( $# )); do
        case "$1" in
            -h|--help)        show_help; exit 0 ;;
            -v|--version)     show_version; exit 0 ;;
            --verbose)        VERBOSE=true; shift ;;
            --dry-run)        DRY_RUN=true; shift ;;
            --pause)          PAUSE_ON_EXIT=true; shift ;;
            --no-pause)       PAUSE_ON_EXIT=false; shift ;;
            --keep-archives)  KEEP_ARCHIVES=true; shift ;;
            --quiet)          QUIET=true; shift ;;
            --color)          USE_COLOR=true; shift ;;
            --no-color)       USE_COLOR=false; shift ;;
            --month)          MONTH_GROUPING=true; shift ;;
            --no-month)       MONTH_GROUPING=false; shift ;;
            --gui)            FORCE_GUI=true; shift ;;
            --no-gui)         FORCE_NOGUI=true; shift ;;
            --make-shortcut)  _MAKE_SHORTCUT=true; shift ;;
            -d|--date)        [[ -z "${2:-}" ]] && die "--date требует ДД.ММ.ГГГГ"; DATE="$2"; shift 2 ;;
            --root)           [[ -z "${2:-}" ]] && die "--root требует путь"; ROOT="${2%/}"; _ROOT_FROM_CLI=true; shift 2 ;;
            --officer)        [[ -z "${2:-}" ]] && die "--officer требует ФИО"; OFFICER_CLI="$2"; shift 2 ;;
            --max-depth)      [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--max-depth требует число"; MAX_NEST_DEPTH="$2"; shift 2 ;;
            --only)           [[ -z "${2:-}" ]] && die "--only требует список модулей"
                              set_modules_csv false "$(all_modules | paste -sd ',')"
                              set_modules_csv true "$2"; shift 2 ;;
            --skip)           [[ -z "${2:-}" ]] && die "--skip требует список модулей"
                              set_modules_csv false "$2"; shift 2 ;;
            --list-modules)   _DO_LIST_MODULES=true; shift ;;
            --no-blanks)      ENABLE_ARCHIVE_BLANKS=false; shift ;;
            --no-unzip)       ENABLE_UNPACK_ZIP=false; shift ;;
            --no-pdtv)        ENABLE_PDTV=false; shift ;;
            --no-extract)     ENABLE_EXTRACT=false; shift ;;
            --no-cleanup)     ENABLE_CLEANUP=false; shift ;;
            --no-chmod)       ENABLE_CHMOD=false; shift ;;
            --no-open)        ENABLE_OPEN=false; shift ;;
            *)                die "Неизвестный параметр: $1 (см. --help)" ;;
        esac
    done
}

#===============================================================================
# ПРОВЕРКА ЗАВИСИМОСТЕЙ
#===============================================================================
check_deps() {
    local c
    for c in find sed sort paste grep tr wc basename mkdir mv rm; do
        command -v "$c" >/dev/null 2>&1 || die "Не найдена утилита: $c"
    done
    # Опциональные — предупреждаем только о включённых модулях
    [[ "$ENABLE_ARCHIVE_BLANKS" == true ]] && { command -v zip   >/dev/null 2>&1 || warn "zip не найден — упаковка бланков будет пропущена"; }
    [[ "$ENABLE_UNPACK_ZIP" == true ]]     && { command -v unzip >/dev/null 2>&1 || warn "unzip не найден — распаковка ZIP будет пропущена"; }
    if [[ "$ENABLE_EXTRACT" == true ]]; then
        for c in 7z tar gzip bzip2 xz; do
            command -v "$c" >/dev/null 2>&1 || warn "$c не найден — часть архивов не распакуется"
        done
    fi
    return 0
}

#===============================================================================
# ПОДТВЕРЖДЕНИЕ И СОЗДАНИЕ БАЗОВЫХ КАТАЛОГОВ
#===============================================================================
# Спросить «да/нет»: в терминале — текстом (по умолчанию ДА), без терминала, но
# в графике — окном zenity, иначе (неинтерактивно) — считаем ДА.
_confirm() {
    local q="$1"
    if [[ -t 0 && -t 1 ]]; then
        local a; printf '%s%s [Д/н]: %s' "$C_YEL" "$q" "$C_RESET" >&2; IFS= read -r a || true
        case "$a" in [НнNn]*) return 1 ;; *) return 0 ;; esac
    elif [[ -n "${DISPLAY:-}" ]] && command -v zenity >/dev/null 2>&1; then
        zenity --question --title="pdtv" --text="$q" --ok-label="Да" --cancel-label="Нет" 2>/dev/null
    else
        return 0
    fi
}

# Минимально необходимые каталоги: Входящие, ПДТВ, ! Отработанные.
# Если их нет — предложить создать (а не падать с ошибкой).
ensure_base_dirs() {
    if [[ ! -d "$ROOT" ]]; then
        if _confirm "Корневой каталог не найден: «$ROOT». Создать?"; then
            mkdir -p "$ROOT" 2>/dev/null || die "Не удалось создать корневой каталог: $ROOT"
            ok "Создан корневой каталог: $ROOT"
        else
            die "Корневой каталог не найден: $ROOT"
        fi
    fi
    local d
    for d in "$VHOD" "$PDTV" "$OTRABOTKA"; do
        [[ -d "$d" ]] && continue
        if _confirm "Не найден каталог «${d#$ROOT/}». Создать?"; then
            run mkdir -p "$d"; ok "Создан каталог: ${d#$ROOT/}"
        else
            warn "Каталог не создан: $d (некоторые этапы могут не сработать)"
        fi
    done
    return 0
}

#===============================================================================
# ЗАВЕРШЕНИЕ (пауза для запуска по ярлыку)
#===============================================================================
maybe_pause() {
    case "$PAUSE_ON_EXIT" in
        false) return 0 ;;
        auto)  [[ -t 0 && -t 1 ]] || return 0 ;;
        true)  [[ -t 0 ]] || return 0 ;;
    esac
    printf '\nНажмите Enter для выхода… ' >&2
    IFS= read -r _ || true
}

#===============================================================================
# GUI (Zenity): окно настроек + создание ярлыка на рабочем столе
#===============================================================================
# Нужен ли графический режим: явный --gui, либо авто (есть DISPLAY и zenity,
# и запуск НЕ из интерактивного терминала — то есть по ярлыку).
want_gui() {
    [[ "$FORCE_GUI"   == true ]] && return 0
    [[ "$FORCE_NOGUI" == true ]] && return 1
    # Единообразно с uch_list: окно настроек само открывается, если есть графика
    # (DISPLAY+zenity) и скрипт запущен БЕЗ аргументов. С любыми CLI-аргументами
    # работаем в терминале; принудительно окно — ключом --gui.
    [[ "$HAD_ARGS" == false && -n "${DISPLAY:-}" ]] && command -v zenity >/dev/null 2>&1
}

# Безопасный вызов zenity. Штатный ненулевой код (Отмена / доп.кнопка) НЕ должен
# дёргать ERR-trap: errtrace (set -E) протаскивает ловушку в субшелл подстановки
# команд, поэтому даже обёртка set +e не спасала и появлялась ложная
# «Непредвиденная ошибка: строка …, код 1». Здесь на время вызова снимаем и
# ловушку, и errexit/errtrace, затем восстанавливаем. Вывод → переменная ZNT_OUT.
ZNT_OUT=""
znt() {
    local _rc
    trap - ERR; set +Ee
    ZNT_OUT="$(zenity "$@" 2>/dev/null)"; _rc=$?
    set -Ee; trap 'on_error "$LINENO"' ERR
    return "$_rc"
}

# Каталог рабочего стола: xdg → Astra Fly (~/Desktops/Desktop1) → рус/англ варианты
desktop_dir_path() {
    local d
    # Astra (fly) держит НЕСКОЛЬКО рабочих столов в ~/Desktops/Desktop1..N и
    # показывает первый. xdg-user-dir на таких машинах часто отдаёт ~/Desktop,
    # которого на экране НЕТ — ярлык «пропадает». Поэтому Astra-каталог первым.
    for d in "$HOME/Desktops/Desktop1" "$HOME/Рабочий стол"; do
        [[ -d "$d" ]] && { printf '%s' "$d"; return 0; }
    done
    if command -v xdg-user-dir >/dev/null 2>&1; then
        d="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
        [[ -n "$d" && -d "$d" ]] && { printf '%s' "$d"; return 0; }
    fi
    [[ -d "$HOME/Desktop" ]] && { printf '%s' "$HOME/Desktop"; return 0; }
    printf '%s' "$HOME/Desktop"   # будет создан
}

# Собрать строку флагов CLI из ТЕКУЩЕЙ конфигурации (для Exec в ярлыке).
# Дату НЕ фиксируем — ярлык всегда работает на «сегодня».
build_cli_flags() {
    local f=""
    f+=" --root \"$ROOT\""
    [[ -n "$OFFICER_CLI" ]] && f+=" --officer \"$OFFICER_CLI\""
    [[ "$MONTH_GROUPING" == false ]] && f+=" --no-month"
    [[ "$KEEP_ARCHIVES"  == true  ]] && f+=" --keep-archives"
    [[ "$ENABLE_ARCHIVE_BLANKS" == true ]] || f+=" --no-blanks"
    [[ "$ENABLE_UNPACK_ZIP"     == true ]] || f+=" --no-unzip"
    [[ "$ENABLE_PDTV"           == true ]] || f+=" --no-pdtv"
    [[ "$ENABLE_EXTRACT"        == true ]] || f+=" --no-extract"
    [[ "$ENABLE_CLEANUP"        == true ]] || f+=" --no-cleanup"
    [[ "$ENABLE_CHMOD"          == true ]] || f+=" --no-chmod"
    [[ "$ENABLE_OPEN"           == true ]] || f+=" --no-open"
    printf '%s' "$f"
}

# Создать .desktop-ярлык на рабочем столе с текущей конфигурацией.
# Имя файла и подпись включают ФИО дежурного: у каждого дежурного СВОЙ ярлык
# (pdtv_Иванов_И.И..desktop) — второй ярлык больше не затирает первый.
# Повторное создание с тем же ФИО обновляет его же ярлык (это ожидаемо).
make_desktop_shortcut() {
    local script desktop_dir target flags who suffix name
    script="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$0")"
    desktop_dir="$(desktop_dir_path)"
    mkdir -p "$desktop_dir" 2>/dev/null || true
    who="$(trim "${OFFICER_CLI:-}")"
    suffix=""
    name="ПДТВ — обработка входящих"
    if [[ -n "$who" ]]; then
        # Имя файла: пробелы → _, выкидываем опасные для fly/шелла символы.
        suffix="_${who//[\/\\\"\'!]/}"
        suffix="${suffix// /_}"
        name+=" ($who)"
    fi
    target="$desktop_dir/pdtv${suffix}.desktop"
    flags="$(build_cli_flags)"

    cat > "$target" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Comment=Обработка входящих по сохранённой конфигурации (без окон и терминала)
Exec=bash "$script"$flags
Terminal=false
Icon=utilities-terminal
Categories=Utility;Office;
EOF
    chmod +x "$target" 2>/dev/null || true
    printf '%s' "$target"          # только путь в stdout (для захвата вызывающим)
}

# Окно ввода конфигурации (zenity --forms) + чек-лист модулей.
# ВАЖНО: чаще всего меняют именно РАБОЧУЮ ПАПКУ (корень) — поэтому она первой
# и подписана подробно. Пустые поля = текущие значения (сохранённые в прошлый раз
# или из системы GECOS). Введённое СОХРАНЯЕТСЯ для следующего запуска и попадает
# в ярлык на рабочем столе.
gui_configure() {
    read_gecos   # чтобы показать в подсказках, что подставится «из системы»

    # Текущие значения для подсказок: сохранённое/CLI → иначе из системы GECOS.
    local cur_fio="${OFFICER_CLI:-${GEC_FIO:-—}}"

    local out
    znt --forms --title="ПДТВ — настройка запуска" \
        --text="Заполняйте только то, что нужно ИЗМЕНИТЬ. Пустое поле = текущее значение.
Введённые значения сохранятся и подставятся при следующем запуске (и в ярлык).

РАБОЧАЯ ПАПКА (корень) — внутри неё: «Входящие», «ПДТВ», «! Отработанные»." \
        --add-entry="РАБОЧАЯ ПАПКА — откуда/куда (сейчас: $ROOT)" \
        --add-entry="Рабочая дата ДД.ММ.ГГГГ (пусто = сегодня $DATE)" \
        --add-entry="Дежурный, ФИО (пусто = $cur_fio)" \
        --separator='|' --width=600 \
        || { note "Настройка отменена"; exit 0; }
    out="$ZNT_OUT"

    local r d o
    IFS='|' read -r r d o <<< "$out"
    r="$(trim "${r:-}")"; d="$(trim "${d:-}")"; o="$(trim "${o:-}")"
    [[ -n "$r"  ]] && ROOT="${r%/}"
    [[ -n "$d"  ]] && DATE="$d"
    [[ -n "$o"  ]] && OFFICER_CLI="$o"

    # Сохранить рабочую папку / ФИО для следующего запуска.
    save_config

    # Чек-лист модулей: предвыбраны включённые
    local m on
    local -a rows=()
    for m in blanks unzip pdtv extract cleanup chmod open; do
        case "$m" in
            blanks)  on=$ENABLE_ARCHIVE_BLANKS ;;
            unzip)   on=$ENABLE_UNPACK_ZIP ;;
            pdtv)    on=$ENABLE_PDTV ;;            extract) on=$ENABLE_EXTRACT ;;
            cleanup) on=$ENABLE_CLEANUP ;;         chmod)   on=$ENABLE_CHMOD ;;
            open)    on=$ENABLE_OPEN ;;
        esac
        rows+=( "$on" "$m" )
    done
    if znt --list --checklist --title="ПДТВ — модули" \
        --text="Отметьте этапы обработки, которые выполнять" \
        --column="Вкл" --column="Этап" "${rows[@]}" \
        --separator='|'; then
        # Применяем выбор: сначала всё выкл, затем включаем отмеченные
        if [[ -n "$ZNT_OUT" ]]; then
            set_modules_csv false "blanks,unzip,pdtv,extract,cleanup,chmod,open"
            set_modules_csv true "${ZNT_OUT//|/,}"
        fi
    fi
}

# Диалог действия: Запустить / Создать ярлык / Отмена (с повтором после ярлыка).
# znt() снимает ERR-trap на время вызова, поэтому «Отмена»/доп.кнопка больше не
# вызывают ложную «Непредвиденную ошибку».
gui_action() {
    local rc
    while true; do
        # ВАЖНО: znt() возвращает 1 при «Отмена»/доп.кнопке — это ШТАТНО.
        # Bare-вызов под set -Ee дёргал бы ERR-trap → ложная «строка 1481, код 1»,
        # поэтому код выхода снимаем через «|| rc=$?» (errexit здесь не срабатывает).
        rc=0
        znt --question --title="ПДТВ" \
            --text="Готово к запуску.

Рабочая папка: $ROOT
Дата:          $DATE
Дежурный:      ${OFFICER_CLI:-<из системы>}

«Создать ярлык» сохранит эти настройки на рабочий стол." \
            --ok-label="Запустить" --cancel-label="Отмена" \
            --extra-button="Создать ярлык на рабочем столе" || rc=$?
        if [[ "$ZNT_OUT" == "Создать ярлык на рабочем столе" ]]; then
            local made; made="$(make_desktop_shortcut)"
            znt --info --title="ПДТВ" --text="Ярлык создан:\n$made" || true
            continue                       # вернуться к выбору: запустить или отмена
        elif (( rc != 0 )); then
            note "Запуск отменён пользователем"; exit 0
        fi
        break                              # «Запустить» → продолжаем обработку
    done
}

#===============================================================================
# UI: БАННЕР И ИТОГОВАЯ СВОДКА
#===============================================================================
print_banner() {
    [[ "$QUIET" == true ]] && return 0
    local line='══════════════════════════════════════════════════════'
    local active=0 m
    for m in "$ENABLE_ARCHIVE_BLANKS" "$ENABLE_UNPACK_ZIP" "$ENABLE_PDTV" \
             "$ENABLE_EXTRACT" "$ENABLE_CLEANUP" "$ENABLE_CHMOD" "$ENABLE_OPEN"; do
        [[ "$m" == true ]] && active=$(( active + 1 ))
    done
    printf '\n%s%s%s\n' "$C_CYA" "$line" "$C_RESET"
    printf '%s  pdtv %s%s — обработчик входящих документов / ПДТВ\n' "$C_BLD" "$VERSION" "$C_RESET"
    printf '%s%s%s\n' "$C_CYA" "$line" "$C_RESET"
    printf '  %s•%s Дата:    %s%s%s' "$C_CYA" "$C_RESET" "$C_BLD" "$DATE" "$C_RESET"
    [[ "$DRY_RUN" == true ]] && printf '   %s[DRY-RUN]%s' "$C_YEL$C_BLD" "$C_RESET"
    printf '\n'
    printf '  %s•%s Период:  %s%s%s\n' "$C_CYA" "$C_RESET" "$C_DIM" "$PERIOD" "$C_RESET"
    printf '  %s•%s Корень:  %s%s%s\n' "$C_CYA" "$C_RESET" "$C_DIM" "$ROOT" "$C_RESET"
    printf '  %s•%s Модулей активно: %s%s/7%s\n' "$C_CYA" "$C_RESET" "$C_BLD" "$active" "$C_RESET"
    printf '%s%s%s\n' "$C_DIM" "$line" "$C_RESET"
}

_srow() {  # _srow «метка» значение
    printf '  %s•%s %s: %s%s%s\n' "$C_CYA" "$C_RESET" "$1" "$C_BLD" "$2" "$C_RESET"
}

print_summary() {
    local line='──────────────────────────────────────────────────────'
    printf '\n%s%s%s\n' "$C_DIM" "$line" "$C_RESET"
    printf '%s  Сводка%s  %s(заняло %sс)%s\n' "$C_BLD" "$C_RESET" "$C_DIM" "$SECONDS" "$C_RESET"
    printf '%s%s%s\n' "$C_DIM" "$line" "$C_RESET"
    _srow "Распаковано ZIP"         "${STATS[zip]}"
    _srow "Распаковано архивов"     "${STATS[arc_ok]}"
    (( STATS[arc_fail] > 0 )) && _srow "  не распаковано"  "${STATS[arc_fail]}"
    _srow "Упаковано бланков"       "${STATS[blanks]}"
    if (( STATS[warn] > 0 )); then
        printf '  %s⚠ Предупреждений: %s%s\n' "$C_YEL" "${STATS[warn]}" "$C_RESET"
    else
        printf '  %s✓ Без предупреждений%s\n' "$C_GRN" "$C_RESET"
    fi
    printf '%s%s%s\n' "$C_DIM" "$line" "$C_RESET"
}

#===============================================================================
# ОБРАБОТКА НЕПРЕДВИДЕННЫХ ОШИБОК (errtrace + ERR-trap)
#===============================================================================
on_error() {
    local rc=$? ln="${1:-?}"
    printf '%s✗ Непредвиденная ошибка: строка %s, код %s%s\n' \
        "$C_RED$C_BLD" "$ln" "$rc" "$C_RESET" >&2
}

#===============================================================================
# MAIN
#===============================================================================
_DO_LIST_MODULES=false
FORCE_GUI=false
FORCE_NOGUI=false
_MAKE_SHORTCUT=false
HAD_ARGS=false            # были ли переданы CLI-аргументы (влияет на авто-GUI)

main() {
    [[ $# -gt 0 ]] && HAD_ARGS=true
    parse_args "$@"
    setup_colors
    trap 'on_error "$LINENO"' ERR
    load_config              # подставить сохранённые ROOT/ФИО (CLI важнее)

    if [[ "$_DO_LIST_MODULES" == true ]]; then list_modules; exit 0; fi

    # Создать ярлык и выйти (без обработки)
    if [[ "$_MAKE_SHORTCUT" == true ]]; then
        local _t; _t="$(make_desktop_shortcut)"; ok "Ярлык создан: $_t"; exit 0
    fi

    # Графический режим: окно настроек + выбор «Запустить / Создать ярлык»
    if want_gui; then
        gui_configure
        gui_action
    fi

    ensure_utf8_locale
    init_paths
    SECONDS=0

    print_banner
    [[ "$DRY_RUN" == true ]] && note "РЕЖИМ DRY-RUN: изменения на диск НЕ вносятся"
    [[ "$VERBOSE" == true ]] && list_modules >&2

    check_deps

    # Базовые каталоги (Входящие, ПДТВ, Отработанные) — при отсутствии предложить создать
    ensure_base_dirs

    # Замок от двойного запуска: у каждого дежурного свой ярлык, но рабочая
    # папка общая — параллельная обработка перемешала бы перенос файлов.
    # flock — штатный util-linux; замок снимается сам при выходе процесса.
    if command -v flock >/dev/null 2>&1 && exec 9>"$ROOT/.pdtv.lock"; then
        if ! flock -n 9; then
            die "Обработка уже идёт (другой запуск в «$ROOT») — дождитесь завершения"
        fi
    fi

    [[ "$ENABLE_PDTV" == true ]] && resolve_officer
    vlog "Пользователь: ${USER:-?} | GECOS: '${GECOS_FULL}' | ФИО: '${FIO}'"

    # --- Конвейер модулей (каждый под своим выключателем) ---
    prepare_environment                                            # M1  подготовка окружения
    [[ "$ENABLE_ARCHIVE_BLANKS" == true ]] && archive_documents    # M2
    [[ "$ENABLE_UNPACK_ZIP" == true ]]     && unpack_and_move       # M3  вскрыть внешний zip
    # ВАЖЕН ПОРЯДОК. Перечень ПДТВ (M4) формируем по ПОЛУЧЕННЫМ файлам — как они пришли:
    # содержимое внешнего zip и принятые архивы (напр. 4 док + 4 архива = 8 файлов), а
    # НЕ их распакованная «начинка». Поэтому M4 идёт ДО глубокой распаковки.
    [[ "$ENABLE_PDTV" == true ]]           && generate_pdtv         # M4  перечень полученного
    # Затем добываем вложенное содержимое: распаковка архивов (в т.ч. «архив в архиве»)
    # в цикле, пока раскрываются архив→архив→…→итоговые файлы.
    deep_extract                                                   # M5  (до стабилизации)
    [[ "$ENABLE_CLEANUP" == true ]]        && final_cleanup         # M6
    # Открытие файлов — ПЕРЕД раздачей прав: окна должны появляться сразу, не
    # дожидаясь долгого chmod -R по общему каталогу.
    [[ "$ENABLE_OPEN" == true ]]           && open_documents        # M7
    [[ "$ENABLE_CHMOD" == true ]]          && apply_permissions     # chmod (после открытия)

    print_summary
    ok "Обработка завершена"
    maybe_pause
    return 0
}

main "$@"
