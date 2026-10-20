#!/bin/sh
# Renders the PNGs that come from the SVG masters in this folder:
# the app icon set, the site's apple-touch-icon and the social preview.
# Needs Google Chrome; sips ships with macOS.
set -eu

cd "$(dirname "$0")"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# render <html file> <width> <height> <out.png>
render() {
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size="$2,$3" \
    --screenshot="$4" "file://$1" >/dev/null 2>&1
}

# master <svg> <out.png>: the SVG at 1024 px, transparent around it.
master() {
  printf '<style>html,body{margin:0;background:transparent}</style><img src="file://%s" width="1024" height="1024" style="display:block">' \
    "$PWD/$1" > "$work/page.html"
  render "$work/page.html" 1024 1024 "$2"
}

master icon-light.svg "$work/large.png"
master icon-small-light.svg "$work/small.png"

# macOS icon set. At 32 px and below the small master is used.
set_dir=../App/Assets.xcassets/AppIcon.appiconset
size() { sips -z "$2" "$2" "$work/$1.png" --out "$set_dir/$3" >/dev/null; }
size small 16 icon_16x16.png
size small 32 icon_16x16@2x.png
size small 32 icon_32x32.png
size large 64 icon_32x32@2x.png
size large 128 icon_128x128.png
size large 256 icon_128x128@2x.png
size large 256 icon_256x256.png
size large 512 icon_256x256@2x.png
size large 512 icon_512x512.png
cp "$work/large.png" "$set_dir/icon_512x512@2x.png"

# iOS rounds the corners itself and fills transparency with black, so the
# touch icon is the body alone, square and without the drop shadow.
sed -e 's/viewBox="0 0 1024 1024"/viewBox="100 100 824 824"/' -e 's/ rx="185"//' -e 's/ filter="url(#sh)"//' \
  icon-light.svg > "$work/square.svg"
printf '<style>html,body{margin:0}</style><img src="file://%s" width="1024" height="1024" style="display:block">' \
  "$work/square.svg" > "$work/page.html"
render "$work/page.html" 1024 1024 "$work/square.png"
sips -z 180 180 "$work/square.png" --out ../site/public/apple-touch-icon.png >/dev/null

render "$PWD/og.html" 1280 640 ../site/public/og.png

# The site shows the icon at 32 px and below, so it only needs the small master.
cp icon-small-light.svg ../site/public/favicon.svg
cp icon-small-light.svg ../site/public/icon-light.svg
cp icon-small-dark.svg ../site/public/icon-dark.svg
echo "Rendered."
