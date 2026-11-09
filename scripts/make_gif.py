#!/usr/bin/env python3
"""
make_gif.py — animação (GIF) das saídas 3-em-3-horas do MPAS-Atmosphere.

Reaproveita a regridagem/plotagem do visualize.py, mas com escala de cores
FIXA entre os quadros (comparável no tempo) e um quadro por arquivo history.

Uso:
  python3 scripts/make_gif.py --outputs outputs/latest --var t2m
  python3 scripts/make_gif.py --outputs outputs/latest --all
  python3 scripts/make_gif.py --outputs outputs/latest --var t2m,precip --stride 2

Saída: <figdir>/<var>_anim.gif  (default figdir = <outputs>/figs)
"""
import argparse, glob, os, re, sys
from datetime import datetime

import numpy as np
import visualize as viz

# variáveis animadas por padrão no --all (as mais úteis e leves)
GIF_VARS = ["t2m", "surface_pressure", "precip", "wind"]

TIME_RE = re.compile(
    r"history\.(\d{4})-(\d{2})-(\d{2})_(\d{2})\.(\d{2})\.(\d{2})\.nc$")


def frame_time(path):
    """Data/hora válida do quadro, a partir do nome do arquivo history."""
    m = TIME_RE.search(os.path.basename(path))
    if not m:
        return None
    y, mo, d, h, mi, s = (int(x) for x in m.groups())
    return datetime(y, mo, d, h, mi, s)


def find_frames(outputs, stride=1):
    files = []
    for f in glob.glob(os.path.join(outputs, "history.*.nc")):
        t = frame_time(f)
        if t is not None:
            files.append((t, f))
    files.sort(key=lambda x: x[0])
    return files[::max(1, stride)]


def load_frames(files, var, extent, res):
    """Lê e regride cada quadro. Retorna (frames, unidade)."""
    frames = []
    unit = viz.UNITS.get(var, "")
    for t, path in files:
        ds = viz._open(path)
        try:
            if var == "wind":
                speed, _ = viz.get_field(ds, "wind_speed")
                u, v = viz.wind_components(ds)
            else:
                speed, loc = viz.get_field(ds, var)
                u = v = None
                if loc != "cell":
                    raise KeyError(f"'{var}' está em {loc}; animação só p/ campos de célula")
            lon, lat = viz.load_coords(path, "cell")
        except KeyError as e:
            ds.close()
            print(f"[skip] {path}: {e}", file=sys.stderr)
            continue
        ds.close()
        lon0, lat0 = lon, lat

        if len(lon) != len(speed):
            print(f"[skip] {path}: dimensões inconsistentes", file=sys.stderr)
            continue
        lon, lat, speed = viz._subset(lon, lat, speed, extent)
        if len(speed) < 12:
            print(f"[skip] {path}: poucos pontos na região (n={len(speed)})", file=sys.stderr)
            continue

        fr = {"time": t, "path": path, "lon": lon, "lat": lat, "val": speed,
              "u": None, "v": None}
        if var == "wind":
            # mesma máscara já aplicada a lon/lat
            _, _, u = viz._subset(lon0, lat0, u, extent)
            _, _, v = viz._subset(lon0, lat0, v, extent)
            fr["u"], fr["v"] = u, v
        else:
            speed, unit = viz._convert(var, speed)
            fr["val"] = speed

        fr["X"], fr["Y"], fr["Z"] = viz.regrid(lon, lat, speed, extent, res)
        if var == "wind":
            fr["U"] = viz.regrid(lon, lat, u, extent, res)[2]
            fr["V"] = viz.regrid(lon, lat, v, extent, res)[2]
        frames.append(fr)
    return frames, unit


def fixed_levels(frames, n=21):
    """Níveis iguais em todos os quadros (percentis 2-98 do conjunto)."""
    vals = np.concatenate([f["val"] for f in frames])
    return viz._levels(vals, n)


