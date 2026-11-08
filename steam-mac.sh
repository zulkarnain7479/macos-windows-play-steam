#!/bin/bash
# steam-mac.sh — Windows-игры из Steam на Mac с чипом Apple (M1 и новее) через Highball.
#
#   bash steam-mac.sh install        ставит всё нужное и показывает план установки с прогрессом
#   bash steam-mac.sh watch [appid]  показывает тот же план с прогрессом и ничего не меняет
#   bash steam-mac.sh play [appid]   запускает игру; без appid — Machine Party (4108000)
#
# Подробно — README.md.
#
# Почему Highball (github.com/gauthierpiarrette/highball): бесплатный, с открытым кодом (GPL-3.0),
# сам ставит Steam для Windows и подбирает графику под игру, работает на M1+ с macOS 14+.
# Почему в репозитории нет самих программ: Highball, движок Wine и Steam скачиваются при установке
# с официальных мест. Так они всегда свежие, а мы ничего не распространяем сами (D3DMetal от Apple
# распространять нельзя вовсе, игры — тем более).

set -euo pipefail
# Длина русских строк нужна в символах, а не в байтах, иначе колонки плана съезжают.
export LC_CTYPE=en_US.UTF-8

GAME_APPID_DEFAULT=4108000
GAME_NAME_DEFAULT="Machine Party"
HB_REPO="gauthierpiarrette/highball"
HB_BUNDLE_ID="app.highball.Highball"
# Подпись разработчика Highball: «Developer ID Application: Gauthier PIARRETTE (B95M7DARU4)».
# Чужая подпись в скачанном образе = подмена, установка останавливается.
HB_TEAM_ID="B95M7DARU4"
MAC_STEAM_ID="com.valvesoftware.steam"
MIN_MACOS=14
MIN_FREE_GB=8
STEAM_DIR_IN_ENV="drive_c/Program Files (x86)/Steam"

GAME_APPID=$GAME_APPID_DEFAULT
GAME_NAME=$GAME_NAME_DEFAULT
HB_APP=""
HB_HOME=""
TOKEN=""
TMP=""
ENGINE_KB=0

# Что установщик уже сделал сам (режим install).
SENT_STEAM_AT=0   # когда попросили Highball поставить Steam
ENV_READY_AT=0    # когда заметили готовую среду Windows
STEAM_SEEN_AT=0   # когда появился steam.exe
LAUNCHED=0        # открывали ли Steam
BOOT_BEFORE=0     # сколько строк было в журнале обновления Steam до нашего запуска
RESTARTS=0        # сколько раз перезапускали Steam после известных сбоев
DOWN=0            # сколько секунд подряд Steam не запущен

# --- экран: план установки --------------------------------------------------------------------
# В Терминале план рисуется на одном месте и обновляется 5 раз в секунду: ✓ готово, крутилка —
# идёт сейчас, ○ впереди, у текущего этапа полоса с процентами. Если вывод идёт не в Терминал,
# а в файл, вместо плана печатаются обычные строки при смене этапа.

if [ -t 1 ]; then TTY=1; else TTY=0; fi
if [ "$TTY" = 1 ]; then
  C_OK=$'\033[32m'; C_RUN=$'\033[33m'; C_DIM=$'\033[2m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=""; C_RUN=""; C_DIM=""; C_ERR=""; C_B=""; C_0=""
fi
SPIN=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
STAGES=("Проверка Mac" "Rosetta 2" "Highball" "Движок Wine" "Среда Windows" "Steam для Windows"
  "Обновление Steam" "Вход в Steam" "$GAME_NAME_DEFAULT")
ST=(wait wait wait wait wait wait wait wait wait)   # done | run | wait | fail
DT=("" "" "" "" "" "" "" "" "")                     # подпись справа
PC=("" "" "" "" "" "" "" "" "")                     # процент, если его можно посчитать
HINT=""        # что делать сейчас; несколько строк — через перевод строки
FOOT=""        # можно ли закрыть окно
DASH=0         # план на экране
FRAME=0
LAST_PLAIN=""
LAST_PLAIN_HINT=""

info() { printf '  %s\n' "$*"; }
warn() { printf '%s  %s%s\n' "$C_RUN" "$*" "$C_0"; }

set_stage() { ST[$1]=$2; DT[$1]=${3:-}; PC[$1]=${4:-}; }   # set_stage <номер с 0> <статус> [подпись] [процент]

