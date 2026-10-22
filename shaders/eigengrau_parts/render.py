#!/usr/bin/env -S uv run --quiet --with wgpu --with numpy --with pillow python
"""Offscreen preview renderer for vibe fragment shaders.

Binds the same uniforms as vibe's fragment canvas, fakes the audio, and writes
PNG frames, so a shader can be looked at without a compositor.

  ./render.py SHADER.wgsl OUT.png [--t 12.5] [--bands 0.6,0.3,0.2] [--bpm 120]
              [--size 960x540] [--click 0.5,0.5,10] [--mouse 0.5,0.5]
  ./render.py SHADER.wgsl OUTDIR --sheet 0,8,16,24 ...   one PNG per time + sheet.png
  ./render.py SHADER.wgsl OUT.webp --anim 0,32,15 ...    animated webp, start,end,fps

SHADER is a body without the preamble (it is prepended), e.g. ../eigengrau.wgsl
or a temp assembly from check.sh.
"""
import argparse
import pathlib
import struct

import numpy as np
import wgpu
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
PREAMBLE = HERE.parents[1] / "vibe-renderer/src/components/fragment_canvas/fragment_preamble.wgsl"
VERTEX = """
@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}
"""
N_FREQS = 64


def fake_freqs(bass, mid, treble):
    x = np.linspace(0.0, 1.0, N_FREQS)
    f = bass * np.exp(-((x / 0.06) ** 2)) + mid * np.exp(-(((x - 0.25) / 0.15) ** 2)) + treble * np.clip((x - 0.45) / 0.55, 0, 1) ** 0.5
    return f.astype(np.float32)


_DEV = None
_MODS = {}


def render(src, w, h, t, bands, bpm, mouse, click):
    global _DEV
    if _DEV is None:
        _DEV = wgpu.gpu.request_adapter_sync(power_preference="high-performance").request_device_sync()
    dev = _DEV
    code = PREAMBLE.read_text() + "\n" + src + "\n" + VERTEX
    if code not in _MODS:
        _MODS[code] = dev.create_shader_module(code=code)
    mod = _MODS[code]

    def ubuf(data):
        b = dev.create_buffer(size=max(16, len(data)), usage=wgpu.BufferUsage.UNIFORM | wgpu.BufferUsage.COPY_DST)
        dev.queue.write_buffer(b, 0, data.ljust(max(16, len(data)), b"\0"))
        return b

    freqs = fake_freqs(*bands)
    sbuf = dev.create_buffer(size=freqs.nbytes, usage=wgpu.BufferUsage.STORAGE | wgpu.BufferUsage.COPY_DST)
    dev.queue.write_buffer(sbuf, 0, freqs.tobytes())
    tex = dev.create_texture(size=(1, 1, 1), format=wgpu.TextureFormat.rgba8unorm, usage=wgpu.TextureUsage.TEXTURE_BINDING | wgpu.TextureUsage.COPY_DST)
    colors = struct.pack("16f", 0.9, 0.5, 0.3, 1, 0.3, 0.6, 0.9, 1, 0.8, 0.3, 0.8, 1, 0.3, 0.9, 0.6, 1)
    res = {
        0: ubuf(struct.pack("2f", w, h)),
        1: sbuf,
        2: ubuf(struct.pack("f", t)),
        3: ubuf(struct.pack("2f", *mouse)),
        4: ubuf(struct.pack("f", bpm)),
        5: ubuf(colors),
        6: dev.create_sampler(),
        7: tex.create_view(),
        8: ubuf(struct.pack("4f", *click)),
        9: ubuf(struct.pack("f", 12.0)),
    }
    target = dev.create_texture(size=(w, h, 1), format=wgpu.TextureFormat.rgba8unorm, usage=wgpu.TextureUsage.RENDER_ATTACHMENT | wgpu.TextureUsage.COPY_SRC)
    pipe = dev.create_render_pipeline(
        layout="auto",
        vertex={"module": mod, "entry_point": "vs"},
        fragment={"module": mod, "entry_point": "main", "targets": [{"format": wgpu.TextureFormat.rgba8unorm}]},
        primitive={"topology": wgpu.PrimitiveTopology.triangle_list},
    )
    layout = pipe.get_bind_group_layout(0)
    entries = []
    for binding, r in res.items():
        if isinstance(r, wgpu.GPUBuffer):
            entries.append({"binding": binding, "resource": {"buffer": r, "offset": 0, "size": r.size}})
        else:
            entries.append({"binding": binding, "resource": r})
    # layout="auto" drops bindings the shader never touches; retry without them.
    try:
        bg = dev.create_bind_group(layout=layout, entries=entries)
    except Exception:
        used = [e for e in entries if f"@binding({e['binding']})" in code and _used(code, e["binding"])]
        bg = dev.create_bind_group(layout=layout, entries=used)
    enc = dev.create_command_encoder()
    rp = enc.begin_render_pass(color_attachments=[{"view": target.create_view(), "load_op": "clear", "store_op": "store", "clear_value": (0, 0, 0, 1)}])
    rp.set_pipeline(pipe)
    rp.set_bind_group(0, bg)
    rp.draw(3)
    rp.end()
    dev.queue.submit([enc.finish()])
    data = dev.queue.read_texture({"texture": target}, {"bytes_per_row": w * 4, "rows_per_image": h}, (w, h, 1))
    return Image.fromarray(np.frombuffer(data, np.uint8).reshape(h, w, 4)[:, :, :3].copy())


