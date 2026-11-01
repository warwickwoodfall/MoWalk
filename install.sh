#!/bin/bash
# =============================================================================
#  Mo'Walk installer -- builds the app on this Mac and puts it on your iPhone.
#
#  Run it from Terminal, inside the MoWalk folder:      bash install.sh
#
#  It checks everything as it goes and tells you exactly what to do when it
#  needs you. Safe to run again at any time (e.g. every week -- see README).
# =============================================================================

set -u
cd "$(dirname "$0")" || exit 1
HERE="$(pwd)"
CONFIG="$HERE/.mowalk-local"          # remembers your choices for next time
LOG="$HERE/build.log"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- look and feel ----------------------------------------------------
if [ -t 1 ]; then
  B=$(tput bold); G=$(tput setaf 2); Y=$(tput setaf 3); R=$(tput setaf 1); C=$(tput setaf 6); N=$(tput sgr0)
else
  B=""; G=""; Y=""; R=""; C=""; N=""
fi
STEP=0
step()  { STEP=$((STEP + 1)); echo; echo "${B}${C}==================================================================${N}"
          echo "${B}${C}  STEP $STEP: $1${N}"; echo "${B}${C}==================================================================${N}"; }
ok()    { echo "  ${G}✔${N} $1"; }
warn()  { echo "  ${Y}!${N} $1"; }
bad()   { echo "  ${R}✘${N} $1"; }
say()   { echo "  $1"; }
todo()  { echo "     ${B}→${N} $1"; }
enter() { echo; read -r -p "  ${B}Press Enter when you've done that${N} (or type q to quit): " a || bye; [ "$a" = "q" ] && bye; }
yesno() {   # yesno "question" -> returns 0 for y, 1 for n
  local a
  while true; do
    read -r -p "  ${B}$1 (y/n):${N} " a || bye
    case "$a" in y|Y|yes|YES) return 0 ;; n|N|no|NO) return 1 ;; *) say "Please type y or n, then Enter." ;; esac
  done
}
bye()   { echo; say "Stopped. Nothing is broken -- run ${B}bash install.sh${N} again whenever you like."; exit 1; }
save()  { # save KEY VALUE into the config file
  grep -v "^$1=" "$CONFIG" 2>/dev/null > "$TMP/cfg"; echo "$1=\"$2\"" >> "$TMP/cfg"; mv "$TMP/cfg" "$CONFIG"; }
[ -f "$CONFIG" ] && . "$CONFIG"
TEAM_ID="${TEAM_ID:-}"; BUNDLE_ID="${BUNDLE_ID:-}"

