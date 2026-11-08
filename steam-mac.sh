#!/bin/bash
# steam-mac.sh — Windows-игры из Steam на Mac с чипом Apple (M1 и новее) через Highball.
#
#   bash steam-mac.sh install        ставит Rosetta 2, Highball, среду Windows и Steam для Windows
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

HB_APP=""
HB_HOME=""
TOKEN=""
TMP=""

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  [ -n "$TMP" ] || return 0
  if [ -d "$TMP/mnt" ]; then
    hdiutil detach "$TMP/mnt" -quiet 2>/dev/null || hdiutil detach "$TMP/mnt" -force -quiet 2>/dev/null || true
  fi
  # Образ так и не отключился — не трогаем папку, чтобы не задеть его содержимое.
  if ! mount | grep -qF "$TMP/mnt"; then rm -rf "$TMP"; fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
Windows-игры из Steam на Mac с чипом Apple.

  bash steam-mac.sh install        установить всё нужное (по умолчанию)
  bash steam-mac.sh play [appid]   запустить игру (без appid — $GAME_NAME_DEFAULT, $GAME_APPID_DEFAULT)
EOF
}

# --- проверки и Rosetta -----------------------------------------------------------------------

check_mac() {
  bold "1/6. Проверяю Mac"
  [ "$(id -u)" -ne 0 ] || die "Не запускайте установку через sudo: Highball работает от имени пользователя."
  # hw.optional.arm64 = 1 и под Rosetta, поэтому не uname -m.
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] \
    || die "Нужен Mac с чипом Apple M1 или новее. На Mac с процессором Intel Highball не работает."
  local ver major free_kb free_gb
  ver=$(sw_vers -productVersion)
  major=${ver%%.*}
  [ "$major" -ge "$MIN_MACOS" ] || die "Нужна macOS $MIN_MACOS (Sonoma) или новее, у вас $ver."
  free_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
  free_gb=$(( free_kb / 1024 / 1024 ))
  info "Чип Apple, macOS $ver, свободно ${free_gb} ГБ."
  if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
    warn "Нужно около ${MIN_FREE_GB} ГБ свободного места. Установка может не поместиться."
  fi
}

ensure_rosetta() {
  bold "2/6. Rosetta 2"
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    info "Уже установлена."
    return 0
  fi
  info "Ставлю Rosetta 2 от Apple: через неё работает движок Wine."
  softwareupdate --install-rosetta --agree-to-license >/dev/null \
    || die "Rosetta не установилась. Выполните в Терминале: softwareupdate --install-rosetta --agree-to-license"
  arch -x86_64 /usr/bin/true 2>/dev/null \
    || die "Rosetta установлена, но не запускается. Перезагрузите Mac и запустите установку снова."
  info "Готово."
}

# --- Highball ---------------------------------------------------------------------------------

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
  info "Подпись разработчика и проверка Apple в порядке."
}

quit_app() {  # quit_app <bundle id> <имя процесса> <что сказать>
  pgrep -x "$2" >/dev/null || return 0
  info "$3"
  osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    pgrep -x "$2" >/dev/null || return 0
    sleep 1
  done
  return 1
}

