#!/bin/zsh
# Game Tools views read GameToolsCapabilities and never ask which engine a game uses: no EngineFamily cases and no
# engine names in App/Sources/GameTools. The decision lives in GameTools' GameToolsCapabilityResolver.
cd "$(dirname "$0")/.."
bad=$(grep -rnE 'EngineFamily\.|\.(rpgMaker(MV|MZ|XP|VX|VXAce|2000|2003)|renpy|scummvm|godot|kirikiri|tyrano)\b' App/Sources/GameTools 2>/dev/null)
[[ -z "$bad" ]] && exit 0
echo "$bad" | while IFS=: read -r file line rest; do echo "$file:$line: error: Game Tools views must use GameToolsCapabilities, not engine checks"; done
exit 1