def render_gif(var, frames, levels, unit, out_gif, extent, dpi, duration_ms):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from PIL import Image

    t0 = frames[0]["time"]
    images = []
    for i, fr in enumerate(frames):
        fig = plt.figure(figsize=(11, 8))
        ax, transform, _ = viz.new_axes(fig, extent)
        cmap = plt.get_cmap(viz.CMAPS.get(var, "turbo")).copy()
        cmap.set_bad((1, 1, 1, 0))

        cf = ax.contourf(fr["X"], fr["Y"], fr["Z"], levels=levels, cmap=cmap,
                         extend="both", transform=transform, zorder=2)
        ax.contour(fr["X"], fr["Y"], fr["Z"], levels=levels[::3], colors="k",
                   linewidths=0.35, alpha=0.55, transform=transform, zorder=3)
        if var == "wind":
            sl = (slice(None, None, 14), slice(None, None, 14))
            ax.quiver(fr["X"][sl], fr["Y"][sl], fr["U"][sl], fr["V"][sl],
                      color="k", pivot="middle", scale=None, width=0.0018,
                      headwidth=3.2, headlength=4.0, transform=transform, zorder=4)

        cb = plt.colorbar(cf, ax=ax, shrink=0.82, pad=0.02,
                          label=f"{var} [{unit}]")
        cb.ax.tick_params(labelsize=8)
        fh = int(round((fr["time"] - t0).total_seconds() / 3600.0))
        ax.set_title(
            f"MPAS-Atmosphere (240 km) — {var}\n"
            f"{fr['time']:%d/%m/%Y %HZ}  (f+{fh:02d}h)   "
            f"[{i + 1}/{len(frames)}]", fontsize=11)
        fig.canvas.draw()
        img = Image.fromarray(np.asarray(fig.canvas.buffer_rgba())).convert("RGB")
        images.append(img)
        plt.close(fig)
        print(f"  quadro {i + 1}/{len(frames)}  {fr['time']:%d/%m %HZ}")

    images[0].save(out_gif, save_all=True, append_images=images[1:],
                   duration=duration_ms, loop=0, optimize=True, disposal=2)
    size_mb = os.path.getsize(out_gif) / 1e6
    print(f"OK: {out_gif}  ({len(images)} quadros, {size_mb:.1f} MB)")
    return True


def parse_extent(s):
    vals = [float(x) for x in s.split(",")]
    if len(vals) != 4:
        raise ValueError("--extent espera lon0,lon1,lat0,lat1")
    return tuple(vals)


def main():
    ap = argparse.ArgumentParser(description="GIF animado das saídas do MPAS.")
    ap.add_argument("--outputs", default="outputs")
    ap.add_argument("--var", default="t2m",
                    help="variável(is) separadas por vírgula (default t2m)")
    ap.add_argument("--all", action="store_true",
                    help=f"anima {', '.join(GIF_VARS)}")
    ap.add_argument("--figdir", default=None,
                    help="diretório de saída (default <outputs>/figs)")
    ap.add_argument("--stride", type=int, default=1,
                    help="usa 1 a cada N quadros (default 1 = todos)")
    ap.add_argument("--duration-ms", type=int, default=400,
                    help="tempo de cada quadro no GIF (default 400 ms)")
    ap.add_argument("--dpi", type=int, default=100)
    ap.add_argument("--res", type=int, default=320,
                    help="resolução da grade de regridagem (default 320)")
    ap.add_argument("--extent", default=None,
                    help="lon0,lon1,lat0,lat1 (default América Central+Sul)")
    a = ap.parse_args()

    extent = parse_extent(a.extent) if a.extent else viz.REGION
    figdir = a.figdir or os.path.join(a.outputs, "figs")
    os.makedirs(figdir, exist_ok=True)

    files = find_frames(a.outputs, a.stride)
    if len(files) < 2:
        print(f"[erro] preciso de >=2 history.*.nc em {a.outputs}/ "
              f"(encontrei {len(files)})", file=sys.stderr)
        sys.exit(1)

    targets = GIF_VARS if a.all else [v.strip() for v in a.var.split(",") if v.strip()]
    ok = 0
    for var in targets:
        print(f"== {var}: {len(files)} quadros ==")
        frames, unit = load_frames(files, var, extent, a.res)
        if len(frames) < 2:
            print(f"[skip] {var}: menos de 2 quadros válidos", file=sys.stderr)
            continue
        levels = fixed_levels(frames)
        out_gif = os.path.join(figdir, f"{var}_anim.gif")
        if render_gif(var, frames, levels, unit, out_gif, extent,
                      a.dpi, a.duration_ms):
            ok += 1

    print(f"{ok}/{len(targets)} animações em {figdir}/")
    if ok == 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
