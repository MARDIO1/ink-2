"""Register unified shield soldier layers, fill occlusion masks, and refit the rig."""
from pathlib import Path
from collections import deque
import math
import re
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(r"D:\2D Admination\Finished\大盾\unified")
PARTS = ROOT / "actor/monster/imported/great_shield/assets/parts"
SCALE = 1.65


def silhouette(image):
    # Close only pixel-scale outline gaps, then fill enclosed interiors.
    alpha = image.getchannel("A")
    padded = Image.new("L", (image.width + 16, image.height + 16))
    padded.paste(alpha, (8, 8))
    closed = padded.filter(ImageFilter.MaxFilter(7)).filter(ImageFilter.MinFilter(7))
    w, h = closed.size
    solid = bytes(1 if value > 16 else 0 for value in closed.tobytes())
    outside = bytearray(w * h)
    queue = deque([0])
    outside[0] = 1
    while queue:
        i = queue.popleft()
        x, y = i % w, i // w
        for j in ([i-1] if x else []) + ([i+1] if x+1<w else []) + ([i-w] if y else []) + ([i+w] if y+1<h else []):
            if not outside[j] and not solid[j]:
                outside[j] = 1
                queue.append(j)
    mask = Image.frombytes("L", (w, h), bytes(0 if value else 255 for value in outside)).crop((8, 8, w-8, h-8))
    result = Image.new("RGBA", image.size, (255, 255, 255, 0))
    result.putalpha(mask)
    return result


def rotate(point, angle):
    x,y=point
    return (x*math.cos(angle)-y*math.sin(angle), x*math.sin(angle)+y*math.cos(angle))


def main():
    sources = sorted(SOURCE.glob("*.png"))
    body = next(p for p in sources if p.name.startswith("3a"))
    shield = next(p for p in sources if p.name.startswith("de47"))
    left_arm = next(p for p in sources if Image.open(p).size == (520,520))
    right_arm = next(p for p in sources if Image.open(p).size == (444,444) and Image.open(p).getbbox() == (168,92,276,328))
    left_leg = next(p for p in sources if Image.open(p).size == (452,452))
    right_leg = next(p for p in sources if p.stem.endswith("_2"))
    definitions = {
        "body": (body, (84,48,332,435)),
        "left_arm": (left_arm, (68,116,196,328)),
        "right_arm": (right_arm, (168,92,276,328)),
        "left_leg": (left_leg, (100,160,220,288)),
        "right_leg": (right_leg, (164,160,276,288)),
    }
    for name,(source,bounds) in definitions.items():
        image=Image.open(source).convert("RGBA").crop(bounds)
        image=image.resize(tuple(round(v*SCALE) for v in image.size),Image.Resampling.NEAREST)
        image.save(PARTS/f"{name}.png")
        silhouette(image).save(PARTS/"masks"/f"{name}_mask.png")
    Image.open(shield).convert("RGBA").crop((88,12,320,460)).save(PARTS/"shield.png")
    path=ROOT/"actor/monster/imported/great_shield/scenes/great_shield_body_rig.tscn"
    text=path.read_text(encoding="utf-8")
    # Keep the established bone angles; sprite counter-rotations preserve upright ink strokes.
    # Values are in rig coordinates, before the monster's 0.5 visual scale.
    specs={
        "BodyBone": ((0,0),-math.pi/2,(0,-199.8)),
        "LeftArm": ((210,-140),-2.7027333,(-8,114)),
        "RightArm": ((215,135),2.920764,(0,128.7)),
        "LeftLeg": ((-145,18),1.9379702,(0,100)),
        "RightLeg": ((65,18),1.3439975,(0,100)),
    }
    for bone,(pos,angle,art_delta) in specs.items():
        # Body art delta is expressed in world/rig axes; arm deltas are upright sprite axes.
        art_rotation=-angle+(math.pi/2 if bone.endswith("Arm") else 0)
        if bone=="BodyBone": art_rotation=math.pi/2
        local=rotate(art_delta,art_rotation)
        pattern=r'(\[node name="'+bone+r'"[^\n]*\]\n)(.*?)(?=\n\[|\Z)'
        def update_bone(m):
            block=m[2]
            block=re.sub(r'^position = .*$',f'position = Vector2({pos[0]}, {pos[1]})',block,flags=re.M)
            c,s=math.cos(angle),math.sin(angle)
            block=re.sub(r'^rest = .*$',f'rest = Transform2D({c:.9f}, {s:.9f}, {-s:.9f}, {c:.9f}, {pos[0]}, {pos[1]})',block,flags=re.M)
            return m[1]+block
        text=re.sub(pattern,update_bone,text,flags=re.S)
        for suffix in ["Art","OcclusionMask"]:
            name=("Body" if bone=="BodyBone" else bone)+suffix
            pat=r'(\[node name="'+name+r'"[^\n]*\]\n)(.*?)(?=\n\[|\Z)'
            def update_art(m):
                block=re.sub(r'^position = .*$',f'position = Vector2({local[0]:.6f}, {local[1]:.6f})',m[2],flags=re.M)
                block=re.sub(r'^rotation = .*$',f'rotation = {art_rotation:.9f}',block,flags=re.M)
                return m[1]+block
            text=re.sub(pat,update_art,text,flags=re.S)
    text=re.sub(r'(\[node name="PalmGrip"[^\n]*\]\n)position = .*',r'\1position = Vector2(-52.8, 141.9)',text)
    # Recenter animation translations without accumulating offsets on regeneration.
    for leg, hip in [("LeftLeg", -145), ("RightLeg", 65)]:
        pattern = r'(tracks/\d+/path = NodePath\("Skeleton2D/Root/'+leg+r':position"\).*?"values": \[)(.*?)(\])'
        def refit_track(match):
            points = re.findall(r'Vector2\((-?\d+(?:\.\d+)?), (-?\d+(?:\.\d+)?)\)', match[2])
            start_x = hip + ((-32 if hip < 0 else 32) if len(points) > 1 else 0)
            dx, dy = start_x - float(points[0][0]), 18 - float(points[0][1])
            values = ", ".join(f"Vector2({float(x)+dx:.6f}, {float(y)+dy:.6f})" for x,y in points)
            return match[1] + values + match[3]
        text = re.sub(pattern, refit_track, text, flags=re.S)
    path.write_text(text,encoding="utf-8")
    print("Rebuilt five layers, five masks, shield, shoulders, hips and grip.")

if __name__ == "__main__":
    main()
