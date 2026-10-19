#!/usr/bin/env python3
"""耳机猫 —— 用 Pillow 逐帧画，输出两套：

  frames/*.png   动画封面用的帧（正方形 1024，交 ffmpeg 编码成循环视频）
  static.png     静态封面 / Live Activity 备用

为什么程序化画而不是手搓 SVG：要出几十帧连续动画，靠手写路径不现实；
而且「有质感」靠的是分层渐变、柔和阴影、高光这些能算出来的东西。

配色沿用 App 图标（design/appicon.svg）：淡粉底 #FFF3F8→#FFDCEA→#FFC3DA，
深莓主色 #7D1549→#380A2C。猫刻意用暖奶油色，在粉底上才跳得出来。
"""
import math
import os
from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = os.path.dirname(os.path.abspath(__file__))

# 画布必须是**竖版 3:4**。
#
# ⚠️ 这不是审美选择，是硬约束：实测（iPhone Air / iOS 27.2）系统只支持
# `MPNowPlayingInfoProperty3x4AnimatedArtwork`，**不支持 1x1**
# —— `MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys` 只返回 3x4 那一个。
# 用不支持的 key 系统会**静默忽略**，现象就是「封面没换」。
# 头文件也写了：宽高比和 key 不符会退回静态图。
#
# 相应的构图也改了：正方形时猫是「斜靠 + 尾巴翘起」的俏皮姿势，缩到锁屏那种
# 小方块里像一团毛球；竖版改成**端坐**——头在中间偏上、正对观众、两只眼睛分开，
# 小尺寸下才认得出是只猫。
# 1080×1440 = **正好** 3:4，而且两个方向都是偶数。
#
# 两个数都不是随便挑的：
#   · 比例必须正好 3:4 —— 头文件写了，宽高比和 key 不符会退回静态图。
#     （本来取 1024×1365，1365 是奇数，H.264 的 yuv420p 要求偶数，
#      libx264 会直接报错；改成 1364 又差了 0.1%，不如直接取准。）
#   · 偶数 —— yuv420p 是 2×2 色度抽样，边长奇数编码器不接受。
W, H = 1080, 1440
FONT = "/System/Library/Fonts/Supplemental/Songti.ttc"