install_highball() {
  bold "3/6. Highball"
  local app cur latest
  app=$(hb_app_path || true)
  cur=0
  if [ -n "$app" ]; then cur=$(app_version "$app"); fi
  latest=$(hb_latest_version || true)
  if [ -z "$latest" ]; then
    [ -n "$app" ] || die "Не удалось узнать последнюю версию Highball на GitHub. Проверьте интернет и запустите снова."
    warn "GitHub не ответил, оставляю установленную версию $cur."
    HB_APP=$app
    return 0
  fi
  if [ -n "$app" ] && ! version_lt "$cur" "$latest"; then
    info "Установлена последняя версия $cur."
    HB_APP=$app
    return 0
  fi

  info "Скачиваю Highball $latest с GitHub…"
  TMP=$(mktemp -d -t steam-mac)
  curl -fL --retry 3 --progress-bar -o "$TMP/Highball.dmg" \
    "https://github.com/$HB_REPO/releases/download/v$latest/Highball.dmg" || die "Не скачался Highball."
  mkdir "$TMP/mnt"
  # macOS 27 пишет, что hdiutil attach устарел, но команда работает и есть во всех macOS 14+.
  local out
  out=$(hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$TMP/mnt" "$TMP/Highball.dmg" 2>&1) \
    || die "Не открылся образ Highball.dmg: $out"
  [ -d "$TMP/mnt/Highball.app" ] || die "В образе нет Highball.app."
  verify_app "$TMP/mnt/Highball.app"

  local dest_dir
  if [ -n "$app" ]; then
    dest_dir=$(dirname "$app")
  elif [ -w /Applications ]; then
    dest_dir=/Applications
  else
    dest_dir="$HOME/Applications"
    mkdir -p "$dest_dir"
  fi
  quit_app "$HB_BUNDLE_ID" Highball "Закрываю Highball, чтобы обновить его." \
    || die "Highball не закрылся. Закройте его сами и запустите установку снова."
  ditto "$TMP/mnt/Highball.app" "$dest_dir/.Highball.app.new" || die "Не удалось скопировать Highball в $dest_dir."
  if [ -d "$dest_dir/Highball.app" ]; then mv "$dest_dir/Highball.app" "$TMP/Highball.old.app"; fi
  mv "$dest_dir/.Highball.app.new" "$dest_dir/Highball.app"
  HB_APP="$dest_dir/Highball.app"
  info "Highball $latest установлен: $HB_APP"
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

# --- среда Windows и Steam --------------------------------------------------------------------

# Готовая среда: после первого запуска Wine в ней есть system.reg. Highball по умолчанию берёт «Games».
ready_env() {
  local d
  if [ -f "$HB_HOME/bottles/Games/system.reg" ]; then echo "$HB_HOME/bottles/Games"; return 0; fi
  for d in "$HB_HOME"/bottles/*/; do
    if [ -f "${d}system.reg" ]; then echo "${d%/}"; return 0; fi
  done
  return 1
}

# Скачанный движок — папка в engines/. Недокачанный лежит там же, но с точкой в начале имени.
engine_installed() {
  local d
  for d in "$HB_HOME"/engines/*/; do
    if [ -d "$d" ]; then return 0; fi
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

wait_for_env() {
  bold "4/6. Движок Wine и среда Windows"
  if ready_env >/dev/null; then
    info "Среда Windows уже готова."
    return 0
  fi
  info "В окне Highball нажмите одну кнопку: «Get started»."
  info "Highball сам скачает движок Wine и подготовит среду Windows. Обычно 5–15 минут."
  local waited=0
  until ready_env >/dev/null; do
    sleep 10
    waited=$((waited + 10))
    if [ $((waited % 300)) -eq 0 ]; then
      if engine_installed; then
        info "Движок скачан, Highball готовит среду Windows. Прошло $((waited / 60)) мин."
      else
        info "Прошло $((waited / 60)) мин. Если в окне Highball видна кнопка «Get started», нажмите её."
      fi
    fi
    if [ "$waited" -ge 5400 ]; then
      die "Среда Windows не появилась за 90 минут. Посмотрите, что пишет Highball, и запустите установку снова."
    fi
  done
  # Wine дописывает реестр и закрывается, Highball доделывает настройку — даём им закончить.
  while pgrep -f wineboot >/dev/null; do sleep 3; done
  sleep 15
  info "Среда Windows готова."
}

quit_mac_steam() {
  quit_app "$MAC_STEAM_ID" steam_osx \
    "Закрываю Steam для macOS: один аккаунт не может быть в сети в двух Steam сразу." \
    || warn "Steam для macOS не закрылся. Закройте его сами: Steam → Выйти из Steam."
}

install_steam() {
  bold "5/6. Steam для Windows"
  local env waited=0 i
  if env=$(steam_env); then
    info "Уже установлен (среда «$(basename "$env")»)."
  else
    info "Ставлю Steam для Windows в среду Highball. Установщик качается с серверов Valve."
    open_link "highball://open/launcher/steam?t=$TOKEN"
    until env=$(steam_env); do
      sleep 10
      waited=$((waited + 10))
      # Занятый Highball пропускает ссылку. Повтор безопасен: идущую установку он не перебивает.
      if [ $((waited % 180)) -eq 0 ]; then open_link "highball://open/launcher/steam?t=$TOKEN"; fi
      if [ "$waited" -ge 3600 ]; then
        die "Steam не установился за час. Откройте Highball, нажмите Steam и посмотрите, что он пишет."
      fi
    done
    # Пока Highball не записал рецепт Steam, ссылка начнёт установку заново, а не откроет Steam.
    for i in $(seq 1 60); do
      if grep -q '"steam"' "$env/bottle.json" 2>/dev/null; then break; fi
      sleep 5
    done
    sleep 10
    info "Установлен."
  fi
  quit_mac_steam
  info "Открываю Steam для Windows. Первый запуск качает сам Steam: 15–25 минут, окно может выглядеть зависшим."
  open_steam_watched "$env"
}

# Загрузчик Steam под Rosetta иногда виснет на первом же запросе и через минуту пишет
# «Steam needs to be online to update», хотя интернет есть. Помогает перезапуск, его и делаем.
# Найдено на чистой установке 08.11: со второго запуска Steam сразу начал качаться.
open_steam_watched() {
  local env=$1 log before tries=0 waited new
  log="$env/$STEAM_DIR_IN_ENV/logs/bootstrap_log.txt"
  while :; do
    before=0
    if [ -f "$log" ]; then before=$(wc -l < "$log" | tr -d ' '); fi
    open_link "highball://open/launcher/steam?t=$TOKEN"
    waited=0
    while [ "$waited" -lt 100 ]; do
      sleep 5
      waited=$((waited + 5))
      new=$(tail -n +"$((before + 1))" "$log" 2>/dev/null || true)
      case "$new" in
        *"Downloading update ("*) info "Steam качает обновление, всё идёт как надо."; return 0 ;;
        *"needs to be online"*) break ;;
      esac
    done
    case "$new" in
      *"needs to be online"*) ;;
      *) return 0 ;;
    esac
    tries=$((tries + 1))
    if [ "$tries" -gt 2 ]; then
      warn "Steam трижды не смог скачать обновление. Проверьте интернет, нажмите OK в окне Steam и запустите установку снова."
      return 0
    fi
    warn "Steam завис на первой загрузке, это известный сбой. Перезапускаю его (попытка $tries из 2)."
    stop_steam "$env"
  done
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