ver_ge() {  # ver_ge 14.5 13.5 -> true if $1 >= $2
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

# =============================================================================
clear 2>/dev/null
echo "${B}"
echo "   __  __       _ __        __    _ _    "
echo "  |  \/  | ___ ( )\ \      / /_ _| | | __"
echo "  | |\/| |/ _ \|/  \ \ /\ / / _\` | | |/ /"
echo "  | |  | | (_) |    \ V  V / (_| | |   < "
echo "  |_|  |_|\___/      \_/\_/ \__,_|_|_|\_\\"
echo "${N}"
say "This puts the ${B}Mo'Walk${N} app on your iPhone, straight from this Mac."
say "It goes step by step and tells you exactly what to do. You will need:"
echo
todo "this Mac, connected to the internet"
todo "your iPhone (iOS 17 or newer) and its passcode"
todo "a USB cable that connects the iPhone to this Mac (the charging cable is fine"
say  "     if it's the one that came with the phone)"
todo "your Apple ID email and password (the one your iPhone uses is fine)"
todo "your Mac login password (Terminal may ask for it -- nothing shows as you type)"
echo
say "If Xcode (Apple's free developer app) isn't on this Mac yet, it has to be"
say "downloaded first: that's a big download, 30-60 minutes. Everything else is quick."
echo
say "${Y}Don't plug your iPhone in yet${N} -- I'll tell you when."
echo
yesno "Ready to start?" || bye

# =============================================================================
step "Checking this Mac"
MACOS=$(sw_vers -productVersion)
say "macOS version: ${B}$MACOS${N}   ($(uname -m))"
if ! ver_ge "$MACOS" "13.5"; then
  bad "This Mac is too old for the Xcode version the app needs (macOS 13.5 or newer)."
  todo "Update it: Apple menu  → System Settings → General → Software Update."
  todo "If no update is offered, this Mac can't build the app -- ask Warwick for a TestFlight invite instead."
  bye
fi
ok "macOS is new enough."
FREE_GB=$(df -g / | awk 'NR==2 {print $4}')
say "Free disk space: ${B}${FREE_GB} GB${N}"
if [ ! -d /Applications/Xcode.app ] && [ "$FREE_GB" -lt 40 ]; then
  warn "Xcode needs about 40 GB free to download and install. You have ${FREE_GB} GB."
  todo "Free some space (empty the Bin, delete old downloads), then carry on."
  yesno "Carry on anyway?" || bye
else
  ok "Enough disk space."
fi

# =============================================================================
step "Xcode (Apple's free app for building iPhone apps)"
while [ ! -d /Applications/Xcode.app ]; do
  bad "Xcode is not installed."
  say "I'll open the App Store on the Xcode page for you."
  todo "Click ${B}Get${N} (or the cloud icon), then ${B}Install${N}. Sign in to the App Store if it asks."
  todo "Wait for it to finish -- it's big: 30-60 minutes. Leave this window open."
  todo "When it's installed, ${B}open Xcode once${N} (Launchpad → Xcode)."
  todo "If Xcode asks which platforms to download, make sure ${B}iOS${N} is ticked, click Download/Install."
  todo "If it asks for your Mac password to install components, type it in."
  todo "When you see the 'Welcome to Xcode' window, quit Xcode (⌘Q) and come back here."
  if [ "$MACOS" != "" ] && ! ver_ge "$MACOS" "15.0"; then
    warn "Your macOS is older; if the App Store says Xcode needs a newer macOS, either update macOS"
    say  "     (System Settings → General → Software Update) or get Xcode 15.4 from"
    say  "     https://developer.apple.com/download/all/ (sign in with your Apple ID, search 'Xcode 15.4',"
    say  "     download, double-click the .xip, drag Xcode into Applications)."
  fi
  open "macappstore://apps.apple.com/app/xcode/id497799835" 2>/dev/null
  enter
done
XV=$(defaults read /Applications/Xcode.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)
ok "Xcode $XV is installed."
if ! ver_ge "${XV:-0}" "15.0"; then
  bad "This Xcode is too old (need 15 or newer). Update it from the App Store (Updates), then run this again."
  bye
fi

DEV=$(xcode-select -p 2>/dev/null)
if [ "$DEV" != "/Applications/Xcode.app/Contents/Developer" ]; then
  warn "Terminal's developer tools point at: ${DEV:-nothing}"
  say  "They need to point at Xcode. I'll fix that now -- ${B}type your Mac login password${N} when asked"
  say  "(nothing shows as you type; press Enter at the end)."
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer || { bad "That didn't work."; bye; }
fi
ok "Developer tools point at Xcode."

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  say "Xcode needs its one-time setup (licence + components)."
  say "${B}Type your Mac login password${N} if asked. This can take a few minutes."
  sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch || { bad "Xcode setup failed. Open Xcode once by hand, then run this again."; bye; }
fi
ok "Xcode is set up."

if ! xcodebuild -showsdks 2>/dev/null | grep -q iphoneos; then
  warn "Xcode hasn't got the iOS parts yet. Downloading them now (a few GB, 5-20 minutes)..."
  xcodebuild -downloadPlatform iOS || { bad "Download failed. Open Xcode → Settings → Components, install iOS, then run this again."; bye; }
fi
ok "iOS building tools are there."

# =============================================================================
step "Your Apple ID in Xcode (this is what signs the app)"
read_teams() {   # prints lines: TEAMID|Team name|free(0/1)
  rm -f "$TMP/x.plist"
  defaults export com.apple.dt.Xcode "$TMP/x.plist" 2>/dev/null || return
  /usr/bin/python3 - "$TMP/x.plist" <<'PY' 2>/dev/null
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
t = d.get('IDEProvisioningTeamByIdentifier') or d.get('IDEProvisioningTeams') or {}
seen = set()
for teams in t.values():
    for x in teams:
        i = x.get('teamID')
        if i and i not in seen:
            seen.add(i)
            print('%s|%s|%d' % (i, x.get('teamName', '?'), 1 if x.get('isFreeProvisioningTeam') else 0))
PY
}
TEAMS="$(read_teams)"
while [ -z "$TEAMS" ]; do
  bad "Xcode isn't signed in to an Apple ID yet."
  say "I'll open Xcode for you. Then:"
  todo "In the menu bar at the top of the screen click ${B}Xcode${N} → ${B}Settings…${N}  (or press ⌘ and comma)"
  todo "Click the ${B}Accounts${N} tab."
  todo "Click the ${B}+${N} button at the bottom-left → choose ${B}Apple ID${N} → ${B}Continue${N}."
  todo "Sign in with your Apple ID and password (and the code sent to your phone, if asked)."
  todo "You should now see your name with ${B}(Personal Team)${N} next to it. That's all."
  todo "Close the Settings window (you can leave Xcode open), then come back here."
  open -a Xcode 2>/dev/null
  enter
  TEAMS="$(read_teams)"
done

if [ -n "$TEAM_ID" ] && echo "$TEAMS" | grep -q "^$TEAM_ID|"; then
  ok "Using the same team as last time: $(echo "$TEAMS" | grep "^$TEAM_ID|" | cut -d'|' -f2)"
else
  N_TEAMS=$(echo "$TEAMS" | wc -l | tr -d ' ')
  if [ "$N_TEAMS" = "1" ]; then
    TEAM_ID=$(echo "$TEAMS" | cut -d'|' -f1)
    ok "Signed in: $(echo "$TEAMS" | cut -d'|' -f2)"
  else
    say "Xcode knows these teams:"
    i=0
    echo "$TEAMS" | while IFS='|' read -r tid tname tfree; do
      i=$((i + 1)); echo "     ${B}$i${N}) $tname  ($([ "$tfree" = 1 ] && echo free personal team || echo paid developer team))"
    done
    while true; do
      read -r -p "  ${B}Type the number of the team to use, then Enter:${N} " pick || bye
      TEAM_ID=$(echo "$TEAMS" | sed -n "${pick}p" 2>/dev/null | cut -d'|' -f1)
      [ -n "$TEAM_ID" ] && break
      say "That's not one of the numbers above."
    done
  fi
  save TEAM_ID "$TEAM_ID"
fi
FREE_TEAM=$(echo "$TEAMS" | grep "^$TEAM_ID|" | cut -d'|' -f3)
if [ "$FREE_TEAM" = "1" ]; then
  warn "This is a ${B}free${N} Apple ID (Personal Team). That's fine, but Apple makes apps"
  say  "     installed this way stop opening after ${B}7 days${N}. Just plug the phone in and run"
  say  "     ${B}bash install.sh${N} again to renew it -- your walks and photos are kept."
fi

# app id: must be unique to you, and the same every time so re-installs keep your data
if [ -z "$BUNDLE_ID" ]; then
  U=$(id -un | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z' | cut -c1-20)
  BUNDLE_ID="com.mowalk.${U:-walker}$(( (RANDOM % 9000) + 1000 ))"
  save BUNDLE_ID "$BUNDLE_ID"
fi
ok "App id: $BUNDLE_ID"

# =============================================================================
step "Your iPhone"
say "${B}Now plug your iPhone into this Mac with the cable.${N}"
todo "Unlock the iPhone (it must stay unlocked during the install)."
todo "If the iPhone asks ${B}'Trust This Computer?'${N} tap ${B}Trust${N} and enter your iPhone passcode."
todo "If the Mac asks ${B}'Allow accessory to connect?'${N} click ${B}Allow${N}."
enter

find_phones() {  # prints lines: id|name|iOS|devmode|paired|udid
  rm -f "$TMP/dev.json"
  xcrun devicectl list devices --json-output "$TMP/dev.json" >/dev/null 2>&1
  /usr/bin/python3 - "$TMP/dev.json" <<'PY' 2>/dev/null
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit()
for x in d.get('result', {}).get('devices', []):
    h, p, c = x.get('hardwareProperties', {}), x.get('deviceProperties', {}), x.get('connectionProperties', {})
    if h.get('platform') != 'iOS' or h.get('deviceType') not in (None, 'iPhone'): continue
    here = c.get('transportType') == 'wired' or c.get('tunnelState') == 'connected'
    if not here: continue
    print('%s|%s|%s|%s|%s|%s' % (x['identifier'], p.get('name', 'iPhone'), p.get('osVersionNumber', '?'),
                                 p.get('developerModeStatus', '?'), c.get('pairingState', '?'), h.get('udid', '')))
PY
}

while true; do
  say "Looking for your iPhone..."
  PHONES="$(find_phones)"
  [ -n "$PHONES" ] && break
  bad "I can't see an iPhone plugged in."
  todo "Check the cable is pushed in at both ends. Some cheap cables only charge -- try another."
  todo "Unlock the phone. Look for the 'Trust This Computer?' message on it and tap Trust."
  todo "Try a different USB port on the Mac (avoid USB hubs if you can)."
  enter
done

if [ "$(echo "$PHONES" | wc -l | tr -d ' ')" != "1" ]; then
  say "More than one iPhone is connected:"
  echo "$PHONES" | awk -F'|' '{printf "     %d) %s (iOS %s)\n", NR, $2, $3}'
  while true; do
    read -r -p "  ${B}Type the number of the iPhone to install on:${N} " pick || bye
    PHONE=$(echo "$PHONES" | sed -n "${pick}p" 2>/dev/null); [ -n "$PHONE" ] && break
  done
else
  PHONE="$PHONES"
fi
DEVICE_ID=$(echo "$PHONE" | cut -d'|' -f1); PHONE_NAME=$(echo "$PHONE" | cut -d'|' -f2)
IOS=$(echo "$PHONE" | cut -d'|' -f3)
UDID=$(echo "$PHONE" | cut -d'|' -f6)
ok "Found ${B}$PHONE_NAME${N} (iOS $IOS)"

if ! ver_ge "$IOS" "17.0"; then
  bad "Mo'Walk needs iOS 17 or newer; this iPhone has iOS $IOS."
  todo "On the iPhone: Settings → General → Software Update. Then run this again."
  bye
fi

while [ "$(echo "$PHONE" | cut -d'|' -f5)" != "paired" ]; do
  bad "The iPhone hasn't trusted this Mac yet."
  todo "Unplug the cable and plug it back in, with the iPhone unlocked."
  todo "Tap ${B}Trust${N} on the iPhone and enter your passcode."
  enter
  PHONE="$(find_phones | grep "^$DEVICE_ID|")"
  [ -z "$PHONE" ] && PHONE="x|x|x|x|x|"
done
ok "The iPhone trusts this Mac."

while [ "$(echo "$PHONE" | cut -d'|' -f4)" != "enabled" ]; do
  bad "${B}Developer Mode${N} is off on the iPhone. Apple requires it to install apps from a Mac."
  todo "On the iPhone open ${B}Settings${N} → ${B}Privacy & Security${N} → scroll right to the bottom →"
  say  "       ${B}Developer Mode${N} → switch it ${B}on${N} → tap ${B}Restart${N}."
  todo "After the phone restarts and you unlock it, a message asks to turn on Developer Mode:"
  say  "       tap ${B}Turn On${N} and enter your passcode."
  todo "Leave the cable plugged in."
  say  "   (Can't see 'Developer Mode' in that list? I'm opening Xcode -- with the phone plugged in"
  say  "    and unlocked, wait a minute, then look again. It appears once a Mac with Xcode has seen the phone.)"
  open -a Xcode 2>/dev/null
  enter
  PHONE="$(find_phones | grep "^$DEVICE_ID|")"
  [ -z "$PHONE" ] && PHONE="x|x|x|x|paired|"
done
ok "Developer Mode is on."

# =============================================================================
step "Building Mo'Walk (this takes 1-5 minutes)"
say "Keep the iPhone plugged in and unlocked."
warn "Your Mac may pop up: ${B}'codesign wants to access key ...'${N}"
say  "     Type your ${B}Mac login password${N} and click ${B}Always Allow${N}. It may ask two or three times."
echo
if [ -n "$UDID" ]; then DEST="id=$UDID"; else DEST="generic/platform=iOS"; fi
build() {
  xcodebuild -project MoWalk.xcodeproj -scheme MoWalk -configuration Release \
    -destination "$DEST" -derivedDataPath "$HERE/build" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic \
    build > "$LOG" 2>&1 &
  local pid=$! n=0
  while kill -0 $pid 2>/dev/null; do
    n=$((n + 1)); printf "\r  building%-12s %ds " "$(printf '%*s' $((n % 10)) '' | tr ' ' '.')" $((n * 2)); sleep 2
  done
  wait $pid; local rc=$?; printf "\r%60s\r" ""; return $rc
}
while ! build; do
  bad "The build failed."
  if grep -qiE "maximum number of apps|maximum app ID|reached the maximum" "$LOG"; then
    say "Apple limits free Apple IDs to 3 of your own apps on a phone, and 10 new app ids a week."
    todo "Delete another self-installed app from the iPhone (press and hold its icon → Remove App), or wait a few days."
  elif grep -qiE "not available|cannot be registered|failed registering bundle|is not available for use" "$LOG"; then
    say "Apple won't give out the app id ${B}$BUNDLE_ID${N} (someone else has it)."
    if yesno "Pick a new random app id and try again?"; then
      BUNDLE_ID="com.mowalk.$(id -un | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z' | cut -c1-20)$(( (RANDOM % 90000) + 10000 ))"
      save BUNDLE_ID "$BUNDLE_ID"; ok "New app id: $BUNDLE_ID"; continue
    fi
  elif grep -qiE "No Account for Team|No accounts|sign in|session has expired" "$LOG"; then
    say "Xcode's Apple ID sign-in has expired or is missing."
    todo "Xcode → Settings… → Accounts: select your Apple ID; if it says to sign in, do so."
  elif grep -qiE "Developer Mode|is not available because it is unpaired|device is locked|locked" "$LOG"; then
    say "The iPhone wasn't ready."
    todo "Unlock the iPhone and keep it unlocked; check Developer Mode is on."
  elif grep -qiE "errSecInternalComponent|User interaction is not allowed|codesign" "$LOG"; then
    say "The Mac couldn't use your signing key -- usually the password pop-up was missed or cancelled."
    todo "Run it again and, when 'codesign wants to access key' appears, type your Mac password → Always Allow."
  else
    say "Here's the end of the build log (the full log is ${B}build.log${N} in this folder):"
    echo; grep -E "error:|warning: .*provision" "$LOG" | tail -8 | sed 's/^/     /'; echo
    todo "Send build.log to Warwick if this doesn't make sense."
  fi
  yesno "Try the build again?" || bye
done
APP=$(ls -d "$HERE"/build/Build/Products/Release-iphoneos/MoWalk.app 2>/dev/null | head -1)
[ -d "$APP" ] || { bad "Build said OK but I can't find the app. Send build.log to Warwick."; bye; }
ok "Built."

# =============================================================================
step "Installing on $PHONE_NAME"
say "Keep the iPhone unlocked..."
until xcrun devicectl device install app --device "$DEVICE_ID" "$APP" > "$TMP/inst.log" 2>&1; do
  bad "Installing didn't work:"; grep -iE "error|failed" "$TMP/inst.log" | head -3 | sed 's/^/     /'
  todo "Unlock the iPhone, check the cable, and make sure it still shows up (unplug/replug if needed)."
  yesno "Try installing again?" || bye
done
ok "Mo'Walk is installed on $PHONE_NAME."

# =============================================================================
step "Allowing it to open"
say "Trying to open Mo'Walk on the phone..."
until xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" > "$TMP/run.log" 2>&1; do
  if grep -qiE "untrusted|not been explicitly trusted|invalid code signature|profile" "$TMP/run.log"; then
    warn "The iPhone doesn't trust your Apple ID as an app developer yet (once only)."
    todo "On the iPhone: ${B}Settings${N} → ${B}General${N} → ${B}VPN & Device Management${N}"
    todo "Under ${B}Developer App${N} tap your Apple ID (it says 'Apple Development: …')"
    todo "Tap ${B}Trust \"Apple Development: …\"${N} → ${B}Trust${N}."
  else
    warn "It didn't open:"; grep -iE "error|reason" "$TMP/run.log" | head -3 | sed 's/^/     /'
    todo "Unlock the iPhone and try again."
  fi
  if ! yesno "Done that -- try opening it again?"; then
    say "No problem: just tap the Mo'Walk icon on the phone once you've trusted it."; break
  fi
done

# =============================================================================
step "All done"
ok "${B}Mo'Walk is on your iPhone.${N} You can unplug it now."
echo
say "The first time you use it, the iPhone will ask for permissions:"
todo "${B}Location${N}: choose ${B}Allow While Using App${N} (it records your walk and tags photos)."
todo "${B}Camera${N}, ${B}Microphone${N} (interviews) and ${B}Photos${N} (saves a copy of walk photos): Allow."
echo
say "Using it:"
todo "${B}Start walk${N} on the main screen. Take photos, interviews and notes as you go."
todo "Tap the ${B}compass${N} button (top right) to follow a route: the Mo Walk is built in,"
say  "       or load any .gpx file (from Files, or share one to Mo'Walk from WhatsApp/Mail/AirDrop)."
todo "Walks are listed at the bottom; tap one for its map, photos and a GPX to share."
if [ "$FREE_TEAM" = "1" ]; then
  echo
  warn "Free Apple ID: the app ${B}stops opening after 7 days${N}. To renew it, plug the phone in"
  say  "     and run this again (Terminal, then:  ${B}cd \"$HERE\" && bash install.sh${N})."
  say  "     It remembers your answers, so it's quick. Your walks and photos are kept."
fi
echo
