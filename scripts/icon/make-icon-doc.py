import json, os, sys

out = sys.argv[1]
concept = sys.argv[2] if len(sys.argv) > 2 else "wave"
os.makedirs(f"{out}/Assets", exist_ok=True)
for f in os.listdir(f"{out}/Assets"):
    os.remove(f"{out}/Assets/{f}")


def p3(hexstr):
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"display-p3:{r:.4f},{g:.4f},{b:.4f},1.0"


BG = [p3("#4B4E52"), p3("#1C1E20")]
INK = p3("#CDD1A6")
INK2 = p3("#868C5E")


def svg(name, body):
    with open(f"{out}/Assets/{name}", "w") as f:
        f.write('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
                f'<g fill="#FFFFFF">{body}</g></svg>')


def bar(cx, h, w=100):
    return f'<rect x="{cx - w / 2}" y="{512 - h / 2}" width="{w}" height="{h}" rx="{w / 2}" ry="{w / 2}"/>'


def group(name, ink):
    return {
        "layers": [{"image-name": f"{name}.svg", "name": name, "glass": True, "fill": {"solid": ink}}],
        "shadow": {"kind": "neutral", "opacity": 0.5},
        "translucency": {"enabled": True, "value": 0.25},
        "specular": True,
    }


if concept == "mic":
    svg("capsule.svg", '<rect x="392" y="196" width="240" height="420" rx="120" ry="120"/>')
    svg("stand.svg", '<path d="M300,500 A212,212 0 0 0 724,500" fill="none" stroke="#FFFFFF" stroke-width="56" stroke-linecap="round"/>'
                     '<rect x="484" y="700" width="56" height="110" rx="28"/><rect x="380" y="784" width="264" height="56" rx="28"/>')
    groups = [group("capsule", INK), group("stand", INK2)]
else:
    xs = [272, 392, 512, 632, 752]
    hs = [220, 420, 572, 382, 258]
    svg("front.svg", "".join(bar(x, h) for i, (x, h) in enumerate(zip(xs, hs)) if i % 2 == 0))
    svg("back.svg", "".join(bar(x, h) for i, (x, h) in enumerate(zip(xs, hs)) if i % 2 == 1))
    groups = [group("front", INK), group("back", INK2)]

doc = {
    "fill": {"linear-gradient": BG},
    "groups": groups,
    "supported-platforms": {"squares": ["macOS"]},
}
with open(f"{out}/icon.json", "w") as f:
    json.dump(doc, f, indent=2)
print(out)
