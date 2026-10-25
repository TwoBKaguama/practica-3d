# Aventura de Estrellas

Enlace a video 

https://drive.google.com/file/d/1TSrO3tuekLuTwFrSHfs7BSmJoPaPYXUE/view?usp=drive_link


Plataformas 3D hecho con Godot 4.7 (renderer Compatibility). Corre por islas
sobre el mar, recoge estrellas, busca la gema secreta de cada nivel y no te
caigas al agua.

## Modos

- **Aventura (niveles 1-3):** Prado Verde, Canon Azul y Torre Roja. Tres vidas
  (hasta cinco con corazones), una gema secreta por nivel, Super salto y
  resortes en las rutas secundarias.
- **Contrarreloj (niveles 4-5):** Marea Alta y Tormenta. Hay "3, 2, 1, ¡YA!" y
  una cuenta atrás; mientras corre, la marea sube y al llegar a 0 se traga al
  jugador.
  - Los aros verdes dan +3 s y los checkpoints también suman tiempo. Cada caída
    resta 3 s.
  - Las flechas dan Turbo para cruzar los "saltos turbo" y los bloques rojos se
    rompen al pisarlos.
  - Con menos de 10 s suena el tic-tac, la música se acelera y los bordes de la
    pantalla laten en rojo.

Controles: WASD para moverse, Espacio para saltar, ratón para la cámara, P o
Esc para pausar y R para reiniciar.

## Records (SQLite)

Al empezar se pide un nickname. Cada intento queda guardado en
`user://aventura.db` mediante la extensión
[godot-sqlite](https://github.com/2shady4u/godot-sqlite) (`addons/godot-sqlite`).
Se registra el tiempo, el número de intento, las estrellas, la gema, los
corazones, las caídas, la medalla y el resultado.

- **En el juego:** la pantalla de inicio muestra el top 5 y "Ver tabla
  completa" abre las pestañas por nivel, General y Mi historial.
- **Fuera del juego:** `python3 tools/leaderboard.py --help`. Solo lee la base.

Ruta de la base: en Linux `~/.local/share/godot/app_userdata/IA/aventura.db`, en
Windows `%APPDATA%\Godot\app_userdata\IA\aventura.db`. En la versión web se
guarda en el almacenamiento del navegador (IndexedDB) de cada jugador.


## Ventana

La ventana se abre a 1080x920, se puede redimensionar y se adapta a cualquier
proporción:

- La interfaz se diseña sobre 1152x864 y se escala sin deformarse (stretch
  `canvas_items` + `expand`).
- En ventanas altas o estrechas la cámara abre su campo de visión horizontal
  para no dar sensación de zoom.
