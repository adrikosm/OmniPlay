#!/bin/zsh
# Keeps the history single-author. Every commit is authored, committed and GPG-signed by the owner
# pinned in this clone's .git/config (user.name, user.email, user.signingkey; never committed), and no
# message carries co-author trailers or AI attribution. Agents never bypass it with --no-verify.
#   check-authorship.sh commit MSGFILE   commit-msg hook: identity and message
#   check-authorship.sh push REMOTE      pre-push hook: every outgoing commit, including its signature
set -uo pipefail
cfg="$(git rev-parse --git-common-dir)/config"
name=$(git config --file "$cfg" user.name) email=$(git config --file "$cfg" user.email)
key=$(git config --file "$cfg" user.signingkey)
if [[ -z $name || -z $email || -z $key ]]; then
  echo "check-authorship: pin user.name, user.email and user.signingkey with git config --local" >&2
  exit 1
fi
owner="$name <$email>"
bad=()

# Reads a commit message on stdin; $1 labels the findings.
check_message() {
  local msg line
  msg=$(sed '/^# -* >8 -*$/,$d' | grep -v '^#')
  print -r -- "$msg" | grep -Ei '^[a-z-]+-by:' | grep -vFx "Signed-off-by: $owner" | while IFS= read -r line; do
    bad+=("$1: foreign trailer '$line'")
  done
  print -r -- "$msg" | grep -Ei 'claude|anthropic|chatgpt|openai|copilot|generated (with|by)' | while IFS= read -r line; do
    bad+=("$1: AI attribution '$line'")
  done
}

case ${1:-} in
  commit)
    for who in AUTHOR COMMITTER; do
      id=$(git var GIT_${who}_IDENT | sed -E 's/ [0-9]+ [-+][0-9]{4}$//')
      [[ $id == "$owner" ]] || bad+=("${(L)who} is '$id', expected '$owner'")
    done
    check_message message < "$2"
    ;;
  push)
    while read -r _ lsha _ rsha; do
      [[ $lsha =~ '^0+$' ]] && continue
      if [[ $rsha =~ '^0+$' ]]; then range=("$lsha" --not "--remotes=$2"); else range=("$rsha..$lsha"); fi
      for c in $(git rev-list "${range[@]}"); do
        s=${c[1,8]}
        [[ $(git log -1 --format='%an <%ae>' "$c") == "$owner" ]] || bad+=("$s: author is not '$owner'")
        [[ $(git log -1 --format='%cn <%ce>' "$c") == "$owner" ]] || bad+=("$s: committer is not '$owner'")
        sig=(${=$(git log -1 --format='%G? %GK' "$c")})
        if [[ ${sig[1]} != [GU] || -z ${sig[2]:-} || ${key:u} != *${sig[2]:u} ]]; then
          bad+=("$s: not signed with $key (re-sign it before pushing)")
        fi
        git log -1 --format=%B "$c" | check_message "$s"
      done
    done
    ;;
  *) echo "usage: check-authorship.sh commit MSGFILE | push REMOTE" >&2; exit 2 ;;
esac

if (( ${#bad} )); then
  echo "check-authorship: refusing" >&2
  printf '  %s\n' "${bad[@]}" >&2
  exit 1
fi
