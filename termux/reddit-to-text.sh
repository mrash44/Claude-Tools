#!/data/data/com.termux/files/usr/bin/bash
# reddit-to-text.sh - Save Reddit threads / user pages as readable .txt files.
#
# Reddit now blocks unauthenticated downloads, so this pulls the same posts and
# comments from the Arctic Shift archive (free, no key). Very new comments can
# be missing for a day or two.
#
# Setup (once, in Termux):
#   pkg install curl jq
#   termux-setup-storage        # optional: lets output go to phone's Download folder
#
# Usage:
#   bash reddit-to-text.sh                 # download the built-in URL list below
#   bash reddit-to-text.sh --check         # only report which threads the archive has
#   bash reddit-to-text.sh urls.txt        # one URL per line (works with --check too)
#   OUT=~/mydir bash reddit-to-text.sh     # custom output folder

set -u

URLS=(
https://www.reddit.com/r/ausadhd/comments/100vqlo/someonehealth_psychology/
https://www.reddit.com/r/ausadhd/comments/13bhqcj/someonehealth/
https://www.reddit.com/r/AUfrugal/comments/1x8lsum/10_free_psychologist_appointments_each_year/
https://www.reddit.com/r/AussieFrugal/comments/1x8lbor/10_free_telehealth_psychologist_appointments_per/
https://www.reddit.com/r/AussieFrugal/comments/1g8huko/how_to_get_therapy/
https://www.reddit.com/r/AussieMentalHealth/comments/1u2p6wx/how_telehealth_psychology_actually_works_in/
https://www.reddit.com/r/australian/comments/1v1euso/mental_health_support_systems_in_australia_are/
https://www.reddit.com/r/australia/comments/1wuygsj/how_is_this_possible/
https://www.reddit.com/r/centralcoastnsw/comments/1ujnf9o/bulk_billing_psychologist/
https://www.reddit.com/r/AskAnAustralian/comments/18sevqv/anybody_know_any_good_online_mental_health/
https://www.reddit.com/r/melbourne/comments/10n4dx6/affordable_or_bulk_billed_psychologists/
https://www.reddit.com/r/melbourne/comments/1rrchh9/affordable_psychologists_in_melbourne/
https://www.reddit.com/r/melbourne/comments/1w0bgvd/the_mental_health_system_is_an_absolute_joke/
https://www.reddit.com/r/AussieMentalHealth/comments/1lk2seq/australia_mental_health_care_sucks/
https://www.reddit.com/r/AussieMentalHealth/comments/1lgvibu/any_online_therapy_choices_to_speak_to_someone/
https://www.reddit.com/r/vic/comments/1q9mv9r/for_rural_victorians_have_you_ever_accessed/
https://www.reddit.com/r/melbourne/comments/1x5gftg/guide_to_what_actually_happens_in_melbournes/
https://www.reddit.com/user/SomeoneHealth/
)

CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
if [ $# -ge 1 ]; then
  mapfile -t URLS < <(grep -E '^https?://' "$1")
fi

for dep in curl jq; do
  command -v "$dep" >/dev/null || { echo "Missing $dep - run: pkg install curl jq"; exit 1; }
done

if [ -z "${OUT:-}" ]; then
  if [ -d "$HOME/storage/downloads" ]; then OUT="$HOME/storage/downloads/reddit"
  else OUT="$HOME/reddit"; fi
fi
[ $CHECK = 1 ] || mkdir -p "$OUT"

API="${API:-https://arctic-shift.photon-reddit.com/api}"
UA="termux-reddit-to-text/2.0"

# GET an API path; prints JSON, fails on HTTP/API errors.
get() {
  local body
  body=$(curl -sSL --compressed -A "$UA" --retry 3 --retry-delay 5 -f "$API/$1") || return 1
  echo "$body" | jq -e 'has("data") and (.data != null)' >/dev/null 2>&1 || return 1
  echo "$body"
}

# Fetch every result of a search endpoint (100 per page, oldest first),
# printed as one JSON array.
get_all() {
  local q="$1" after=0 page last pages=()
  while :; do
    page=$(get "$q&limit=100&sort=asc&after=$after") || return 1
    pages+=("$page")
    [ "$(echo "$page" | jq '.data | length')" -lt 100 ] && break
    last=$(echo "$page" | jq '.data[-1].created_utc | floor')
    # Back up one second so items sharing the last timestamp aren't lost.
    [ "$last" -le "$after" ] && break
    after=$((last - 1))
    sleep 1
  done
  printf '%s\n' "${pages[@]}" | jq -s '[.[].data[]] | unique_by(.id) | sort_by(.created_utc)'
}

read -r -d '' COMMON <<'EOF'
def ind($d): [range($d)] | map("    ") | join("");
def when: (.created_utc // 0 | floor | strftime("%Y-%m-%d %H:%M UTC"));
def para($p): (. // "") | split("\n") | map($p + .) | .[];
def post:
  ("TITLE:   " + .title),
  ("SUB:     r/" + .subreddit),
  ("AUTHOR:  u/" + (.author // "[deleted]")),
  ("POSTED:  " + when),
  ("SCORE:   " + ((.score // 0) | tostring) + "   COMMENTS: " + ((.num_comments // 0) | tostring)),
  ("URL:     https://www.reddit.com" + .permalink),
  (if (.is_self | not) and .url then "LINK:    " + .url else empty end),
  "",
  (if (.selftext // "") != "" then .selftext | para("") else empty end);
EOF

# Thread: $post = post object, input = flat array of comments. Rebuilds the reply tree.
read -r -d '' THREAD <<'EOF'
($c | map({key: .id, value: true}) | from_entries) as $have
| ($c | group_by(.parent_id) | map({key: .[0].parent_id, value: .}) | from_entries) as $kids
| def tree($id; $d):
    ($kids[$id] // [])[] |
    (ind($d) + "+ u/" + (.author // "[deleted]") + "  |  "
       + ((.score // 0) | tostring) + " pts  |  " + when),
    (.body | para(ind($d) + "| ")),
    "",
    tree("t1_" + .id; $d + 1);
  ($post | post),
  "", ("=" * 70), "COMMENTS (" + ($c | length | tostring) + " archived)", ("=" * 70), "",
  tree("t3_" + $post.id; 0),
  # Replies whose parent comment isn't in the archive
  ($c[] | select((.parent_id | startswith("t1_")) and ($have[.parent_id[3:]] | not))
   | "[reply to a comment missing from the archive]",
     ("+ u/" + (.author // "[deleted]") + "  |  " + ((.score // 0) | tostring) + " pts  |  " + when),
     (.body | para("| ")), "", tree("t1_" + .id; 1))
EOF

# User page: input = merged array of posts and comments, newest first.
read -r -d '' USER <<'EOF'
sort_by(-.created_utc)[] |
("#" * 70),
(if has("title") then "[POST]", post
 else
   "[COMMENT] in r/" + .subreddit + "   POSTED: " + when + "   SCORE: " + ((.score // 0) | tostring),
   "URL:     https://www.reddit.com" + (.permalink // ("/comments/" + (.link_id[3:]) + "/_/" + .id)),
   "",
   (.body | para(""))
 end), ""
EOF

ok=0; fail=0
for url in "${URLS[@]}"; do
  url="${url%%\?*}"; url="${url%/}"
  if [[ "$url" =~ /comments/([a-z0-9]+)(/([^/]*))? ]]; then
    id="${BASH_REMATCH[1]}"; slug="${BASH_REMATCH[3]}"
    sub=$(echo "$url" | sed -E 's#.*/r/([^/]+)/.*#\1#')
    file="$OUT/${sub}_${id}${slug:+_$slug}.txt"
    echo "-> r/$sub $id"

    post=$(get "posts/ids?ids=$id" | jq -c '.data[0] // empty')
    if [ -z "$post" ]; then
      echo "   NOT IN ARCHIVE (or archive unreachable)"; fail=$((fail+1)); continue
    fi
    if [ $CHECK = 1 ]; then
      echo "   OK: $(echo "$post" | jq -r '"\(.num_comments // 0) comments - \(.title)"')"
      ok=$((ok+1)); sleep 1; continue
    fi
    comments=$(get_all "comments/search?link_id=$id") || { echo "   FAILED fetching comments"; fail=$((fail+1)); continue; }
    if echo "$comments" | jq -r --argjson post "$post" "$COMMON . as \$c | $THREAD" > "$file"; then
      echo "   saved $file ($(echo "$comments" | jq length) comments)"; ok=$((ok+1))
    else
      echo "   FAILED to format"; rm -f "$file"; fail=$((fail+1))
    fi

  elif [[ "$url" =~ /(user|u)/([^/]+) ]]; then
    user="${BASH_REMATCH[2]}"
    file="$OUT/user_${user}.txt"
    echo "-> u/$user"
    posts=$(get_all "posts/search?author=$user") && comments=$(get_all "comments/search?author=$user")
    if [ $? -ne 0 ]; then
      echo "   NOT IN ARCHIVE (or archive unreachable)"; fail=$((fail+1)); continue
    fi
    np=$(echo "$posts" | jq length); nc=$(echo "$comments" | jq length)
    if [ $CHECK = 1 ]; then
      echo "   OK: $np posts, $nc comments"; ok=$((ok+1)); continue
    fi
    if jq -rs "$COMMON .[0] + .[1] | $USER" <(echo "$posts") <(echo "$comments") > "$file"; then
      echo "   saved $file ($np posts, $nc comments)"; ok=$((ok+1))
    else
      echo "   FAILED to format"; rm -f "$file"; fail=$((fail+1))
    fi

  else
    echo "-> skipping unrecognised URL: $url"
    continue
  fi
  sleep 1   # be polite to the volunteer-run archive
done

echo
if [ $CHECK = 1 ]; then echo "Check done: $ok available, $fail missing."
else echo "Done: $ok saved, $fail failed. Files in: $OUT"; fi
