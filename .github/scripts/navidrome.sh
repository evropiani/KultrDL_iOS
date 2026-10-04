#!/bin/bash
# A throwaway Navidrome on the runner for the live check: the macOS build
# from its latest release, five short tagged songs, an admin account
# (admin / kultr-pass) and a normal one that has played them (listener /
# listen-pass), as people listen. Prints the address for KULTRDL_NAVIDROME,
# or nothing when it couldn't be started (the probe then skips its checks).
set -u
dir="${RUNNER_TEMP:-/tmp}/navidrome"
mkdir -p "$dir/music" "$dir/data"
auth=()
[ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
asset=$(curl -fsSL --max-time 30 "${auth[@]}" https://api.github.com/repos/navidrome/navidrome/releases/latest |
  python3 -c 'import sys, json; print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith("_darwin_arm64.tar.gz")))') || exit 0
echo "Navidrome: $asset" >&2
curl -fsSL --max-time 180 "$asset" | tar -xz -C "$dir" || exit 0
[ -x "$dir/navidrome" ] || exit 0

pip3 install --quiet --break-system-packages mutagen 2>/dev/null || pip3 install --quiet mutagen 2>/dev/null || true
python3 - "$dir/music" >&2 <<'PY'
import math, os, struct, subprocess, sys, wave
from mutagen.mp4 import MP4
root = sys.argv[1]
songs = [
    ("Daft Punk", "Discovery", "One More Time", 1),
    ("Daft Punk", "Discovery", "Aerodynamic", 2),
    ("Massive Attack", "Mezzanine", "Teardrop", 3),
    ("Air", "Moon Safari", "Sexy Boy", 2),
    ("Portishead", "Dummy", "Roads", 5),
]
for artist, album, title, track in songs:
    folder = os.path.join(root, artist, album)
    os.makedirs(folder, exist_ok=True)
    wav = os.path.join(folder, title + ".wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
        w.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / 22050))) for i in range(22050 * 35)))
    m4a = os.path.join(folder, title + ".m4a")
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", wav, m4a], check=True)
    os.remove(wav)
    tags = MP4(m4a)
    tags["\xa9ART"] = [artist]; tags["aART"] = [artist]; tags["\xa9alb"] = [album]
    tags["\xa9nam"] = [title]; tags["\xa9gen"] = ["Electronic"]; tags["trkn"] = [(track, 0)]
    tags.save()
    print("song", m4a)
PY

cd "$dir"
ND_MUSICFOLDER="$dir/music" ND_DATAFOLDER="$dir/data" ND_PORT=4533 ND_ADDRESS=127.0.0.1 \
  ND_DEVAUTOCREATEADMINPASSWORD=kultr-pass ND_SCANNER_SCHEDULE=1m ND_LOGLEVEL=info \
  nohup ./navidrome > "$dir/navidrome.log" 2>&1 &
api="http://127.0.0.1:4533/rest"
n=0
for _ in $(seq 1 60); do
  n=$(curl -s --max-time 5 "$api/search3.view?u=admin&p=kultr-pass&v=1.16.1&c=ci&f=json&query=&songCount=50" |
    python3 -c 'import sys, json; print(len(json.load(sys.stdin)["subsonic-response"].get("searchResult3", {}).get("song", [])))' 2>/dev/null || echo 0)
  [ "$n" -ge 5 ] && break
  sleep 3
done
echo "Navidrome has $n songs" >&2

# A normal account to listen with: the plays go to it, not to the admin.
if [ "$n" -ge 1 ]; then
  token=$(curl -s --max-time 10 -H 'Content-Type: application/json' -d '{"username":"admin","password":"kultr-pass"}' \
    http://127.0.0.1:4533/auth/login | python3 -c 'import sys, json; print(json.load(sys.stdin)["token"])' 2>/dev/null || true)
  created=$(curl -s --max-time 10 -H 'Content-Type: application/json' -H "x-nd-authorization: Bearer $token" \
    -d '{"userName":"listener","name":"Listener","password":"listen-pass","isAdmin":false}' http://127.0.0.1:4533/api/user || true)
  echo "Created: $created" >&2
  user_id=$(echo "$created" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)
  listener="u=listener&p=listen-pass&v=1.16.1&c=ci&f=json"
  listed() { curl -s --max-time 10 "$api/search3.view?$listener&query=&songCount=50" |
    python3 -c 'import sys, json; print(" ".join(s["id"] for s in json.load(sys.stdin)["subsonic-response"].get("searchResult3", {}).get("song", [])))' 2>/dev/null || true; }
  if [ -z "$(listed)" ] && [ -n "$user_id" ]; then
    # Navidrome with several libraries gives new users none until they're added.
    curl -s --max-time 10 -X PUT -H 'Content-Type: application/json' -H "x-nd-authorization: Bearer $token" \
      -d '{"libraryIds":[1]}' "http://127.0.0.1:4533/api/user/$user_id/library" >&2 || true
  fi
  ids=$(listed)
  echo "listener sees $(echo $ids | wc -w | tr -d ' ') songs" >&2
  for id in $(echo $ids | cut -d' ' -f1-3); do
    for _ in 1 2 3; do curl -s --max-time 10 "$api/scrobble.view?$listener&id=$id&submission=true" >/dev/null || true; done
  done
fi
if [ "$n" -ge 1 ]; then echo "http://127.0.0.1:4533"; else tail -20 "$dir/navidrome.log" >&2; fi