game_installed() {  # game_installed <appid>
  ls "$HB_HOME"/bottles/*/"$STEAM_DIR_IN_ENV"/steamapps/appmanifest_"$1".acf >/dev/null 2>&1
}

finish_hint() {
  bold "6/6. $GAME_NAME_DEFAULT"
  if game_installed "$GAME_APPID_DEFAULT"; then
    info "Игра уже установлена. Запуск: «Играть в Machine Party.command» или кнопка Play в Highball."
    return 0
  fi
  cat <<EOF
  Осталось сделать в окне Steam для Windows:
   1. Дождитесь, пока Steam докачает себя и покажет окно входа.
   2. Войдите в свой аккаунт. Код Steam Guard придёт в приложение Steam на телефоне.
   3. Библиотека → $GAME_NAME_DEFAULT → «Установить». Нет в библиотеке — купите в магазине Steam.
   4. Играйте: кнопка Play у игры в Highball или файл «Играть в Machine Party.command».

  Steam закрылся сам минуты через три после первого обновления? Это известный сбой нового клиента.
  Запустите установку ещё раз: она откроет Steam снова, дальше он работает нормально.
EOF
}

# --- команды ----------------------------------------------------------------------------------

cmd_install() {
  check_mac
  ensure_rosetta
  install_highball
  HB_HOME=$(hb_home)
  TOKEN=$(hb_token)
  info "Открываю Highball."
  open -a "$HB_APP"
  wait_for_env
  install_steam
  finish_hint
}

cmd_play() {
  local appid=${1:-$GAME_APPID_DEFAULT}
  case "$appid" in *[!0-9]*|"") die "appid — это число из адреса игры в магазине Steam." ;; esac
  HB_APP=$(hb_app_path) || die "Highball не установлен. Сначала запустите «Установить.command»."
  HB_HOME=$(hb_home)
  TOKEN=$(hb_token)
  steam_env >/dev/null || die "Steam для Windows ещё не установлен. Запустите «Установить.command»."
  quit_mac_steam
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
  play) shift; cmd_play "$@" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
