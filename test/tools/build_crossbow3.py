"""Generate blueprints/弩箭3.inkbp: long bell-crank cocking lever + spring crossbow."""
import json
import math
import os

W, H = 480, 260
BLACK, GREY, YELLOW = 1, 4, 9


def rect(cells, x, y, w, h, material=BLACK):
    for yy in range(int(y), int(y + h)):
        for xx in range(int(x), int(x + w)):
            if 0 <= xx < W and 0 <= yy < H:
                cells[(xx, yy)] = material


def diagonal(cells, a, b, width, material=BLACK):
    dx, dy = b[0] - a[0], b[1] - a[1]
    steps = max(1, int(math.ceil(math.hypot(dx, dy))))
    half = width / 2.0
    for i in range(steps + 1):
        t = i / steps
        x = a[0] + dx * t
        y = a[1] + dy * t
        rect(cells, x - half, y - half, width, width, material)


def entries(cells):
    return [[y * W + x, mat] for (x, y), mat in sorted(cells.items())]


def main():
    lever = {}
    rect(lever, 93, 25, 6, 60)
    diagonal(lever, (96, 25), (216, 145), 4)
    rect(lever, 205, 136, 22, 18)

    roller = {}
    for oy in range(-5, 5):
        half = int(math.sqrt(25.0 - (oy + 0.5) ** 2))
        rect(roller, 96 - half, 80 + oy, half * 2, 1)

    pusher = {}
    rect(pusher, 103, 74, 24, 22)
    rect(pusher, 115, 58, 12, 20)

    bolt = {}
    rect(bolt, 77, 91, 24, 10, BLACK)
    for i in range(8):
        rect(bolt, 77 - (8 - i), 95 - i, 1, 2 + i * 2, GREY)

    static = {}
    rect(static, 78, 8, 36, 10)       # top bracket
    rect(static, 360, 20, 24, 180)    # spring post
    rect(static, 50, 101, 55, 3)      # bolt shelf
    rect(static, 190, 160, 25, 8)     # lever rest shelf
    rect(static, 210, 215, 22, 16)    # foot brace

    rods = []
    for y in range(93, 100):
        for x in range(112, 268):
            rods.append(y * W + x)

    data = {
        "version": 4,
        "id": "弩箭3",
        "name": "弩箭3",
        "description": "长杠杆省力上弦：手拉长臂，短臂滚轮压推块；拉力约为直接拉推块的 1/1.7～1/2，"
                       "需要黑色脚撑提供反作用力。弹道释放仍需阻铁/扳机。",
        "tags": ["手动", "弩箭", "杠杆"],
        "updated": 0,
        "favorite": False,
        "editor_only": False,
        "size": [W, H],
        "pixels": [],
        # Nail the yellow guide rail so it bakes as a static body (otherwise the
        # slider drags the rail along with the pusher).
        "fixed_nails": [96 * W + 113, 96 * W + 200],
        # Background nails on other rail cells: zero collision layer (nails are exclusive per cell).
        "background_nails": [96 * W + 150, 96 * W + 260],
        "infinite_nails": [],
        "rods": rods,
        "blue": [],
        "anchors": [],
        "springs": [{
            "path": [[121, 66], [372, 66]],
            "width": 65,
            "worn": [],
            "dash": 8.0,
            "gap": 6.0,
            "dashed": True,
        }],
        "motors": [],
        "bodies": [
            {"pixels": entries(lever), "fixed_nails": [], "background_nails": [],
             "infinite_nails": [], "static": False, "gear_centers": []},
            {"pixels": entries(roller), "fixed_nails": [], "background_nails": [],
             "infinite_nails": [], "static": False, "gear_centers": []},
            {"pixels": entries(pusher), "fixed_nails": [], "background_nails": [],
             "infinite_nails": [], "static": False, "gear_centers": []},
            {"pixels": entries(bolt), "fixed_nails": [], "background_nails": [],
             "infinite_nails": [], "static": False, "gear_centers": []},
            {"pixels": entries(static), "fixed_nails": [], "background_nails": [],
             "infinite_nails": [], "static": True, "gear_centers": []},
        ],
        "gears": [],
        "gear_centers": [],
        "draft_bearings": [
            {"position": [96, 25], "support_position": [96, 25], "fixed_to_world": True,
             "support": -1, "support_material": 0, "wheel_material": BLACK, "center_id": -1},
            {"position": [96, 80], "support_position": [96, 80], "fixed_to_world": False,
             "support": 0, "support_material": BLACK, "wheel_material": BLACK, "center_id": -1},
        ],
        "rails": [{"a": [113, 96], "b": [267, 96], "width": 7}],
        "slider_pins": [{"source": [119, 94], "position": [119, 94]}],
    }

    out = os.path.join(os.path.dirname(__file__), "..", "..", "blueprints", "弩箭3.inkbp")
    with open(out, "w", encoding="utf-8", newline="") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    print(out)


if __name__ == "__main__":
    main()
