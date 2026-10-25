#!/usr/bin/env python3
"""Genera el panel de diseno de Aventura de Estrellas: un HTML interactivo con
graficas y tablas para decidir que cambiar en el juego.

Lee la base que crea el juego (user://aventura.db) solo en modo lectura y los
datos de cada nivel (nombre, tiempo de oro, plataformas) de
scripts/level_data.gd. Todo queda dentro del HTML: se abre sin servidor y sin
internet.

    python3 tools/dashboard.py                 # escribe tools/dashboard.html
    python3 tools/dashboard.py --abrir         # y lo abre en el navegador
    python3 tools/dashboard.py --db RUTA --salida panel.html

La version web del juego guarda los records en el navegador de cada jugador:
esos datos no llegan a esta base.
"""
import argparse
import json
import re
import sqlite3
import sys
import webbrowser
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from leaderboard import default_db_path  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LEVEL_DATA = ROOT / "scripts" / "level_data.gd"
TEMPLATE = Path(__file__).resolve().parent / "dashboard_template.html"
DEFAULT_OUT = Path(__file__).resolve().parent / "dashboard.html"

NUM = r"(-?\d+(?:\.\d+)?)"
BLOCK_RE = re.compile(r'\["[a-z_]+_(\d+)x(\d+)x(\d+)",\s*"[^"]*",\s*' + NUM + r",\s*" + NUM + r",\s*" + NUM)


def read_levels():
    """Nombre, tiempo de oro, modo y planta (x, z, ancho, fondo) de cada nivel,
    en el orden de LevelData.levels()."""
    src = LEVEL_DATA.read_text(encoding="utf-8")
    order = re.search(r"static func levels\(\) -> Array:\s*return \[([^\]]*)\]", src)
    names = re.findall(r"(_\w+)\(\)", order.group(1)) if order else []
    levels = []
    for i, fn in enumerate(names):
        start = src.find(f"static func {fn}() -> Dictionary:")
        end = src.find("\nstatic func ", start + 1)
        body = src[start:end if end > 0 else len(src)]

        def field(key, cast=str, default=None):
            m = re.search(rf'"{key}":\s*("([^"]*)"|{NUM})', body)
            if not m:
                return default
            return cast(m.group(2) if m.group(2) is not None else m.group(3))

        blocks = [[float(x), float(z), float(w), float(d)] for w, d, _h, x, _y, z in BLOCK_RE.findall(body)]
        levels.append({
            "n": i + 1,
            "name": field("name", str, f"Nivel {i + 1}"),
            "par_ms": int(field("par_time", float, 0) * 1000),
            "time_limit": field("time_limit", float, 0),
            "trial": field("mode", str, "") == "contrarreloj",
            "blocks": blocks,
        })
    return levels


def columns(con, table):
    return {r[1] for r in con.execute(f"PRAGMA table_info({table})")}


def rows(con, sql):
    cur = con.execute(sql)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def read_db(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        cols = columns(con, "intentos")
        extra = ", ".join(c if c in cols else f"NULL AS {c}" for c in ["sesion_id", "par_ms", "checkpoints", "fin_x", "fin_z"])
        attempts = rows(con, f"""SELECT id, jugador_id, nivel, numero, resultado, tiempo_ms, estrellas,
            estrellas_total, gema, corazones, poderes, caidas, medalla, fecha, {extra}
            FROM intentos ORDER BY id""")
        players = rows(con, "SELECT id, nickname, creado FROM jugadores")
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        deaths = rows(con, "SELECT intento_id, nivel, causa, x, y, z, tiempo_ms FROM muertes") if "muertes" in tables else []
        sessions = rows(con, "SELECT id, jugador_id, inicio, fin FROM sesiones") if "sesiones" in tables else []
    finally:
        con.close()
    return {"attempts": attempts, "players": players, "deaths": deaths, "sessions": sessions}


def main():
    parser = argparse.ArgumentParser(description="Panel de diseno de Aventura de Estrellas")
    parser.add_argument("--db", type=Path, default=None, help="ruta de aventura.db")
    parser.add_argument("--salida", type=Path, default=DEFAULT_OUT, help="HTML a escribir")
    parser.add_argument("--abrir", action="store_true", help="abrir el panel en el navegador")
    args = parser.parse_args()

    db = args.db or default_db_path()
    if not db.exists():
        sys.exit(f"No se encontro la base de datos en {db}\nJuega una partida primero o usa --db RUTA.")
    data = read_db(db)
    data["levels"] = read_levels()
    data["generated"] = datetime.now().strftime("%Y-%m-%d %H:%M")
    data["db_path"] = str(db)

    # "</" dentro de un <script> lo cerraria: se escapa.
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    html = TEMPLATE.read_text(encoding="utf-8").replace("/*__DATOS__*/null", payload)
    args.salida.write_text(html, encoding="utf-8")
    print(f"Panel escrito en {args.salida}  ({len(data['attempts'])} intentos, {len(data['players'])} jugadores)")
    if args.abrir:
        webbrowser.open(args.salida.resolve().as_uri())


if __name__ == "__main__":
    main()
