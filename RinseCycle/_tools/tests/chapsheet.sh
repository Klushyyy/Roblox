#!/bin/bash
# usage: chapsheet.sh LC out.png t1 t2 ...   (LC = level digit + chapter digit, e.g. 11)
LC=$1; OUT=$2; shift 2
D=$(cd "$(dirname "$0")" && pwd)
cd $D
FILES=""
for T in "$@"; do
  ( R=$(timeout 300 ../tools/lune run harness.luau "chap$LC@$T" ch_${LC}_$T.json 2>&1); echo "$R" | grep -v "^CAM\|^DUR\|wrote" | head -5 >&2; CAM=$(echo "$R" | grep CAM | cut -d' ' -f2-); set -- $CAM; python3 render.py ch_${LC}_$T.json ch_${LC}_$T.png $1 $2 $3 $4 $5 $6 $7 640 360 >/dev/null ) &
  FILES="$FILES ch_${LC}_$T.png"
done
wait
python3 - $OUT $FILES <<'PY'
import sys
from PIL import Image, ImageDraw
out=sys.argv[1]; files=sys.argv[2:]
ims=[]
for f in files:
    try: ims.append((f,Image.open(f)))
    except Exception: ims.append((f,Image.new('RGB',(640,360),(255,0,0))))
cols=3; rows=(len(ims)+cols-1)//cols
sheet=Image.new('RGB',(640*cols,360*rows))
for i,(f,im) in enumerate(ims):
    sheet.paste(im,((i%cols)*640,(i//cols)*360))
    ImageDraw.Draw(sheet).text(((i%cols)*640+6,(i//cols)*360+6),f.split('_')[-1][:-4],fill=(255,255,0))
sheet.save(out)
PY