NAMES = {0: "iResolution", 1: "freqs", 2: "iTime", 3: "iMouse", 4: "iBPM", 5: "iColors", 6: "iSampler", 7: "iTexture", 8: "iMouseClick", 9: "iLocalTime"}


def _used(code, binding):
    import re
    name = NAMES[binding]
    body = code.split("var<uniform> iLocalTime: f32;", 1)[-1]
    return re.search(rf"\b{name}\b", body) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("shader")
    ap.add_argument("out")
    ap.add_argument("--t", type=float, default=10.0)
    ap.add_argument("--sheet", help="comma-separated times; OUT is a directory")
    ap.add_argument("--anim", help="start,end,fps; OUT is an animated .webp")
    ap.add_argument("--bands", default="0.5,0.35,0.25")
    ap.add_argument("--bpm", type=float, default=120.0)
    ap.add_argument("--size", default="960x540")
    ap.add_argument("--mouse", default="0.5,0.5")
    ap.add_argument("--click", default="-1,-1,0,0", help="x,y,time[,0]")
    a = ap.parse_args()
    src = pathlib.Path(a.shader).read_text()
    w, h = map(int, a.size.split("x"))
    bands = tuple(map(float, a.bands.split(",")))
    mouse = tuple(map(float, a.mouse.split(",")))
    click = tuple(map(float, a.click.split(","))) + (0.0,) * 4
    if a.anim:
        t0, t1, fps = map(float, a.anim.split(","))
        n = int((t1 - t0) * fps)
        frames = [render(src, w, h, t0 + i / fps, bands, a.bpm, mouse, click[:4]) for i in range(n)]
        frames[0].save(a.out, save_all=True, append_images=frames[1:], duration=int(1000 / fps), loop=0, quality=80)
        print(a.out)
    elif a.sheet:
        out = pathlib.Path(a.out)
        out.mkdir(parents=True, exist_ok=True)
        frames = []
        for t in map(float, a.sheet.split(",")):
            img = render(src, w, h, t, bands, a.bpm, mouse, click[:4])
            img.save(out / f"t{t:07.2f}.png")
            frames.append(img)
        cols = min(4, len(frames))
        rows = -(-len(frames) // cols)
        sheet = Image.new("RGB", (cols * w, rows * h))
        for i, f in enumerate(frames):
            sheet.paste(f, ((i % cols) * w, (i // cols) * h))
        sheet.save(out / "sheet.png")
        print(out / "sheet.png")
    else:
        render(src, w, h, a.t, bands, a.bpm, mouse, click[:4]).save(a.out)
        print(a.out)


if __name__ == "__main__":
    main()