rest_wait() {  # все этапы после <номер> — ещё впереди
  local i
  for ((i = $1 + 1; i < ${#STAGES[@]}; i++)); do set_stage "$i" wait; done
}

pad() {  # pad <строка> <ширина>
  local n=$(( $2 - ${#1} ))
  if [ "$n" -lt 0 ]; then n=0; fi
  printf '%s%*s' "$1" "$n" ""
}

bar() {  # bar <процент> — полоса из 20 клеток
  local f=$(( $1 * 20 / 100 )) i out=""
  for ((i = 0; i < 20; i++)); do
    if [ "$i" -lt "$f" ]; then out+="█"; else out+="░"; fi
  done
  printf '%s' "$out"
}

plan_position() {  # номер текущего этапа с 1 (0 — всё готово) и сколько этапов осталось
  local i cur=0 left=0
  for ((i = 0; i < ${#STAGES[@]}; i++)); do
    if [ "${ST[i]}" != done ]; then
      left=$((left + 1))
      if [ "$cur" -eq 0 ]; then cur=$((i + 1)); fi
    fi
  done
  echo "$cur $left"
}

draw() {
  local pos cur left n=${#STAGES[@]} i icon text l buf
  local -a lines
  pos=$(plan_position); cur=${pos% *}; left=${pos#* }
  if [ "$TTY" = 0 ]; then draw_plain "$cur"; return 0; fi
  if [ "$left" -eq 0 ]; then
    lines=("" "  ${C_B}${C_OK}Готово: все $n этапов пройдены${C_0}" "")
  else
    lines=("" "  ${C_B}$GAME_NAME на Mac${C_0}   этап $cur из $n, осталось $left" "")
  fi
  for ((i = 0; i < n; i++)); do
    case "${ST[i]}" in
      done) icon="${C_OK}✓${C_0}" ;;
      run) icon="${C_RUN}${SPIN[FRAME % 10]}${C_0}" ;;
      fail) icon="${C_ERR}✗${C_0}" ;;
      *) icon="${C_DIM}○${C_0}" ;;
    esac
    text=$(pad "${STAGES[i]}" 19)
    if [ "${ST[i]}" = wait ]; then text="${C_DIM}${text}${C_0}"; fi
    if [ "${ST[i]}" = run ] && [ -n "${PC[i]}" ]; then
      text+="${C_RUN}$(bar "${PC[i]}")${C_0} $(printf '%3d%%' "${PC[i]}")  ${DT[i]}"
    elif [ -n "${DT[i]}" ]; then
      text+="${C_DIM}${DT[i]}${C_0}"
    fi
    lines+=("  $icon $text")
  done
  if [ -n "$HINT" ]; then
    lines+=("")
    while IFS= read -r l; do lines+=("  $l"); done <<< "$HINT"
  fi
  if [ -n "$FOOT" ]; then lines+=("" "  ${C_DIM}${FOOT}${C_0}"); fi
  lines+=("")
  buf=$'\033[H'
  for l in "${lines[@]}"; do buf+=$'\033[K'"$l"$'\n'; done
  buf+=$'\033[J'
  printf '%s' "$buf"
}

draw_plain() {  # draw_plain <текущий этап> — строка при смене этапа и на каждых 10% прогресса
  local cur=$1 i sig line
  if [ "$cur" -eq 0 ]; then
    sig=done
    line="Готово: все ${#STAGES[@]} этапов пройдены."
  else
    i=$((cur - 1))
    sig="$cur ${ST[i]} $(( ${PC[i]:-0} / 10 ))"
    line="[$cur/${#STAGES[@]}] ${STAGES[i]}"
    if [ -n "${PC[i]}" ]; then line+=": ${PC[i]}%"; fi
    if [ -n "${DT[i]}" ]; then line+=", ${DT[i]}"; fi
  fi
  if [ "$sig" != "$LAST_PLAIN" ]; then
    printf '%s  %s\n' "$(date +%H:%M)" "$line"
    LAST_PLAIN=$sig
  fi
  if [ -n "$HINT" ] && [ "$HINT" != "$LAST_PLAIN_HINT" ]; then
    printf '%s\n' "$HINT" | sed 's/^/       /'
    LAST_PLAIN_HINT=$HINT
  fi
}

dash_start() {
  DASH=1
  # Чистим окно и прячем курсор: план всегда рисуется от верхнего края, перенос строк ему не мешает.
  # Без Терминала первую строку не печатаем: этапы ещё не проверены.
  if [ "$TTY" = 1 ]; then
    printf "\033[?25l\033[2J\033[H"
    draw
  fi
}

dash_end() {
  if [ "$DASH" = 1 ] && [ "$TTY" = 1 ]; then printf '\033[?25h'; fi
  DASH=0
}

die() {
  local i
  if [ "$DASH" = 1 ]; then
    for ((i = 0; i < ${#STAGES[@]}; i++)); do
      if [ "${ST[i]}" = run ]; then ST[i]=fail; break; fi
    done
    HINT="${C_ERR}Ошибка: $*${C_0}"
    FOOT=""
    draw
  else
    printf '\n%sОшибка: %s%s\n' "$C_ERR" "$*" "$C_0" >&2
  fi
  exit 1
}

cleanup() {
  dash_end
  [ -n "$TMP" ] || return 0
  if [ -d "$TMP/mnt" ]; then
    hdiutil detach "$TMP/mnt" -quiet 2>/dev/null || hdiutil detach "$TMP/mnt" -force -quiet 2>/dev/null || true
  fi
  # Образ так и не отключился — не трогаем папку, чтобы не задеть его содержимое.
  if ! mount | grep -qF "$TMP/mnt"; then rm -rf "$TMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# animate_pid <pid> <этап> [файл] [ожидаемый размер, байт] — рисует план, пока процесс работает.
animate_pid() {
  local pid=$1 i=$2 file=${3:-} total=${4:-0} got
  while kill -0 "$pid" 2>/dev/null; do
    if [ -n "$file" ] && [ "$total" -gt 0 ]; then
      got=$(stat -f %z "$file" 2>/dev/null || echo 0)
      PC[$i]=$(( got * 100 / total ))
      if [ "${PC[$i]}" -gt 99 ]; then PC[$i]=99; fi
      DT[$i]="$(( got / 1048576 )) из $(( total / 1048576 )) МБ"
    fi
    draw
    FRAME=$((FRAME + 1))
    sleep 0.2
  done
  wait "$pid"
}

usage() {
  cat <<EOF
Windows-игры из Steam на Mac с чипом Apple.

  bash steam-mac.sh install        установить всё нужное (по умолчанию)
  bash steam-mac.sh watch [appid]  показать план установки с прогрессом, ничего не меняя
  bash steam-mac.sh play [appid]   запустить игру (без appid — $GAME_NAME_DEFAULT, $GAME_APPID_DEFAULT)
EOF
}

# --- этапы 1–3: Mac, Rosetta, Highball --------------------------------------------------------

stage_check_mac() {
  local ver major free_kb free_gb
  set_stage 0 run
  draw
  [ "$(id -u)" -ne 0 ] || die "Не запускайте установку через sudo: Highball работает от имени пользователя."
  # hw.optional.arm64 = 1 и под Rosetta, поэтому не uname -m.
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] \
    || die "Нужен Mac с чипом Apple M1 или новее. На Mac с процессором Intel Highball не работает."
  ver=$(sw_vers -productVersion)
  major=${ver%%.*}
  [ "$major" -ge "$MIN_MACOS" ] || die "Нужна macOS $MIN_MACOS (Sonoma) или новее, у вас $ver."
  free_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
  free_gb=$(( free_kb / 1024 / 1024 ))
  if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
    set_stage 0 done "macOS $ver, свободно ${free_gb} ГБ из нужных $MIN_FREE_GB"
  else
    set_stage 0 done "macOS $ver, свободно ${free_gb} ГБ"
  fi
}

stage_rosetta() {
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    set_stage 1 done "уже установлена"
    return 0
  fi
  set_stage 1 run "ставится"
  HINT="Ставлю Rosetta 2 от Apple: через неё работает движок Wine."
  softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 &
  animate_pid $! 1 || die "Rosetta не установилась. Выполните в Терминале: softwareupdate --install-rosetta --agree-to-license"
  arch -x86_64 /usr/bin/true 2>/dev/null \
    || die "Rosetta установлена, но не запускается. Перезагрузите Mac и запустите установку снова."
  set_stage 1 done "установлена"
  HINT=""
}

hb_app_path() {
  local p
  for p in "/Applications/Highball.app" "$HOME/Applications/Highball.app"; do
    if [ -d "$p" ]; then echo "$p"; return 0; fi
  done
  return 1
}

app_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo 0
}

# version_lt A B — истина, если версия A старше (меньше) B. Сравнение по числам: 0.10.9 < 0.10.26.
version_lt() {
  local IFS=.
  local -a a=($1) b=($2)
  local i x y
  for i in 0 1 2 3; do
    x=${a[i]:-0}; y=${b[i]:-0}
    x=${x//[!0-9]/}; y=${y//[!0-9]/}
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    if [ "$x" -lt "$y" ]; then return 0; fi
    if [ "$x" -gt "$y" ]; then return 1; fi
  done
  return 1
}

# Номер последнего выпуска — из адреса, куда GitHub перенаправляет /releases/latest.
# Без API GitHub: у него лимит 60 запросов в час на адрес.
hb_latest_version() {
  local url
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$HB_REPO/releases/latest" 2>/dev/null) || return 1
  case "$url" in
    */tag/v*) echo "${url##*/tag/v}" ;;
    *) return 1 ;;
  esac
}

verify_app() {
  local app=$1 sig
  codesign --verify --deep --strict "$app" 2>/dev/null \
    || die "Подпись Highball не сходится. Установка остановлена."
  sig=$(codesign -dv "$app" 2>&1 || true)
  case "$sig" in
    *"TeamIdentifier=$HB_TEAM_ID"*) ;;
    *) die "Highball подписан не тем разработчиком. Установка остановлена." ;;
  esac
  spctl --assess --type execute "$app" 2>/dev/null \
    || die "Apple не подтвердила Highball (нотаризация). Установка остановлена."
}

quit_app() {  # quit_app <bundle id> <имя процесса> — просит программу закрыться и ждёт до 30 секунд
  pgrep -x "$2" >/dev/null || return 0
  osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    pgrep -x "$2" >/dev/null || return 0
    sleep 1
  done
  return 1
}

stage_highball() {
  local app cur latest url total out dest_dir
  set_stage 2 run "проверяю версию"
  draw
  app=$(hb_app_path || true)
  cur=0
  if [ -n "$app" ]; then cur=$(app_version "$app"); fi
  latest=$(hb_latest_version || true)
  if [ -z "$latest" ]; then
    [ -n "$app" ] || die "Не удалось узнать последнюю версию Highball на GitHub. Проверьте интернет и запустите снова."
    HB_APP=$app
    set_stage 2 done "$cur, GitHub не ответил"
    return 0
  fi
  if [ -n "$app" ] && ! version_lt "$cur" "$latest"; then
    HB_APP=$app
    set_stage 2 done "$cur, последняя версия"
    return 0
  fi

  url="https://github.com/$HB_REPO/releases/download/v$latest/Highball.dmg"
  TMP=$(mktemp -d -t steam-mac)
  total=$(curl -fsSLI "$url" 2>/dev/null | awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }' || true)
  set_stage 2 run "" 0
  HINT="Скачиваю Highball $latest с его страницы на GitHub."
  curl -fsSL --retry 3 -o "$TMP/Highball.dmg" "$url" 2>/dev/null &
  animate_pid $! 2 "$TMP/Highball.dmg" "${total:-0}" || die "Не скачался Highball."

  set_stage 2 run "проверяю подпись"
  HINT="Проверяю подпись разработчика и проверку Apple."
  draw
  mkdir "$TMP/mnt"
  # macOS 27 пишет, что hdiutil attach устарел, но команда работает и есть во всех macOS 14+.
  out=$(hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$TMP/mnt" "$TMP/Highball.dmg" 2>&1) \
    || die "Не открылся образ Highball.dmg: $out"
  [ -d "$TMP/mnt/Highball.app" ] || die "В образе нет Highball.app."
  verify_app "$TMP/mnt/Highball.app"

  if [ -n "$app" ]; then
    dest_dir=$(dirname "$app")
  elif [ -w /Applications ]; then
    dest_dir=/Applications
  else
    dest_dir="$HOME/Applications"
    mkdir -p "$dest_dir"
  fi
  set_stage 2 run "устанавливаю"
  draw
  quit_app "$HB_BUNDLE_ID" Highball || die "Highball не закрылся. Закройте его сами и запустите установку снова."
  ditto "$TMP/mnt/Highball.app" "$dest_dir/.Highball.app.new" || die "Не удалось скопировать Highball в $dest_dir."
  if [ -d "$dest_dir/Highball.app" ]; then mv "$dest_dir/Highball.app" "$TMP/Highball.old.app"; fi
  mv "$dest_dir/.Highball.app.new" "$dest_dir/Highball.app"
  HB_APP="$dest_dir/Highball.app"
  set_stage 2 done "$latest, подпись проверена"
  HINT=""
}

# Папка данных Highball. Пользователь мог перенести её (config.json → "home").
hb_home() {
  local def="$HOME/Library/Application Support/Highball" custom=""
  if [ -f "$def/config.json" ]; then
    custom=$(plutil -extract home raw -o - "$def/config.json" 2>/dev/null || true)
  fi
  if [ -n "$custom" ] && [ -d "$custom" ]; then echo "$custom"; else echo "$def"; fi
}

# Ссылки highball:// с этим ключом Highball выполняет без вопросов (так работают его же ярлыки).
# Ключа ещё нет — создаём: Highball возьмёт его из того же файла.
hb_token() {
  local f="$HB_HOME/launch-token" t=""
  if [ -f "$f" ]; then t=$(tr -d '[:space:]' < "$f"); fi
  if [ -z "$t" ]; then
    mkdir -p "$HB_HOME"
    t=$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')
    (umask 077; printf '%s' "$t" > "$f")
  fi
  echo "$t"
}

open_link() { open -a "$HB_APP" "$1"; }

# Сколько Highball качает для движка: сумма размеров из раздела components его же списка
# engine-manifest.json. Во всём файле есть и другие «size», с ними выходило 497 МБ вместо 282.
engine_total_kb() {
  local m="$HB_APP/Contents/Resources/engine-manifest.json" kb
  kb=$(plutil -extract components json -o - "$m" 2>/dev/null | grep -oE '"size"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+$' | awk '{ s += $1 } END { print int(s / 1024) }' || true)
  if [ "${kb:-0}" -gt 1024 ] 2>/dev/null; then echo "$kb"; else echo 280000; fi
}

dir_kb() { local k; k=$(du -sk "$1" 2>/dev/null | awk '{print $1}' || true); echo "${k:-0}"; }

# --- что видно в Highball и Steam -------------------------------------------------------------

# Скачанный движок — папка в engines/. Недокачанный лежит там же, но с точкой в начале имени.
engine_installed() {
  local d
  for d in "$HB_HOME"/engines/*/; do
    if [ -d "$d" ]; then return 0; fi
  done
  return 1
}

# Готовая среда: после первого запуска Wine в ней есть system.reg. Highball по умолчанию берёт «Games».
ready_env() {
  local d
  if [ -f "$HB_HOME/bottles/Games/system.reg" ]; then echo "$HB_HOME/bottles/Games"; return 0; fi
  for d in "$HB_HOME"/bottles/*/; do
    if [ -f "${d}system.reg" ]; then echo "${d%/}"; return 0; fi
  done
  return 1
}

steam_env() {
  local d
  for d in "$HB_HOME"/bottles/*/; do
    if [ -s "${d}$STEAM_DIR_IN_ENV/steam.exe" ]; then echo "${d%/}"; return 0; fi
  done
  return 1
}

steam_running() { pgrep -fi 'steam[.]exe' >/dev/null; }
webhelper_running() { pgrep -fi 'steamwebhelper[.]exe' >/dev/null; }

# Значение ключа из файла Steam вида  "StateFlags"  "4".
acf_value() { awk -F'"' -v k="$2" '$2 == k { print $4; exit }' "$1" 2>/dev/null; }

# Обновление самого Steam: пусто, offline или «<процент> <КБ скачано> <КБ всего>».
steam_update_info() {
  local log="$1/$STEAM_DIR_IN_ENV/logs/bootstrap_log.txt" last nums got total
  if [ ! -f "$log" ]; then return 0; fi
  last=$(tail -n 1 "$log" || true)
  case "$last" in
    *"needs to be online"*) echo offline ;;
    *"Downloading update ("*)
      nums=$(printf '%s' "$last" | sed -E 's/.*\(([0-9,]+) of ([0-9,]+) KB\).*/\1 \2/' | tr -d ',' || true)
      got=${nums% *}; total=${nums#* }
      if [ "$total" -gt 0 ] 2>/dev/null && [ "$got" -ge 0 ] 2>/dev/null; then
        echo "$((got * 100 / total)) $got $total"
      fi ;;
  esac
  return 0
}

# Игра в Steam для Windows: none, installed или «<процент> <МБ скачано> <МБ всего>».
game_info() {
  local acf="$1/$STEAM_DIR_IN_ENV/steamapps/appmanifest_$2.acf" got total
  if [ ! -f "$acf" ]; then echo none; return 0; fi
  if [ "$(acf_value "$acf" StateFlags)" = 4 ]; then echo installed; return 0; fi
  got=$(acf_value "$acf" BytesDownloaded); total=$(acf_value "$acf" BytesToDownload)
  got=${got:-0}; total=${total:-0}
  if [ "$total" -gt 0 ] 2>/dev/null && [ "$got" -ge 0 ] 2>/dev/null; then
    echo "$((got * 100 / total)) $((got / 1048576)) $((total / 1048576))"
  else
    echo "0 0 0"
  fi
}

game_installed() {  # game_installed <appid>
  ls "$HB_HOME"/bottles/*/"$STEAM_DIR_IN_ENV"/steamapps/appmanifest_"$1".acf >/dev/null 2>&1
}

# --- что установщик делает сам после этапа 3 --------------------------------------------------

act_install_steam() {  # act_install_steam <сейчас>
  local now=$1
  # Wine дописывает реестр и закрывается, Highball доделывает настройку — даём им закончить.
  if pgrep -f wineboot >/dev/null || [ $((now - ENV_READY_AT)) -lt 15 ]; then return 0; fi
  # Занятый Highball пропускает ссылку. Повтор безопасен: идущую установку он не перебивает.
  if [ "$SENT_STEAM_AT" -eq 0 ] || [ $((now - SENT_STEAM_AT)) -ge 180 ]; then
    open_link "highball://open/launcher/steam?t=$TOKEN"
    SENT_STEAM_AT=$now
  fi
}

launch_steam() {  # launch_steam <среда>
  local log="$1/$STEAM_DIR_IN_ENV/logs/bootstrap_log.txt"
  BOOT_BEFORE=0
  if [ -f "$log" ]; then BOOT_BEFORE=$(wc -l < "$log" | tr -d ' '); fi
  open_link "highball://open/launcher/steam?t=$TOKEN"
  LAUNCHED=1
  DOWN=0
}

act_open_steam() {  # act_open_steam <среда> <сейчас> — первое открытие Steam
  local env=$1 now=$2
  # Пока Highball не записал рецепт Steam, ссылка начнёт установку заново, а не откроет Steam.
  if ! grep -q '"steam"' "$env/bottle.json" 2>/dev/null && [ $((now - STEAM_SEEN_AT)) -lt 300 ]; then return 0; fi
  if [ "$SENT_STEAM_AT" -ne 0 ] && [ $((now - STEAM_SEEN_AT)) -lt 10 ]; then return 0; fi
  if pgrep -x steam_osx >/dev/null; then
    HINT="Закрываю Steam для macOS:
один аккаунт не может быть в сети в двух Steam сразу."
    draw
    quit_app "$MAC_STEAM_ID" steam_osx || true
  fi
  launch_steam "$env"
}

# Закрывает Steam в среде, как кнопка OK в окне ошибки, и ждёт, пока Wine остановится.
stop_steam() {
  local pattern i
  pattern="bottles/$(basename "$1")/drive_c/Program Files .x86./Steam/steam.exe"
  pkill -f "$pattern" 2>/dev/null || true
  for i in $(seq 1 30); do
    if ! pgrep -f "$pattern" >/dev/null; then break; fi
    sleep 1
  done
  sleep 5
}

# Известные сбои первого запуска Steam под Rosetta. Оба лечатся перезапуском, делаем до двух раз.
# 1. Загрузчик виснет на первом запросе и через минуту пишет «Steam needs to be online to update»,
#    хотя интернет есть. Найдено на чистой установке 08.11: со второго запуска Steam сразу качался.
# 2. Новый клиент закрывается сам минуты через три после первого обновления (заметки Highball).
act_watch_steam() {  # act_watch_steam <среда>
  local env=$1 new
  if [ "$LAUNCHED" = 0 ] || [ "$RESTARTS" -ge 2 ]; then return 0; fi
  new=$(tail -n +"$((BOOT_BEFORE + 1))" "$env/$STEAM_DIR_IN_ENV/logs/bootstrap_log.txt" 2>/dev/null || true)
  case "$new" in
    *"needs to be online"*)
      RESTARTS=$((RESTARTS + 1))
      HINT="Steam завис на первой загрузке, это известный сбой. Перезапускаю его."
      draw
      stop_steam "$env"
      launch_steam "$env"
      return 0 ;;
  esac
  if [ "$DOWN" -ge 30 ]; then
    RESTARTS=$((RESTARTS + 1))
    launch_steam "$env"
  fi
}

# --- этапы 4–9 --------------------------------------------------------------------------------
# Раскладывает по этапам то, что видно в папках Highball, процессах и журналах Steam. Вызывается
# раз в секунду. В режиме install ещё и делает следующий шаг: просит Highball поставить Steam,
# открывает его и перезапускает после известных сбоев.

refresh_state() {  # refresh_state install|watch
  local mode=$1 env upd game now got pct
  now=$(date +%s)
  HINT=""
  if steam_running; then DOWN=0; else DOWN=$((DOWN + 1)); fi

  if ! engine_installed; then
    got=$(dir_kb "$HB_HOME/downloads")
    if [ "$got" -lt 2048 ]; then
      set_stage 3 run "ждёт кнопку"
      HINT="Нажмите «Get started» в окне Highball. Больше ничего нажимать не нужно."
    elif [ "$got" -ge $(( ENGINE_KB * 98 / 100 )) ]; then
      set_stage 3 run "распаковывает"
      HINT="Highball распаковывает движок Wine."
    else
      set_stage 3 run "$(( got / 1024 )) из $(( ENGINE_KB / 1024 )) МБ" $(( got * 100 / ENGINE_KB ))
      HINT="Highball качает движок Wine с GitHub. Это нужно один раз."
    fi
    rest_wait 3
    return 0
  fi
  set_stage 3 done "скачан"

  if ! ready_env >/dev/null; then
    set_stage 4 run "готовит Highball"
    HINT="Highball готовит среду Windows. Обычно это пара минут."
    ENV_READY_AT=0
    rest_wait 4
    return 0
  fi
  set_stage 4 done "готова"
  if [ "$ENV_READY_AT" -eq 0 ]; then ENV_READY_AT=$now; fi

  if ! env=$(steam_env); then
    set_stage 5 run "ставится"
    if [ "$mode" = install ]; then
      HINT="Ставлю Steam для Windows. Установщик качается с серверов Valve."
      act_install_steam "$now"
    else
      HINT="Ждём Steam для Windows. Установщик закрыт? Запустите «Установить.command»."
    fi
    rest_wait 5
    return 0
  fi
  set_stage 5 done "установлен"
  if [ "$STEAM_SEEN_AT" -eq 0 ]; then STEAM_SEEN_AT=$now; fi
  if [ "$mode" = install ] && [ "$LAUNCHED" = 0 ]; then act_open_steam "$env" "$now"; fi

  game=$(game_info "$env" "$GAME_APPID")
  case "$game" in
    installed)
      set_stage 6 done "готово"
      set_stage 7 done "выполнен"
      set_stage 8 done "установлена"
      return 0 ;;
    none) ;;
    *)
      pct=${game%% *}; game=${game#* }
      set_stage 6 done "готово"
      set_stage 7 done "выполнен"
      set_stage 8 run "${game% *} из ${game#* } МБ" "$pct"
      HINT="Steam качает и ставит игру. Окно Steam можно свернуть."
      return 0 ;;
  esac

  if [ -f "$env/$STEAM_DIR_IN_ENV/config/loginusers.vdf" ]; then
    set_stage 6 done "готово"
    set_stage 7 done "выполнен"
    set_stage 8 run "ждёт установки"
    HINT="В Steam откройте Библиотеку → $GAME_NAME → «Установить».
Игры нет в библиотеке? Купите её в магазине Steam."
    return 0
  fi

  upd=$(steam_update_info "$env")
  if [ "$mode" = install ]; then act_watch_steam "$env"; fi
  if webhelper_running; then
    set_stage 6 done "готово"
    set_stage 7 run "ждёт вас"
    HINT="Войдите в свой аккаунт в окне Steam.
Код Steam Guard придёт в приложение Steam на телефоне.
Окна Steam не видно? Нажмите «Show Steam» в окне Highball."
    rest_wait 7
    return 0
  fi
  if [ "$upd" = offline ]; then
    set_stage 6 run "нет связи"
    if [ "$mode" = install ] && [ "$RESTARTS" -lt 2 ]; then
      HINT="Steam завис на первой загрузке, это известный сбой. Перезапускаю его."
    else
      HINT="Steam не смог скачать обновление.
Нажмите OK в его окне и запустите установку снова."
    fi
  elif [ -n "$upd" ]; then
    pct=${upd%% *}; upd=${upd#* }
    set_stage 6 run "$(( ${upd% *} / 1024 )) из $(( ${upd#* } / 1024 )) МБ" "$pct"
    HINT="Steam качает своё обновление. Окно может выглядеть зависшим, это нормально."
  elif [ "$DOWN" -ge 30 ]; then
    set_stage 6 run "закрыт"
    if [ "$mode" = install ] && [ "$RESTARTS" -lt 2 ]; then
      HINT="Steam закрылся до входа, это известный сбой. Открываю его снова."
    else
      HINT="Steam закрыт. Откройте его кнопкой «Open Steam» в окне Highball."
    fi
  else
    set_stage 6 run "запускается"
    HINT="Steam распаковывает обновление и запускается. Под Rosetta это небыстро."
  fi
  rest_wait 6
}

run_plan() {  # run_plan install|watch
  local mode=$1 t=0 start now
  start=$(date +%s)
  ENGINE_KB=$(engine_total_kb)
  while :; do
    if [ $((t % 5)) -eq 0 ]; then
      refresh_state "$mode"
      if [ "${ST[8]}" = done ]; then
        HINT="${C_OK}Играйте: кнопка Play у игры в Highball.${C_0}"
        FOOT=""
        draw
        return 0
      fi
      if [ "$mode" = watch ]; then
        FOOT="Это окно только смотрит. Его можно закрыть, установка не прервётся."
      elif [ "${ST[7]}" = done ]; then
        FOOT="Дальше установщик только смотрит. Окно можно закрыть, игра докачается."
      else
        FOOT="Не закрывайте это окно до входа в Steam: установщик ещё помогает."
      fi
      now=$(date +%s)
      if [ $((now - start)) -ge 14400 ]; then
        HINT="Смотрю уже 4 часа и останавливаюсь.
Снова посмотреть: «Статус установки.command»."
        FOOT=""
        draw
        return 0
      fi
    fi
    draw
    FRAME=$((FRAME + 1))
    t=$((t + 1))
    sleep 0.2
  done
}

# --- команды ----------------------------------------------------------------------------------

cmd_install() {
  dash_start
  stage_check_mac
  stage_rosetta
  stage_highball
  HB_HOME=$(hb_home)
  TOKEN=$(hb_token)
  open -a "$HB_APP"
  run_plan install
}

cmd_watch() {
  local appid=${1:-$GAME_APPID_DEFAULT}
  case "$appid" in *[!0-9]*|"") die "appid — это число из адреса игры в магазине Steam." ;; esac
  GAME_APPID=$appid
  if [ "$appid" != "$GAME_APPID_DEFAULT" ]; then GAME_NAME="Игра $appid"; STAGES[8]=$GAME_NAME; fi
  HB_APP=$(hb_app_path) || die "Highball не установлен. Сначала запустите «Установить.command»."
  HB_HOME=$(hb_home)
  set_stage 0 done "macOS $(sw_vers -productVersion)"
  if arch -x86_64 /usr/bin/true 2>/dev/null; then set_stage 1 done "установлена"; else set_stage 1 fail "не установлена"; fi
  set_stage 2 done "$(app_version "$HB_APP")"
  dash_start
  run_plan watch
}

cmd_play() {
  local appid=${1:-$GAME_APPID_DEFAULT}
  case "$appid" in *[!0-9]*|"") die "appid — это число из адреса игры в магазине Steam." ;; esac
  HB_APP=$(hb_app_path) || die "Highball не установлен. Сначала запустите «Установить.command»."
  HB_HOME=$(hb_home)
  TOKEN=$(hb_token)
  steam_env >/dev/null || die "Steam для Windows ещё не установлен. Запустите «Установить.command»."
  if pgrep -x steam_osx >/dev/null; then
    info "Закрываю Steam для macOS: один аккаунт не может быть в сети в двух Steam сразу."
    quit_app "$MAC_STEAM_ID" steam_osx || warn "Steam для macOS не закрылся. Закройте его сами: Steam → Выйти из Steam."
  fi
  if ! game_installed "$appid"; then
    warn "Игра $appid ещё не установлена в Steam для Windows. Открываю Steam: установите её там."
    open_link "highball://open/launcher/steam?t=$TOKEN"
    return 0
  fi
  info "Запускаю игру через Highball. Steam для Windows стартует сам, в фоне."
  open_link "highball://play/steam/$appid?t=$TOKEN"
}

case "${1:-install}" in
  install) cmd_install ;;
  watch|status) shift; cmd_watch "$@" ;;
  play) shift; cmd_play "$@" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
