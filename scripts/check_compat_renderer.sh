#!/usr/bin/env bash
# The Compatibility (OpenGL 3) renderer: what older laptops and VMs without
# Vulkan / D3D12 / Metal get (project.godot sets
# rendering/rendering_device/fallback_to_opengl3). Runs boot_test, quiz_test
# and tutorial_test with a display (Xvfb) in gl_compatibility, then renders
# the "3D Scenes" cards with tests/scene3d_snapshots.gd and checks a card's
# own 3D view is not a single colour. Fails on a failing test, any
# "SCRIPT ERROR" or "ERROR" line (leaked GL textures included), or a blank card.
#   GODOT=/path/to/godot scripts/check_compat_renderer.sh [out_dir]
# Needs xvfb-run (Debian/Ubuntu: apt install xvfb). Godot runs with a
# throwaway HOME and XDG dirs, so your vault and settings are never touched,
# and the 3D showcase goes into a vault in that HOME by --vault=, so it does
# even under a GODOT wrapper that sets HOME and XDG dirs of its own.
# Logs and PNGs land in out_dir (default: a new temp dir, printed at the end).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
godot="${GODOT:-godot}"
limit="${TIMEOUT:-240}"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/config" XDG_DATA_HOME="$sandbox/data" XDG_CACHE_HOME="$sandbox/cache"
mkdir -p "$HOME/Documents" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
echo "XDG_DOCUMENTS_DIR=\"$HOME/Documents\"" > "$XDG_CONFIG_HOME/user-dirs.dirs"
# The vault every run below opens (the app's autoloads open one even for a
# -s script): the showcase is seeded into it and drawn from it. Named
# outright: a GODOT wrapper that exports HOME and XDG dirs of its own (a
# sandbox of its own) would otherwise get it as its default vault, seeded
# with the starter notes, and keep it.
vault="$HOME/Documents/Ontomeme"

if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run not found (apt install xvfb)"; exit 2
fi
xvfb=(xvfb-run -a -s "-screen 0 1280x1024x24")
compat=(--rendering-driver opengl3 --rendering-method gl_compatibility)
failed=()

# Errors in a log: script errors and every engine ERROR line (leaks included).
errors_in() {
  grep -E 'SCRIPT ERROR|Parse Error|^ERROR|leaked' "$1"
}

# check <name> <exit code> <log> [needs "RESULT: ALL PASS"]
check() {
  local name="$1" code="$2" log="$3" want_result="${4:-yes}"
  local bad
  bad="$(errors_in "$log")"
  if [ "$code" -eq 0 ] && [ -z "$bad" ] && { [ "$want_result" != yes ] || grep -q 'RESULT: ALL PASS' "$log"; }; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (exit $code)"
    { grep -E '^FAIL ' "$log"; echo "$bad"; } | grep -v '^$' | head -20 | sed 's/^/      /'
    failed+=("$name")
  fi
}

"$godot" --headless --path . --import >/dev/null 2>&1 || true

# The app's own tests, drawn by the OpenGL renderer
for t in boot_test quiz_test tutorial_test; do
  log="$out/$t.log"
  timeout "$limit" "${xvfb[@]}" "$godot" --path . "${compat[@]}" -s "res://tests/$t.gd" >"$log" 2>&1
  check "$t (gl_compatibility)" $? "$log"
done

# The 3D showcase: seed it into the throwaway vault, then render every card
log="$out/seed_3d_demo.log"
timeout "$limit" "$godot" --headless --path . -s res://tests/seed_3d_demo.gd -- --vault="$vault" >"$log" 2>&1
check "seed the 3D Scenes note" $? "$log" no
log="$out/scene3d_snapshots.log"
timeout "$limit" "${xvfb[@]}" "$godot" --path . "${compat[@]}" -s res://tests/scene3d_snapshots.gd -- "$out" --vault="$vault" >"$log" 2>&1
check "scene3d_snapshots (gl_compatibility)" $? "$log" no

# A rendered card is not a single colour: luminance spread over its pixels
cat >"$sandbox/pixel_spread.gd" <<'GD'
extends SceneTree
func _init() -> void:
	var path: String = OS.get_cmdline_user_args()[0]
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		print("no image: ", path)
		quit(1)
		return
	var n: int = 0
	var lo: float = 1.0
	var hi: float = 0.0
	var sum: float = 0.0
	var sum2: float = 0.0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var l: float = img.get_pixel(x, y).get_luminance()
			lo = minf(lo, l)
			hi = maxf(hi, l)
			sum += l
			sum2 += l * l
			n += 1
	var mean: float = sum / n
	var stddev: float = sqrt(maxf(sum2 / n - mean * mean, 0.0))
	print("%s: %dx%d  luminance %.3f-%.3f  mean %.3f  stddev %.4f" % [path.get_file(), img.get_width(), img.get_height(), lo, hi, mean, stddev])
	quit(0 if stddev > 0.01 and hi - lo > 0.1 else 1)
GD
card="$out/card_galaxy.png"
if [ -f "$card" ]; then
  spread="$("$godot" --headless --path . -s "$sandbox/pixel_spread.gd" -- "$card" --vault="$vault" 2>&1)"
  code=$?
  echo "$spread" | grep -E 'luminance|no image|ERROR' | sed 's/^/      /'
  if [ $code -eq 0 ]; then
    echo "PASS  the galaxy card's 3D view is not a single colour"
  else
    echo "FAIL  the galaxy card's 3D view is (nearly) a single colour"
    failed+=("card pixels")
  fi
else
  echo "FAIL  no 3D card snapshot ($card)"
  failed+=("card snapshot")
fi

echo
echo "logs and snapshots: $out"
if [ ${#failed[@]} -eq 0 ]; then echo "COMPAT RENDERER OK"; else echo "FAILED: ${failed[*]}"; exit 1; fi