# ---- 调色 ----
BG_TOP, BG_MID, BG_BOT = (255, 243, 248), (255, 220, 234), (255, 195, 218)
FUR_HI, FUR, FUR_SH = (255, 249, 242), (252, 231, 213), (240, 205, 180)
BERRY = (125, 21, 73)
EAR_IN = (246, 178, 199)
IRIS_TOP, IRIS_BOT = (126, 196, 214), (44, 116, 158)
BLUSH = (247, 162, 186)
GLASS_HI = (255, 255, 255, 90)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def vgrad(size, stops):
    """竖直渐变。stops = [(t, rgb), ...]，t ∈ [0,1]。"""
    w, h = size
    img = Image.new("RGB", (1, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        lo = stops[0]
        for i in range(len(stops) - 1):
            if stops[i][0] <= t <= stops[i + 1][0]:
                a, b = stops[i], stops[i + 1]
                span = max(1e-6, b[0] - a[0])
                px[0, y] = lerp(a[1], b[1], (t - a[0]) / span)
                break
        else:
            px[0, y] = stops[-1][1]
    return img.resize((w, h), Image.NEAREST)


def radial(size, inner, outer_rgb, strength=1.0):
    """柔和径向高光，用来做背景的通透感和脸上的光。"""
    w, h = size
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    ccx, ccy = w / 2, h * 0.34
    r = w * outer_rgb
    steps = 60
    for i in range(steps, 0, -1):
        t = i / steps
        val = int(255 * strength * (1 - t) ** 2.2)
        rr = r * t
        d.ellipse([ccx - rr, ccy - rr, ccx + rr, ccy + rr], fill=val)
    m = m.filter(ImageFilter.GaussianBlur(w * 0.06))
    layer = Image.new("RGB", (w, h), inner)
    return Image.composite(layer, Image.new("RGB", (w, h), (0, 0, 0)), m)


def cat_canvas(ear_angle=0.0, lid=0.0, tail=0.0, bob=0.0, closed_eye=False):
    """画一帧猫。所有姿态参数都是小幅度的 —— 轻微动才优雅，大动作显廉价。

    ear_angle  耳朵绕根部旋转的角度（度）
    lid        上眼睑下压比例 0..1（眨眼）
    tail       尾巴摆动（度）
    bob        整体上下浮动（像素）
    """
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    # 猫在竖版画布里的定位。**只调这两个数就能整体缩放/上下挪** ——
    # 后面所有坐标都从 `cx/cy/head_r` 推出来，不再出现「写死 H*0.868」那种
    # 换画布比例就失联的绝对量。
    # 尺寸是被**宽度**卡死的，不是高度。
    #
    # 猫横向要占「耳罩 ±1.12r」≈ 2.24r，竖版只有 W 宽，所以
    # head_r ≤ W/2.24。取 0.40W 留一点边。猫本身是「宽 > 高」的，
    # 所以它在画面里天然填不满上下 —— 竖版多出来的那截高度只能靠背景
    # 渐变的纵深去填，硬把猫拉大会先撞到左右两边。
    #
    # 尾巴也因此改成**贴着身体往上升**（见下），而不是正方形时代那样
    # 往右横扫：横扫出去的尾巴会额外吃掉 1.3r 的横向预算，
    # 那才是真正把猫压小的原因。
    cx = W / 2
    head_r = W * 0.360
    cy = H * 0.495 + bob

    # ---------- 背景：淡粉渐变 + 通透高光 ----------
    bg = vgrad((W, H), [(0.0, BG_TOP), (0.52, BG_MID), (1.0, BG_BOT)]).convert("RGBA")
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    # 光晕落在猫的胸口偏上：把脸和耳机那圈提亮，下半身留在渐变的深处，
    # 画面才有「上亮下暗」的纵深，不是一张平铺的粉纸。
    gy = cy - head_r * 0.30
    for i in range(48, 0, -1):
        t = i / 48
        rr = H * 0.44 * t
        gd.ellipse([cx - rr, gy - rr, cx + rr, gy + rr],
                   fill=(255, 255, 255, int(34 * (1 - t) ** 1.7)))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.05))
    bg.alpha_composite(glow)
    canvas.alpha_composite(bg)

    # 地面阴影：让猫「坐」在画面上，而不是飘着。
    # 跟着爪子的位置走（cy + 1.20*head_r 就是爪底），改姿势时不会脱节。
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).ellipse(
        [cx - head_r * 0.62, cy + head_r * 1.00,
         cx + head_r * 0.92, cy + head_r * 1.10],
        fill=(180, 120, 150, 78))
    sh = sh.filter(ImageFilter.GaussianBlur(W * 0.030))
    canvas.alpha_composite(sh)

    cat = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    # ⚠️ 必须传 "RGBA"：默认模式下 ImageDraw **不做 alpha 混合**，而是把像素
    # 直接替换成带 alpha 的颜色 —— 高光、腮红、胡须的透明会整块糊掉。
    dc = ImageDraw.Draw(cat, "RGBA")

    def rot_about(p, origin, deg):
        a = math.radians(deg)
        dx, dy = p[0] - origin[0], p[1] - origin[1]
        return (origin[0] + dx * math.cos(a) - dy * math.sin(a),
                origin[1] + dx * math.sin(a) + dy * math.cos(a))

    # ---------- 耳朵（**最后**画，见文件末尾 —— 这样它才压在耳机横梁上面） ----------
    def ear_pts(sign, ear_angle_deg):
        """左/右耳的外轮廓。角度绕**耳根**转，转一点点才优雅，转多了显廉价。

        三角形刻意做「宽基座 + 微微外倾的尖」：尖正对基座中心会像兔耳，
        外倾太多又像被风吹歪 —— 0.10r 的外倾是猫耳那个味道。
        """
        base_x = cx + sign * head_r * 0.58
        base_y = cy - head_r * 0.66
        tip = (base_x + sign * head_r * 0.10, base_y - head_r * 0.66)
        pts = []
        for p in [(base_x - sign * head_r * 0.36, base_y + head_r * 0.06),
                  tip,
                  (base_x + sign * head_r * 0.36, base_y + head_r * 0.06)]:
            pts.append(rot_about(p, (base_x, base_y), sign * ear_angle_deg))
        return pts

    def ear_inner(pts):
        """耳廓内侧：把外轮廓朝**三角形重心**缩到 55%，做成同形的暖粉小块。

        原来是在三个顶点上各自硬加偏移，结果那块粉偏到耳朵外侧去了；
        朝重心缩放了就是真正的「同形内嵌」。
        """
        gx = sum(p[0] for p in pts) / 3
        gy = sum(p[1] for p in pts) / 3
        return [(gx + (p[0] - gx) * 0.55, gy + (p[1] - gy) * 0.55) for p in pts]

    # ---------- 尾巴（画在身体**之前** = 在身体后面，从右前方绕到右前方） ----------
    # 姿势：端坐时尾巴从屁股右边甩出来，沿地面向前弯。所以走的是
    # 「先大幅向外、再向里收」的 C 形，而不是正方形时代那条向上翘的弧线。
    #
    # 两条硬要求，缺一条尾巴就白画：
    #   1. 整条**待在身体轮廓之外** —— 画在身体之前，被盖住就一根都看不见。
    #   2. 尾巴尖必须落在画布内 —— 竖版比正方形窄，正方形时代的摆幅会直接出界。
    # 摆动量做在「尾尖相对根部的角度」上，函数保持连续，循环处首尾自然对齐。
    #
    # 用的是二次贝塞尔，不是「圆的极坐标采样」。
    # 极坐标那版（半径先涨后收来做出鼓包）会在鼓包前后**折出两道尖角** ——
    # 半径的导数盖过了角度的导数，曲线自己就往回钻了，看着像尾巴被打了个结。
    # 贝塞尔天然光滑，而且改形状只需要挪一个控制点。
    #
    # 姿势是**尾巴盘在身前**，不是伸在身后。
    #
    # 试过三版「伸出去」的：向右横扫（出画）、向右上翘（被耳罩吃掉）、
    # 贴着身侧往上卷（还是被耳罩吃掉）。根因是硬的 —— 耳罩已经占掉
    # 横向 ±1.12r，竖版宽只有 2.24r，猫右边**没有**能放下一条伸出来尾巴的地方。
    #
    # 而画面前下方（爪子的前面）一直是空的。猫坐着时把尾巴绕到身前来，
    # 本来就是最常见的姿势，正好用掉那块空 —— 这才是既好看又放得下的解法。
    # `tail` 参数改成让尾巴**左右摆**，动的是尾巴尖那一端。
    def tail_path(p):
        """尾巴中轴上的点（二次贝塞尔），从左侧绕到右前方。

        ⚠️ 整条必须压在**下巴线以下**（下巴在 cy + 1.02r）。
        第一版把两端放在 1.00r，尾巴正好从下巴前面横穿过去 ——
        远看像给猫嘴上贴了块胶布。挪到 1.14r 就贴边了。
        弧顶给到 1.42r：再深就顶到画面下沿，再浅就贴着爪子看不出是条尾巴。
        """
        p0 = (cx - head_r * 0.30, cy + head_r * 1.00)
        p1 = (cx + head_r * 0.30, cy + head_r * 1.48)
        p2 = (cx + head_r * 1.18, cy + head_r * 1.08)
        sway = math.sin(math.radians(tail))
        p2 = (p2[0] + head_r * 0.06 * sway, p2[1] - head_r * 0.07 * sway)
        return ((1 - p) ** 2 * p0[0] + 2 * (1 - p) * p * p1[0] + p ** 2 * p2[0],
                (1 - p) ** 2 * p0[1] + 2 * (1 - p) * p * p1[1] + p ** 2 * p2[1])

    tip = tail_path(1.0)

    # ---------- 身体与爪子 ----------
    # 身体用和头同样的 FUR：第一版用了白色，结果像个围兜，和头分家了。
    dc.ellipse([cx - head_r * 0.66, cy + head_r * 0.34,
                cx + head_r * 0.66, cy + head_r * 1.12], fill=FUR)
    # 两只前爪：只比身体亮一点点，靠一点点高光点出形状。
    # 爪底和身体底都是 1.12r —— 齐平才像「坐在地上」，有一截凸出来就像没坐稳。
    for dx in (-0.30, 0.30):
        dc.ellipse([cx + head_r * dx - head_r * 0.20, cy + head_r * 0.80,
                    cx + head_r * dx + head_r * 0.20, cy + head_r * 1.12],
                   fill=lerp(FUR, FUR_HI, 0.55))

    # ---------- 头（先收影子，再画头；顺序反了影子会盖在脸上） ----------
    # 用「整只猫的 alpha 差集」自动求阴影：镜射出一份副本，把本体减掉，
    # 剩下的就是露在本体之外的那圈，染成暖棕再模糊。
    # 比手画一个椭圆准得多 —— 耳朵、耳机、尾巴的形状都会自己长出来。
    shadow = ImageChops.subtract(cat.getchannel("A"),
                                 ImageChops.offset(cat.getchannel("A"), 0, -int(head_r * 0.26)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(head_r * 0.055))
    cat.alpha_composite(Image.merge("RGBA", (
        Image.new("L", (W, H), 150), Image.new("L", (W, H), 96),
        Image.new("L", (W, H), 128), shadow.point(lambda v: int(v * 0.45)))))

    # ---------- 头 ----------
    # 横着比竖着宽一点（1.12r × 1.02r）—— 猫脸本来就是扁圆的，
    # 正圆会显得像颗蛋。
    head_box = [cx - head_r * 1.13, cy - head_r * 1.01,
                cx + head_r * 1.13, cy + head_r * 1.01]
    dc.ellipse(head_box, fill=FUR)

    # ---------- 头的立体感 ----------
    # 这是「有没有质感」的分水岭：不铺这层，头就是一块平的奶油色圆盘，
    # 不管眼睛画得多细都像贴纸。做法很朴素 —— 一个上亮下暖的竖直渐变，
    # 用头的椭圆当遮罩截出来，上半加白、下半压一层暖棕，头就成了个球。
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).ellipse(head_box, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(head_r * 0.02))

    # 渐变：1 = 头顶，0 = 下巴。指数 1.3 让亮部集中在额头，
    # 线性的话整个上半张脸一样亮，看着还是平的。
    ramp = Image.new("L", (W, H), 0)
    rd = ImageDraw.Draw(ramp)
    y0, y1 = int(cy - head_r * 1.02), int(cy + head_r * 1.02)
    for y in range(max(0, y0), min(H, y1 + 1)):
        u = (y - y0) / max(1, y1 - y0)
        rd.line([(0, y), (W, y)], fill=int(255 * max(0.0, 1 - u) ** 1.3))
    ramp = ramp.filter(ImageFilter.GaussianBlur(head_r * 0.10))

    def tint(rgb, alpha):
        return Image.merge("RGBA", (Image.new("L", (W, H), rgb[0]),
                                    Image.new("L", (W, H), rgb[1]),
                                    Image.new("L", (W, H), rgb[2]), alpha))

    cat.alpha_composite(tint((255, 255, 252),
                             ImageChops.multiply(mask, ramp).point(lambda v: int(v * 0.40))))
    cat.alpha_composite(tint((206, 166, 140),
                             ImageChops.multiply(mask, ImageChops.invert(ramp))
                             .point(lambda v: int(v * 0.19))))

    # ---------- 耳机（戴着才有「在听歌」的意思）----------
    band = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    # 头梁 = 一段圆弧的**折线**，不是 `arc` 描边。
    # `arc` 是平头收尾，两端会在脸颊边上支棱出两个小方块；折线配
    # `joint="curve"` 自带圆头。
    #
    # 圆心的取法有讲究：圆心放在**耳罩轴心**（cy - 0.14r）而不是头心，
    # 半径 1.12r 让弧顶落在 cy - 1.26r —— 比头顶（cy - 0.96r）高 0.30r，
    # 戴着是看得见的；同时 θ=0/180 两端正好落进 ±1.12r 的耳罩范围里被盖住，
    # 头梁不会「悬空断在脸两边」。
    bcx, bcy, br = cx, cy - head_r * 0.14, head_r * 1.12
    arcpts = []
    for i in range(61):
        a = math.pi * i / 60
        arcpts.append((bcx + br * math.cos(a), bcy - br * math.sin(a)))
    bd.line(arcpts, fill=BERRY, width=int(head_r * 0.13), joint="curve")
    cat.alpha_composite(band)
    for sign in (-1, 1):
        ex = cx + sign * head_r * 1.02
        ey = cy - head_r * 0.14
        dc.ellipse([ex - head_r * 0.30, ey - head_r * 0.38,
                    ex + head_r * 0.30, ey + head_r * 0.38], fill=BERRY)
        dc.ellipse([ex - head_r * 0.17, ey - head_r * 0.24,
                    ex + head_r * 0.17, ey + head_r * 0.24], fill=lerp(BERRY, (255, 255, 255), 0.14))

    # ---------- 眼睛 ----------
    for sign in (-1, 1):
        ex = cx + sign * head_r * 0.40
        ey = cy - head_r * 0.02
        rx, ry = head_r * 0.155, head_r * (0.185 * (1 - 0.92 * lid))
        if closed_eye or lid > 0.9:
            dc.arc([ex - rx * 1.15, ey - ry * 0.9, ex + rx * 1.15, ey + ry * 1.5],
                   start=200, end=340, fill=lerp(BERRY, (0, 0, 0), 0.1),
                   width=int(head_r * 0.045))
            continue
        # 眼白 → 虹膜渐变 → 瞳孔 → 高光，一层都不省。
        # 虹膜用「渐变图 + 椭圆遮罩」贴，不用一串同心椭圆描边 ——
        # 后者每圈半径都在变，很容易算出 y1 < y0 直接抛异常。
        dc.ellipse([ex - rx, ey - ry, ex + rx, ey + ry], fill=(255, 253, 252))
        iris_box = (int(ex - rx * 0.90), int(ey - ry * 0.94),
                    int(ex + rx * 0.90) + 1, int(ey + ry * 0.94) + 1)
        iw, ih = iris_box[2] - iris_box[0], iris_box[3] - iris_box[1]
        if iw > 2 and ih > 2:
            iris = vgrad((iw, ih), [(0.0, IRIS_TOP), (1.0, IRIS_BOT)]).convert("RGBA")
            mask = Image.new("L", (iw, ih), 0)
            ImageDraw.Draw(mask).ellipse([0, 0, iw - 1, ih - 1], fill=255)
            cat.paste(iris, (iris_box[0], iris_box[1]), mask)
        dc.ellipse([ex - rx * 0.40, ey - ry * 0.62, ex + rx * 0.40, ey + ry * 0.62],
                   fill=(28, 16, 26))
        # 两点高光：大颗在上左、小颗在下右，眼睛「活」起来就靠这个
        dc.ellipse([ex - rx * 0.30, ey - ry * 0.46, ex + rx * 0.06, ey - ry * 0.04],
                   fill=(255, 255, 255))
        dc.ellipse([ex + rx * 0.12, ey + ry * 0.20, ex + rx * 0.34, ey + ry * 0.42],
                   fill=(255, 255, 255, 190))

    # ---------- 鼻子 / 嘴 / 腮红 ----------
    dc.polygon([(cx - head_r * 0.055, cy + head_r * 0.28),
                (cx + head_r * 0.055, cy + head_r * 0.28),
                (cx, cy + head_r * 0.355)], fill=(226, 143, 168))
    dc.arc([cx - head_r * 0.17, cy + head_r * 0.26, cx, cy + head_r * 0.46],
           start=20, end=150, fill=BERRY, width=int(head_r * 0.032))
    dc.arc([cx, cy + head_r * 0.26, cx + head_r * 0.17, cy + head_r * 0.46],
           start=30, end=160, fill=BERRY, width=int(head_r * 0.032))

    blush = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bld = ImageDraw.Draw(blush)
    for sign in (-1, 1):
        bld.ellipse([cx + sign * head_r * 0.66 - head_r * 0.20, cy + head_r * 0.20,
                     cx + sign * head_r * 0.66 + head_r * 0.20, cy + head_r * 0.48],
                    fill=BLUSH + (86,))
    cat.alpha_composite(blush.filter(ImageFilter.GaussianBlur(head_r * 0.12)))

    # 胡须：画在独立图层上、再模糊一丁点，才有「细毛」的柔软感，
    # 直接画实线会像铁丝。
    wh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wh, "RGBA")
    for sign in (-1, 1):
        for dy in (-0.11, 0.0, 0.11):
            x0 = cx + sign * head_r * 0.40
            y0 = cy + head_r * (0.30 + dy)
            wd.line([(x0, y0), (x0 + sign * head_r * 0.66, y0 - head_r * 0.10 + dy * head_r * 0.45)],
                    fill=(203, 168, 176, 205), width=max(2, int(head_r * 0.021)))
    cat.alpha_composite(wh.filter(ImageFilter.GaussianBlur(head_r * 0.012)))

    # ---------- 耳朵：**最后**画 ----------
    # 必须压过耳机横梁。放在头之前画的话，横梁会从两只耳朵中间横穿过去 ——
    # 看着像头上箍了根发带，不是戴耳机。
    for sign in (-1, 1):
        pts = ear_pts(sign, ear_angle)
        dc.polygon(pts, fill=FUR)
        dc.polygon(ear_inner(pts), fill=EAR_IN)

    canvas.alpha_composite(cat)

    # ---------- 尾巴：**最后**画 ----------
    # 画在最后 = 盖在身体上面。尾巴盘在身前，本来就该压在爪子前面；
    # 起点那截（左侧、贴地）会盖住一点身体左下角，看着正好像从屁股后面绕出来的。
    tail_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    tail_d = ImageDraw.Draw(tail_layer)

    def tail_tube(draw, grow, color, scale=1.0, lo=0.0, hi=1.0, dy=0.0):
        """沿中轴铺一串渐细的圆。`grow` 是半径增量，用来做外圈描边。"""
        n = 41
        for i in range(int(lo * (n - 1)), int(hi * (n - 1)) + 1):
            p = i / (n - 1)
            x, y = tail_path(p)
            rr = (head_r * (0.112 - 0.046 * p) * scale) + grow
            y += dy
            draw.ellipse([x - rr, y - rr, x + rr, y + rr], fill=color)

    # 先铺一圈略大的**深色**、再盖上本色：等于给尾巴描了一道细边。
    # 这一步不能省 —— 尾巴压在同样奶油色的爪子/身体上，不描边就是一坨，
    # 远看像爪子长歪了（第一版就是这样，完全看不出有条尾巴）。
    tail_tube(tail_d, head_r * 0.030, FUR_SH)
    tail_tube(tail_d, 0, FUR)
    # 高光：用**细一号的本色亮管整根上移**模拟上缘受光。
    # 早先是画一条水平线，结果尾巴不是水平的，那条线一头扎进尾巴里、
    # 一头悬在外面 —— 不是高光，是道划痕。
    tail_tube(tail_d, 0, FUR_HI, scale=0.34, dy=-head_r * 0.036)
    # 尾巴尖那团浅色：没有它尾巴看着像一根管子，而是一段粗线
    tail_d.ellipse([tip[0] - head_r * 0.075, tip[1] - head_r * 0.075,
                    tip[0] + head_r * 0.075, tip[1] + head_r * 0.075], fill=FUR_HI)
    canvas.alpha_composite(tail_layer)

    # ---------- 音符：只留一个，别挤在一起 ----------
    # 放**左上**：竖版右上角被耳罩占掉了，左上那片空白才是真的空。
    # 半径也压到 0.44r，太大会撞到耳朵。
    d = ImageDraw.Draw(canvas, "RGBA")
    x, y, h = cx - head_r * 1.66, cy - head_r * 0.80, head_r * 0.44
    d.ellipse([x - h * 0.30, y - h * 0.14, x + h * 0.18, y + h * 0.32], fill=BERRY + (238,))
    d.rectangle([x + h * 0.03, y - h * 1.02, x + h * 0.19, y + h * 0.16], fill=BERRY + (238,))
    d.rectangle([x + h * 0.03, y - h * 1.02, x + h * 0.64, y - h * 0.84], fill=BERRY + (238,))
    return canvas


