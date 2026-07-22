#!/usr/bin/env python3
"""Фаззер pdtv: случайные «злые» деревья входящих + проверка, что ни один
документ не потерян.

ЗАЧЕМ. Обычные тесты проверяют сценарии, которые мы придумали. Потеря документа
на офлайн-АРМ невосстановима, а ломается она на том, чего никто не придумал:
имя с переводом строки, кириллица в архиве, файл без расширения, имя длиной 250,
архив в архиве в архиве.

ДВА ИНВАРИАНТА:
    1) содержимое КАЖДОГО входного файла после прогона достижимо (хотя бы
       внутри уцелевшего архива). Нарушение = безвозвратная потеря документа;
    2) документ, пришедший внутри архива, лежит РОССЫПЬЮ — оператор получает
       его файлом, а не «оно где-то в архиве». Нарушение = работа не сделана.

Второй инвариант нужен отдельно: без него целый класс багов проходит молча —
внутренности подархивов не разложились, но сам архив цел, и «потери» формально
нет. Именно этот случай и есть смысл существования pdtv.

Считать «файлы на входе = файлы на выходе» нельзя: раскладка законно пакует
бланки в zip, распаковывает архивы (появляются новые файлы), а исходники
сохраняет рядом. Поэтому сверяем ХЕШИ содержимого, а не имена и не количество.

Запуск:
    pdtv-fuzz.py                  # 20 прогонов со случайными деревьями
    pdtv-fuzz.py -n 100           # больше прогонов
    pdtv-fuzz.py --seed 12345     # повторить конкретный прогон (репро падения)
    pdtv-fuzz.py --keep           # не удалять деревья упавших прогонов
    PDTV=/путь/pdtv.sh pdtv-fuzz.py   # проверить другую версию (в т.ч. pdtv.py)
"""
import argparse
import gzip
import hashlib
import os
import random
import shutil
import string
import subprocess
import sys
import tarfile
import tempfile
import zipfile

# Дефолт — <репа>/pdtv.sh (этот файл лежит в <репа>/scripts/); override через $PDTV.
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PDTV = os.environ.get("PDTV", os.path.join(_REPO, "pdtv.sh"))

# Доп-ключи прогона. Нужны для pdtv_local: там включена маршрутизация по
# управлениям, и архив с подходящим именем НАМЕРЕННО уезжает в каталог-приёмник
# целым, не потрошась. Это штатное поведение, а не потеря, поэтому проверять
# распаковку у него надо так:
#     PDTV=/root/repos/pdtv_local/pdtv.sh PDTV_ARGS=--no-routing pdtv-fuzz.py
EXTRA_ARGS = [a for a in os.environ.get("PDTV_ARGS", "").split() if a]

# Имена, на которых ломаются скрипты. Каждое — реальный класс бага:
# пробелы (word splitting), дефис в начале (парсится как ключ), кавычки и $()
# (подстановка в неэкранированной строке), перевод строки (разрыв построчной
# обработки), кириллица и юникод (локаль/кодировка zip), точки (обрезка
# расширения), длинное имя (лимит файловой системы), без расширения (детектор
# типа), звёздочка (глоб).
NASTY = [
    "простой.txt",
    "с пробелами.txt",
    "два  пробела   подряд.txt",
    "-начинается-с-дефиса.txt",
    "--выглядит-как-ключ.txt",
    "кириллица.txt",
    "СМЕШАННЫЙ Case Имя.TXT",
    "с'апострофом.txt",
    'с"кавычкой.txt',
    "с$(команда).txt",
    "с`бэктиком`.txt",
    "со;точкой;с;запятой.txt",
    "со*звёздочкой.txt",
    "со?знаком.txt",
    "точка.в.середине.txt",
    "без_расширения",
    "с.двойным.расширением.tar.gz.txt",
    "файл.с.пробелом.в.конце .txt",
    "émoji_🙂_имя.txt",
    "ＦＵＬＬＷＩＤＴＨ.txt",
    "a" * 200 + ".txt",
    "документ №5 (копия).txt",
    "смесь Mixed Кириллица 123.txt",
]

# Имя с переводом строки — отдельно: оно валидно в Linux и ломает всё, что
# читает вывод построчно. Включается ключом (по умолчанию да).
NEWLINE_NAME = "имя\nс переводом.txt"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def rand_content(rnd, tag):
    """Уникальное содержимое: по нему потом опознаём файл, как бы его ни звали."""
    body = "".join(rnd.choice(string.ascii_letters + "абвгдеёж ") for _ in range(rnd.randint(20, 200)))
    return ("%s|%s\n" % (tag, body)).encode("utf-8")


