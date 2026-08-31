#!/usr/bin/env bash
# Simple migration helper: create slug copies and optionally update frontmatter.
# Usage: ./scripts/migrate-images.sh [--apply] [--apply-frontmatter]
#   --apply             : copy slugged image files into place
#   --apply-frontmatter : update QMD frontmatter `image:` values to the slug (creates .bak backups)

set -euo pipefail
ROOT="$(pwd)"
MEDIA_DIR="_quarto-utils/MyMedia/images/optimized"
APPLY=false
APPLY_FRONT=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --apply-frontmatter) APPLY_FRONT=true ;;
  esac
done
mkdir -p "$MEDIA_DIR"

echo "Scanning optimized images in $MEDIA_DIR..."
find "$MEDIA_DIR" -maxdepth 1 -type f \( -iname "*.webp" -o -iname "*.png" -o -iname "*.jpg" \) | while read -r f; do
  base=$(basename "$f")
  # attempt to detect keyword like 'docker' in filename
  slug=$(echo "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-[0-9]\{3,4\}.*$//' )
  slug_file="$MEDIA_DIR/${slug}-400.webp"
  if [ "$f" != "$slug_file" ]; then
    echo "Found $base -> suggest $slug-400.webp"
    if $APPLY; then
      cp -n "$f" "$slug_file" && echo "Copied $f -> $slug_file"
    fi
  fi
done

echo "To apply file copies, run: $0 --apply"
echo "To also update QMD frontmatter to slug names, run: $0 --apply-frontmatter (creates .bak backups)"

if [ "$APPLY_FRONT" = true ]; then
  echo "\nUpdating QMD frontmatter to slugs..."
  python3 - <<'PY'
import os,sys,re,json
root=os.getcwd()
media_dir=os.path.join(root,'_quarto-utils','MyMedia','images','optimized')
def slug_from_path(path):
    base=os.path.basename(path)
    s=re.sub('[^A-Za-z0-9]+','-',base).lower()
    s=re.sub('-[0-9]{3,4}.*$','',s)
    s=re.sub('(^-+|-+$)','',s)
    return s

manifest_path=os.path.join(root,'_quarto-utils','image-manifest.json')
manifest = {}
if os.path.exists(manifest_path):
    try:
        manifest = json.load(open(manifest_path,'r',encoding='utf-8'))
    except Exception:
        manifest = {}

for dirpath,_,files in os.walk(os.path.join(root,'Content')):
    for fname in files:
        if not fname.endswith('.qmd'): continue
        fpath=os.path.join(dirpath,fname)
        with open(fpath,'r',encoding='utf-8') as f:
            txt=f.read()
        if not txt.startswith('---'):
            continue
        parts=txt.split('\n---\n',2)
        if len(parts)<2:
            continue
        fm=parts[0] + '\n---\n'
        body = parts[1] if len(parts)==2 else parts[2]
        m=re.search(r'^image:\s*(.+)$',fm,flags=re.M)
        if not m: continue
        val=m.group(1).strip().strip('"').strip("'")
        # already a slug? skip
        if '/' not in val and not re.search(r'\.[a-zA-Z]{2,4}$',val):
            continue
        slug=slug_from_path(val)
        candidates=[os.path.join(media_dir,slug+'-400.webp'), os.path.join(media_dir,slug+'.webp'), os.path.join(media_dir,slug+'-800.webp')]
        found=None
        for c in candidates:
            if os.path.exists(c):
                found=c
                break
        if not found and slug in manifest and '400' in manifest[slug]:
            cand=os.path.join(media_dir,manifest[slug]['400'])
            if os.path.exists(cand):
                found=cand
        if found:
            print(f"Will update {fpath}: {val} -> {slug}")
            bak=fpath+'.bak'
            if not os.path.exists(bak):
                open(bak,'w',encoding='utf-8').write(txt)
            new_fm = re.sub(r'^(image:\s*).+$', r"\1"+slug, fm, flags=re.M)
            new_txt = new_fm + '\n---\n' + body if len(parts)==3 else new_fm
            with open(fpath,'w',encoding='utf-8') as f:
                f.write(new_txt)
        else:
            print(f"No candidate for {fpath} (would map to {slug})")
PY
fi