def main():
    os.makedirs(os.path.join(OUT, "frames"), exist_ok=True)
    static = cat_canvas().convert("RGB")
    static.save(os.path.join(OUT, "static.png"), optimize=True)
    print("static.png", static.size)

    # 预览小图：和视频一样按 3:4 缩，才能看出「锁屏那块小地方」里到底长什么样
    static.resize((240, 320), Image.LANCZOS).save(
        os.path.join(OUT, "preview-240.png"), optimize=True)
    # 系统曲面/极小的占位预览，纯属自己肉眼检查构图用
    static.resize((90, 120), Image.LANCZOS).save(
        os.path.join(OUT, "preview-90.png"), optimize=True)

    # 60 帧、30fps = **2 秒**一个循环。
    #
    # 为什么不取 1 秒：1 秒里塞不进「呼吸 + 眨眼」两件事，眨眼会显得很急促。
    # 2 秒刚好是「吸气—呼气—眨一下眼」的节奏，看起来是活的，又不闹。
    # 60 帧 × 1080×1440 也只有几十 KB —— 循环视频的时长几乎不影响体积。
    #
    # 眨眼单独做成一条窄脉冲（不是正弦）：正弦会让眼睛一直半睁半闭，
    # 看着像困了；脉冲是「忽然闭上、马上睁开」，才是真的眨眼。
    N = 60
    for f in range(N):
        t = f / N
        # 眨眼：t∈[0.62, 0.80] 之间闭一下。`sin(pi*u)` 保证首尾都是 0（全睁），
        # 中间到 1（全闭），所以脉冲边界看不出接缝。
        u = (t - 0.62) / 0.18
        lid = math.sin(math.pi * u) ** 0.6 if 0.0 <= u <= 1.0 else 0.0
        frame = cat_canvas(
            ear_angle=2.6 * math.sin(2 * math.pi * t),
            lid=lid,
            tail=13.0 * math.sin(2 * math.pi * t),
            bob=5.0 * math.sin(2 * math.pi * t),
        )
        frame.convert("RGB").save(os.path.join(OUT, "frames", f"{f:03d}.png"), optimize=True)
    print(f"frames: {N}")


if __name__ == "__main__":
    main()