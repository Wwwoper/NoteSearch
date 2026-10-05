#!/usr/bin/env python3
import shutil
import sys
from pathlib import Path

ROOT = Path.home() / "Documents" / "Notes" / "_NS_TEST"


def write(rel: str, text: str) -> None:
    path = ROOT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main() -> int:
    if ROOT.exists():
        shutil.rmtree(ROOT)
    ROOT.mkdir(parents=True, exist_ok=True)

    fence = "`" * 3

    write(
        "Настройка сервера.md",
        "# Домашний сервер\n\n"
        "Настройка docker compose для домашнего сервера. nsaccept\n\n"
        "## Шаги\n\n"
        "- установить Docker\n"
        "- запустить `docker compose up`\n"
        "1. первый пункт\n\n"
        "> цитата про сервер\n\n"
        f"{fence}bash\ndocker compose up -d\n{fence}\n",
    )
    write("Заметка (копия) №1.md", "Первая строка\nДОМАШНИЙ СЕРВЕР в верхнем регистре. nsaccept\n")
    write("only-docker.md", "docker only nsaccept\n")
    write("only-compose.txt", "compose only nsaccept\n")
    write("UPPER.MD", "расширение в верхнем регистре nsaccept\n")
    write("01-uv-proekt.md", "uv-proekt-i-docker nsaccept\n")
    write("Учёба/Конспекты (2026)/Лекция №2.md", "лекция nsaccept\n")
    write("Учёба/Изображения к текстам/skip.md", "nsaccept в пользовательском исключении\n")
    write("node_modules/pkg/index.js", "nsaccept node_modules\n")
    write("Images/note.md", "nsaccept Images\n")
    write(".git/config.txt", "nsaccept git\n")

    (ROOT / "pic.png").write_bytes(b"\x89PNG nsaccept")
    (ROOT / "broken.md").write_bytes(b"\xff\xfe\xfa\n")

    before = ["a"] * 500
    before[321] = "S"
    tail = [" "] + ["b"] * 600
    tail[299] = "E"
    write("long.md", "".join(before) + " nsaccept" + "".join(tail) + "\n")

    write("many.md", "".join("nsaccept " + "x" * 1000 + "\n" for _ in range(8)))

    files = sorted(p for p in ROOT.rglob("*") if p.is_file())
    print(f"Создана папка: {ROOT}")
    print(f"Файлов: {len(files)}")
    for p in files:
        print("  ", p.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
