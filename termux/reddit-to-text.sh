#!/data/data/com.termux/files/usr/bin/bash
# reddit-to-text.sh - Save Reddit threads / user pages as readable .txt files.
#
# Setup (once, in Termux):
#   pkg install curl jq
#   termux-setup-storage        # optional: lets output go to phone's Download folder
#
# Usage:
#   bash reddit-to-text.sh                 # uses the built-in URL list below
#   bash reddit-to-text.sh urls.txt        # one URL per line
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
mkdir -p "$OUT"

UA="Mozilla/5.0 (Linux; Android 14) termux-reddit-to-text/1.0"

# jq program: turns Reddit's JSON into indented plain text.
read -r -d '' JQ <<'EOF'
def ind($d): [range($d)] | map("    ") | join("");
def when: (.created_utc // 0 | floor | strftime("%Y-%m-%d %H:%M UTC"));
def para($p): (. // "") | split("\n") | map($p + .) | .[];

def comment($d):
  if .kind == "t1" then
    .data as $c
    | (ind($d) + "+ u/" + ($c.author // "[deleted]") + "  |  "
        + (($c.score // 0) | tostring) + " pts  |  " + ($c | when)),
      ($c.body | para(ind($d) + "| ")),
      "",
      (if ($c.replies | type) == "object"
         then $c.replies.data.children[] | comment($d + 1)
         else empty end)
  elif .kind == "more" and (.data.count // 0) > 0 then
    ind($d) + "[" + (.data.count | tostring) + " more replies not loaded]", ""
  else empty end;

def post:
  ("TITLE:   " + .title),
  ("SUB:     r/" + .subreddit),
  ("AUTHOR:  u/" + (.author // "[deleted]")),
  ("POSTED:  " + when),
  ("SCORE:   " + (.score | tostring) + "   COMMENTS: " + (.num_comments | tostring)),
  ("URL:     https://www.reddit.com" + .permalink),
  (if (.is_self | not) and .url then "LINK:    " + .url else empty end),
  "",
  (if (.selftext // "") != "" then .selftext | para("") else empty end);

if type == "array" then
  # Thread page: [post listing, comment listing]
  (.[0].data.children[0].data | post),
  "", ("=" * 70), "COMMENTS", ("=" * 70), "",
  (.[1].data.children[] | comment(0))
else
  # User page: mixed listing of posts (t3) and comments (t1)
  .data.children[] |
  (if .kind == "t3" then
     ("#" * 70), "[POST]", (.data | post)
   else
     .data as $c
     | ("#" * 70),
       "[COMMENT] in r/" + $c.subreddit + " on: " + ($c.link_title // ""),
       "POSTED:  " + ($c | when) + "   SCORE: " + (($c.score // 0) | tostring),
       "URL:     https://www.reddit.com" + $c.permalink,
       "",
       ($c.body | para(""))
   end), ""
end
EOF

ok=0; fail=0
for url in "${URLS[@]}"; do
  url="${url%%\?*}"; url="${url%/}"
  # File name: sub_id_slug.txt  or  user_NAME.txt
  name=$(echo "$url" | sed -E \
    -e 's#.*/r/([^/]+)/comments/([^/]+)/?([^/]*).*#\1_\2_\3#' \
    -e 's#.*/(user|u)/([^/]+).*#user_\2#')
  file="$OUT/${name%_}.txt"
  path="${url#*reddit.com}"
  echo "-> $path"

  json=""
  for host in www.reddit.com old.reddit.com; do
    json=$(curl -sSL --compressed -A "$UA" --retry 2 --retry-delay 5 \
      "https://$host$path/.json?raw_json=1&limit=500") && echo "$json" | jq -e . >/dev/null 2>&1 && break
    json=""
    sleep 3
  done

  if [ -z "$json" ]; then
    echo "   FAILED (blocked or rate-limited - try again later or on mobile data)"
    fail=$((fail+1))
  elif echo "$json" | jq -r "$JQ" > "$file" 2>/dev/null; then
    echo "   saved $file"
    ok=$((ok+1))
  else
    echo "   FAILED to parse"
    rm -f "$file"; fail=$((fail+1))
  fi
  sleep 2   # be polite, avoid Reddit rate limits
done

echo
echo "Done: $ok saved, $fail failed. Files in: $OUT"