def build_tree(root, rnd, allow_newline):
    """Строит «Входящие» со случайным набором злых файлов и архивов.

    :returns: {sha256: описание} — что обязано уцелеть.
    """
    vhod = os.path.join(root, "Входящие")
    os.makedirs(vhod, exist_ok=True)
    expect = {}

    names = NASTY[:]
    if allow_newline:
        names.append(NEWLINE_NAME)
    rnd.shuffle(names)
    names = names[:rnd.randint(4, 12)]

    # 1. Файлы россыпью
    for nm in names:
        data = rand_content(rnd, "loose:" + nm.replace("\n", "\\n"))
        with open(os.path.join(vhod, nm), "wb") as f:
            f.write(data)
        expect[sha(data)] = "россыпью «%s»" % nm.replace("\n", "\\n")

    # 2. ZIP с злыми именами внутри
    if rnd.random() < 0.9:
        zname = rnd.choice(["Пакет.zip", "архив с пробелом.zip", "ZIP_КИРИЛЛИЦА.zip"])
        with zipfile.ZipFile(os.path.join(vhod, zname), "w") as z:
            for nm in rnd.sample(NASTY, rnd.randint(1, 4)):
                data = rand_content(rnd, "inzip:" + nm)
                z.writestr(nm, data)
                expect[sha(data)] = "внутри %s → «%s»" % (zname, nm)

    # 3. Архив в архиве — ВСЕГДА. Вложенность это главное место потери
    # документов, и оставлять её на «повезёт/не повезёт» нельзя: при вероятности
    # 0.7 половина прогонов не доходила до раскладки внутренностей подархивов,
    # и фаззер молчал на заведомо сломанном коде. Покрытие важнее разнообразия.
    if True:
        inner = os.path.join(root, "_inner.zip")
        with zipfile.ZipFile(inner, "w") as z:
            for nm in rnd.sample(NASTY, rnd.randint(1, 3)):
                data = rand_content(rnd, "deep:" + nm)
                z.writestr(nm, data)
                expect[sha(data)] = "во вложенном архиве → «%s»" % nm
        outer = os.path.join(vhod, "Внешний пакет.zip")
        with zipfile.ZipFile(outer, "w") as z:
            z.write(inner, "внутренний архив.zip")
        os.remove(inner)

    # 4. tar.gz
    if rnd.random() < 0.6:
        tpath = os.path.join(vhod, "Сводка.tar.gz")
        with tarfile.open(tpath, "w:gz") as t:
            for nm in rnd.sample(NASTY, rnd.randint(1, 3)):
                data = rand_content(rnd, "intar:" + nm)
                p = os.path.join(root, "_t")
                with open(p, "wb") as f:
                    f.write(data)
                t.add(p, arcname=nm)
                os.remove(p)
                expect[sha(data)] = "внутри Сводка.tar.gz → «%s»" % nm

    # 5. Одиночный .gz (путь _decompress: тот самый, где не было -f)
    if rnd.random() < 0.5:
        data = rand_content(rnd, "gz")
        gpath = os.path.join(vhod, "отчёт о работе.txt.gz")
        with gzip.open(gpath, "wb") as g:
            g.write(data)
        expect[sha(data)] = "внутри отчёт о работе.txt.gz"
        # Провоцируем конфликт имён: рядом кладём файл, в который .gz распакуется
        if rnd.random() < 0.5:
            clash = rand_content(rnd, "clash")
            with open(os.path.join(vhod, "отчёт о работе.txt"), "wb") as f:
                f.write(clash)
            expect[sha(clash)] = "конфликт имён с .gz: «отчёт о работе.txt»"

    # 6. Битый архив — не должен ронять прогон и не должен исчезать
    if rnd.random() < 0.4:
        broken = os.path.join(vhod, "битый.zip")
        data = b"PK\x03\x04\x00\x00 not a real zip " + os.urandom(40)
        with open(broken, "wb") as f:
            f.write(data)
        expect[sha(data)] = "битый архив «битый.zip»"

    return expect


def collect_hashes(root, depth=0):
    """Возвращает (достижимо_вообще, лежит_россыпью).

    ДВА инварианта, потому что «не потеряно» и «оператор это увидит» — разные вещи:

    * достижимо вообще — содержимое есть хоть где-то, пусть и внутри архива.
      Нарушение = безвозвратная потеря документа. Это КРИТ.
    * лежит россыпью — документ доступен отдельным файлом, без раскапывания
      архивов вручную. Ради этого pdtv и существует. Нарушение = документ
      формально цел, но оператор его не получил, а значит и не обработает.

    Первый инвариант мягче и пропускает целый класс: внутренности подархивов
    могут не разложиться, а сам архив уцелеет — содержимое «есть», работы нет.
    """
    found = set()
    loose = set()
    if depth > 4:
        return found, loose
    for dirpath, _dirs, files in os.walk(root):
        for nm in files:
            p = os.path.join(dirpath, nm)
            try:
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            found.add(sha(data))
            loose.add(sha(data))
            found |= _peek_archive(p, data, depth)
    return found, loose


def _peek_archive(path, data, depth):
    """Заглядывает внутрь архива, не распаковывая его на диск целиком."""
    found = set()
    low = path.lower()
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as z:
                for info in z.infolist():
                    if info.is_dir():
                        continue
                    inner = z.read(info)
                    found.add(sha(inner))
                    if depth < 4 and inner[:4] in (b"PK\x03\x04",):
                        with tempfile.NamedTemporaryFile(delete=False) as tf:
                            tf.write(inner)
                            tmp = tf.name
                        try:
                            found |= _peek_archive(tmp, inner, depth + 1)
                        finally:
                            os.unlink(tmp)
        elif tarfile.is_tarfile(path):
            with tarfile.open(path) as t:
                for m in t.getmembers():
                    if not m.isfile():
                        continue
                    fh = t.extractfile(m)
                    if fh:
                        found.add(sha(fh.read()))
        elif low.endswith(".gz"):
            with gzip.open(path, "rb") as g:
                found.add(sha(g.read()))
    except Exception:  # noqa: BLE001 — битый архив это нормальный вход фаззера
        pass
    return found


def run_once(seed, keep, allow_newline):
    rnd = random.Random(seed)
    root = tempfile.mkdtemp(prefix="pdtvfuzz_")
    try:
        expect = build_tree(root, rnd, allow_newline)
        env = dict(os.environ)
        env.pop("DISPLAY", None)
        proc = subprocess.run(
            ["bash", PDTV, "--root", root, "--officer", "Фаззер Ф.Ф.",
             "--no-color", "--no-pause", "--no-gui", "--no-open", "--no-chmod"]
            + EXTRA_ARGS,
            capture_output=True, text=True, errors="replace", env=env, timeout=180)
        found, loose = collect_hashes(root)
        lost = {h: d for h, d in expect.items() if h not in found}
        # «Не разложен» ищем только среди тех, кто пришёл ВНУТРИ архива:
        # у файлов, лежавших россыпью изначально, вопрос не стоит.
        buried = {h: d for h, d in expect.items()
                  if h in found and h not in loose}
        crashed = proc.returncode != 0
        if lost or buried or crashed:
            print("\n### ПАДЕНИЕ, seed=%d ###" % seed)
            if crashed:
                print("  код возврата: %d" % proc.returncode)
                tail = (proc.stdout or "")[-800:] + (proc.stderr or "")[-800:]
                print("  хвост вывода:\n%s" % tail)
            for d in sorted(lost.values()):
                print("  ПОТЕРЯН СОВСЕМ: %s" % d)
            for d in sorted(buried.values()):
                print("  НЕ РАЗЛОЖЕН (остался только внутри архива): %s" % d)
            if keep:
                print("  дерево оставлено: %s" % root)
                return False, None
        return (not lost and not buried and not crashed), root
    finally:
        if not keep:
            shutil.rmtree(root, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description="Фаззер раскладки pdtv")
    ap.add_argument("-n", "--runs", type=int, default=20, help="число прогонов")
    ap.add_argument("--seed", type=int, help="конкретный seed (повтор падения)")
    ap.add_argument("--keep", action="store_true", help="не удалять деревья падений")
    ap.add_argument("--no-newline-names", action="store_true",
                    help="без имён с переводом строки")
    args = ap.parse_args()

    if not os.path.exists(PDTV):
        print("не найден: %s (задайте PDTV=...)" % PDTV)
        return 2

    seeds = [args.seed] if args.seed is not None else \
        [random.randrange(1, 10 ** 9) for _ in range(args.runs)]
    ok = bad = 0
    for s in seeds:
        good, _ = run_once(s, args.keep, not args.no_newline_names)
        if good:
            ok += 1
            sys.stdout.write(".")
        else:
            bad += 1
            sys.stdout.write("F")
        sys.stdout.flush()
    print("\n\nИТОГ: прогонов=%d, чисто=%d, с потерями/падениями=%d"
          % (len(seeds), ok, bad))
    if bad:
        print("Повторить падение: pdtv-fuzz.py --seed <номер> --keep")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
