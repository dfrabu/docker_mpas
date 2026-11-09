#!/usr/bin/env python3
"""
visualize.py — figuras profissionais das saídas do MPAS-Atmosphere.

A malha do MPAS é NÃO estruturada (nCells), então este script:
  1. reamostra os campos para uma grade lat/lon regular (scipy.griddata);
  2. desenha curvas de contorno preenchidas (contourf) + isolinhas (contour);
  3. desenha o VENTO como campo vetorial (quiver), sobre o módulo do vento.

Uso:
  python3.10 scripts/visualize.py --outputs outputs/ --all
  python3.10 scripts/visualize.py --outputs outputs/ --var t2m
  python3.10 scripts/visualize.py --outputs outputs/ --var wind
  python3.10 scripts/visualize.py --outputs outputs/ --list

Variáveis (pula as ausentes):
  temperatura : t2m, temperature, theta, skintemp
  pressão     : surface_pressure, mslp
  vento       : wind  (contorno do módulo + vetores), wind_speed, u10, v10, u, w
  precipitação: precip (=rainc+rainnc), rainnc, rainc, prec_acc_nc
  umidade     : qv, relhum, qc, qr
  outras      : olrtoa, cldfrac

Requer: netCDF4, numpy, scipy, matplotlib (+ cartopy para o mapa de fundo).
"""
import argparse, glob, os, sys
import numpy as np

# lon0, lon1, lat0, lat1 — América Central + do Sul
REGION = (-105.0, -30.0, -60.0, 18.0)

VARS_ALL = [
    # temperatura
    "t2m", "temperature", "theta", "skintemp",
    # pressão
    "surface_pressure", "mslp",
    # vento (wind = módulo + vetores)
    "wind", "wind_speed", "u10", "v10", "u", "w",
    # precipitação
    "precip", "rainnc", "rainc", "prec_acc_nc",
    # umidade / outras (só existem com física ligada)
    "qv", "relhum", "qc", "qr", "olrtoa", "cldfrac",
]

CMAPS = {
    "t2m": "RdYlBu_r", "temperature": "RdYlBu_r", "theta": "RdYlBu_r", "skintemp": "RdYlBu_r",
    "surface_pressure": "viridis", "mslp": "viridis",
    "wind": "turbo", "wind_speed": "turbo",
    "u10": "RdBu_r", "v10": "RdBu_r", "u": "RdBu_r", "w": "RdBu_r",
    "precip": "YlGnBu", "rainnc": "YlGnBu", "rainc": "YlGnBu", "prec_acc_nc": "YlGnBu",
    "qv": "YlGnBu", "relhum": "BrBG", "qc": "PuBuGn", "qr": "PuBuGn",
    "olrtoa": "inferno", "cldfrac": "Greys",
}

UNITS = {
    "t2m": "°C", "temperature": "°C", "skintemp": "°C", "theta": "K",
    "surface_pressure": "Pa", "mslp": "Pa",
    "wind": "m s$^{-1}$", "wind_speed": "m s$^{-1}$",
    "u10": "m s$^{-1}$", "v10": "m s$^{-1}$", "u": "m s$^{-1}$", "w": "m s$^{-1}$",
    "precip": "mm", "rainnc": "mm", "rainc": "mm", "prec_acc_nc": "mm",
    "qv": "kg kg$^{-1}$", "relhum": "%", "qc": "kg kg$^{-1}$", "qr": "kg kg$^{-1}$",
    "olrtoa": "W m$^{-2}$", "cldfrac": "fração",
}


# --------------------------------------------------------------------------- #
# leitura de coordenadas / campos
# --------------------------------------------------------------------------- #
def _open(path):
    from netCDF4 import Dataset
    return Dataset(path)


def load_coords(nc_path, loc="cell"):
    """lon/lat (graus) das células/arestas/vértices. Fallback para init.nc."""
    name = {"cell": "Cell", "edge": "Edge", "vertex": "Vertex"}[loc]
    for path in (nc_path, os.path.join(os.path.dirname(nc_path) or ".", "init.nc")):
        if not os.path.exists(path):
            continue
        ds = _open(path)
        if f"lat{name}" in ds.variables:
            lat = np.degrees(np.asarray(ds[f"lat{name}"][:]).ravel())
            lon = np.degrees(np.asarray(ds[f"lon{name}"][:]).ravel())
            ds.close()
            lon = ((lon + 540.0) % 360.0) - 180.0
            return lon, lat
        ds.close()
    raise KeyError(f"lat{name} ausente em {nc_path} e sem init.nc de fallback")


def _reduce_time_level(v, arr):
    dims = list(v.dimensions)
    while "Time" in dims and arr.ndim == len(dims):
        arr = arr[-1]
        dims = dims[1:]
    for lvl in ("nVertLevels", "nVertLevelsP1"):
        if lvl in dims:
            arr = np.take(arr, 0, axis=dims.index(lvl))
            dims = [d for d in dims if d != lvl]
    return np.asarray(arr).ravel()


def get_field(ds, var):
    """Retorna (data1d, location). location in {cell,edge,vertex}. Suporta derivadas."""
    def block(name):
        v = ds.variables[name]
        loc = ("edge" if "nEdges" in v.dimensions else
               "vertex" if "nVertices" in v.dimensions else "cell")
        return _reduce_time_level(v, np.asarray(v[:])), loc

    if var in ("wind", "wind_speed"):
        if "u10" in ds.variables and "v10" in ds.variables:
            u, _ = block("u10"); v, _ = block("v10")
            return np.sqrt(u ** 2 + v ** 2), "cell"
        raise KeyError("u10/v10 ausentes")
    if var == "precip":
        if "rainnc" in ds.variables:
            rnc, _ = block("rainnc")
            rc = block("rainc")[0] if "rainc" in ds.variables else np.zeros_like(rnc)
            return rnc + rc, "cell"
        raise KeyError("rainnc ausente")
    if var not in ds.variables:
        raise KeyError(f"var '{var}' ausente")
    data, loc = block(var)
    return data, loc


def wind_components(ds):
    """u10/v10 (nCells) para o campo vetorial."""
    if "u10" in ds.variables and "v10" in ds.variables:
        u, _ = get_field(ds, "u10"); v, _ = get_field(ds, "v10")
        return u, v
    raise KeyError("u10/v10 ausentes (vento vetorial requer física/superfície)")


# --------------------------------------------------------------------------- #
# regridagem para grade regular
# --------------------------------------------------------------------------- #
def make_grid(extent, res=320):
    lon0, lon1, lat0, lat1 = extent
    xs = np.linspace(lon0, lon1, res)
    ys = np.linspace(lat0, lat1, res)
    return np.meshgrid(xs, ys)


def regrid(lon, lat, vals, extent, res=320):
    """Reamostra dados não estruturados numa grade lon/lat regular (linear + nearest)."""
    from scipy.interpolate import griddata
    X, Y = make_grid(extent, res)
    pts = np.column_stack([lon, lat])
    Z = griddata(pts, vals, (X, Y), method="linear")
    if np.isnan(Z).any():
        Zn = griddata(pts, vals, (X, Y), method="nearest")
        Z = np.where(np.isnan(Z), Zn, Z)
    return X, Y, Z


def _subset(lon, lat, data, extent):
    lon0, lon1, lat0, lat1 = extent
    m = (lon >= lon0) & (lon <= lon1) & (lat >= lat0) & (lat <= lat1)
    return lon[m], lat[m], data[m]


# --------------------------------------------------------------------------- #
# plot
# --------------------------------------------------------------------------- #
def new_axes(fig, extent):
    """Cria eixo com mapa de fundo (cartopy) ou plano simples."""
    try:
        import cartopy
        # no container de visualização os shapefiles ficam em /opt/cartopy
        cartopy.config["data_dir"] = os.environ.get(
            "MPAS_CARTOPY_DATA", cartopy.config["data_dir"])
        import cartopy.crs as ccrs
        import cartopy.feature as cfeat
        ax = fig.add_subplot(111, projection=ccrs.PlateCarree())
        ax.set_extent(list(extent), crs=ccrs.PlateCarree())
        ax.add_feature(cfeat.OCEAN.with_scale("110m"), facecolor="#dbeaf5", zorder=0)
        ax.add_feature(cfeat.LAND.with_scale("110m"), facecolor="#efe7d5", zorder=0)
        ax.coastlines(resolution="110m", linewidth=0.8, zorder=5)
        ax.add_feature(cfeat.BORDERS.with_scale("110m"), linewidth=0.5, edgecolor="0.35", zorder=5)
        gl = ax.gridlines(draw_labels=True, linewidth=0.4, color="0.5", alpha=0.6, zorder=6)
        gl.top_labels = gl.right_labels = False
        gl.xlabel_style = gl.ylabel_style = {"size": 8}
        ax._ccrs = ccrs
        return ax, ccrs.PlateCarree(), True
    except Exception as e:      # ImportError ou falha ao baixar dados do Natural Earth
        print(f"[aviso] cartopy indisponível ({e}); usando eixos lon/lat simples", file=sys.stderr)
        ax = fig.add_subplot(111)
        ax.set_xlim(extent[0], extent[1]); ax.set_ylim(extent[2], extent[3])
        ax.set_xlabel("lon"); ax.set_ylabel("lat")
        ax.set_facecolor("#dbeaf5")
        return ax, None, False


def _levels(vals, n=21):
    v = np.asarray(vals)[np.isfinite(vals)]
    if v.size == 0:
        return np.linspace(0.0, 1.0, n)
    lo, hi = np.nanpercentile(v, 2), np.nanpercentile(v, 98)
    if not np.isfinite(lo) or not np.isfinite(hi) or hi <= lo:
        lo, hi = float(np.min(v)), float(np.max(v))
    if hi <= lo:                 # campo constante -> faixa artificial
        lo, hi = lo - 0.5, hi + 0.5
    return np.linspace(lo, hi, n)


def _convert(var, data):
    """Converte unidades para exibição. Retorna (data, unidade)."""
    med = np.nanmedian(data) if data.size else np.nan
    if var in ("t2m", "temperature", "skintemp") and med > 200:
        return data - 273.15, "°C"
    if var in ("surface_pressure", "mslp") and med > 5000:
        return data / 100.0, "hPa"
    return data, UNITS.get(var, "")


def plot_scalar(src, var, out_png, extent=REGION, dpi=130, res=320):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import ticker

    ds = _open(src)
    try:
        data, loc = get_field(ds, var)
    except KeyError as e:
        ds.close(); print(f"[skip] {var}: {e}", file=sys.stderr); return False
    ds.close()

    try:
        lon, lat = load_coords(src, loc)
    except KeyError as e:
        print(f"[skip] {var}: {e}", file=sys.stderr); return False

    lon, lat, data = _subset(lon, lat, data, extent)
    if len(data) < 12:
        print(f"[skip] {var}: poucos pontos na região (n={len(data)})", file=sys.stderr)
        return False
    data, unit = _convert(var, data)

    X, Y, Z = regrid(lon, lat, data, extent, res)

    fig = plt.figure(figsize=(11, 8))
    ax, transform, has_map = new_axes(fig, extent)
    cmap = plt.get_cmap(CMAPS.get(var, "turbo")).copy()
    cmap.set_bad((1, 1, 1, 0))
    lv = _levels(data, 21)
    cf = ax.contourf(X, Y, Z, levels=lv, cmap=cmap, extend="both",
                     transform=transform, zorder=2)
    cl = ax.contour(X, Y, Z, levels=lv[::3], colors="k", linewidths=0.35, alpha=0.55,
                    transform=transform, zorder=3)
    try:
        ax.clabel(cl, inline=True, fontsize=6, fmt="%.0f")
    except Exception:
        pass

    cb = plt.colorbar(cf, ax=ax, shrink=0.82, pad=0.02,
                      label=f"{var} [{unit}]")
    cb.ax.tick_params(labelsize=8)
    ax.set_title(f"MPAS-Atmosphere — {var}\n{os.path.basename(src)} | "
                 f"América Central+Sul [{extent[0]:.0f}..{extent[1]:.0f}, "
                 f"{extent[2]:.0f}..{extent[3]:.0f}]", fontsize=11)
    fig.savefig(out_png, dpi=dpi, bbox_inches="tight")
    plt.close(fig)
    print(f"OK: {out_png}  (contorno, n={len(data)})")
    return True


def plot_wind(src, out_png, extent=REGION, dpi=130, res=320, stride=14):
    """Módulo do vento em contorno + vetores (quiver)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    ds = _open(src)
    try:
        speed, _ = get_field(ds, "wind_speed")
        u, v = wind_components(ds)
    except KeyError as e:
        ds.close(); print(f"[skip] wind: {e}", file=sys.stderr); return False
    ds.close()

    lon, lat = load_coords(src, "cell")
    lon0, lon1, lat0, lat1 = extent
    m = (lon >= lon0) & (lon <= lon1) & (lat >= lat0) & (lat <= lat1)
    lon, lat, speed, u, v = lon[m], lat[m], speed[m], u[m], v[m]
    if len(speed) < 12:
        print(f"[skip] wind: poucos pontos (n={len(speed)})", file=sys.stderr)
        return False

    X, Y, Z = regrid(lon, lat, speed, extent, res)
    U = regrid(lon, lat, u, extent, res)[2]
    V = regrid(lon, lat, v, extent, res)[2]

    fig = plt.figure(figsize=(11, 8))
    ax, transform, has_map = new_axes(fig, extent)
    lv = _levels(speed, 21)
    cf = ax.contourf(X, Y, Z, levels=lv, cmap="turbo", extend="both",
                     transform=transform, zorder=2)
    ax.contour(X, Y, Z, levels=lv[::3], colors="k", linewidths=0.3, alpha=0.4,
               transform=transform, zorder=3)
    # vetores (subamostra a grade)
    sl = (slice(None, None, stride), slice(None, None, stride))
    q = ax.quiver(X[sl], Y[sl], U[sl], V[sl], color="k", pivot="middle",
                  scale=None, width=0.0018, headwidth=3.2, headlength=4.0,
                  transform=transform, zorder=4)
    ax.quiverkey(q, 0.90, 1.02, 10, "10 m s$^{-1}$", labelpos="E",
                 coordinates="axes", fontproperties={"size": 8})

    cb = plt.colorbar(cf, ax=ax, shrink=0.82, pad=0.02,
                      label="módulo do vento (10 m) [m s$^{-1}$]")
    cb.ax.tick_params(labelsize=8)
    ax.set_title(f"MPAS-Atmosphere — vento (10 m)\n{os.path.basename(src)} | "
                 f"módulo (contorno) + vetores", fontsize=11)
    fig.savefig(out_png, dpi=dpi, bbox_inches="tight")
    plt.close(fig)
    print(f"OK: {out_png}  (vento vetorial, n={len(speed)})")
    return True


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def pick_file(outputs, pattern):
    files = sorted(glob.glob(os.path.join(outputs, pattern)))
    return files[-1] if files else None


def candidate_files(outputs):
    out, seen = [], set()
    for pat in ("diag.*.nc", "history.*.nc", "init.nc"):
        f = pick_file(outputs, pat)
        if f and f not in seen:
            seen.add(f); out.append(f)
    return out


def main():
    ap = argparse.ArgumentParser(description="Figuras profissionais (contorno/vetor) do MPAS.")
    ap.add_argument("--outputs", default="outputs")
    ap.add_argument("--var", default="t2m")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--dpi", type=int, default=130)
    ap.add_argument("--res", type=int, default=320, help="resolução da grade de regridagem")
    ap.add_argument("--figdir", default=None, help="diretório das figuras (default: <outputs>/figs)")
    a = ap.parse_args()

    figdir = a.figdir or os.path.join(a.outputs, "figs")
    os.makedirs(figdir, exist_ok=True)

    if a.list:
        for f in candidate_files(a.outputs):
            ds = _open(f)
            print(f"== {f}: {len(ds.variables)} vars")
            for v in sorted(ds.variables):
                print(f"  {v} {ds.variables[v].dimensions}")
            ds.close()
        return

    files = candidate_files(a.outputs)
    if not files:
        print(f"[erro] nenhum .nc em {a.outputs}/.", file=sys.stderr); sys.exit(1)

    targets = VARS_ALL if a.all else [a.var]
    ok = 0
    for var in targets:
        done = False
        for src in files:
            out_png = os.path.join(figdir, f"{var}.png")
            if var == "wind":
                done = plot_wind(src, out_png, dpi=a.dpi, res=a.res)
            else:
                done = plot_scalar(src, var, out_png, dpi=a.dpi, res=a.res)
            if done:
                ok += 1; break
        if not done:
            print(f"[skip] {var}: ausente em todos os .nc", file=sys.stderr)
    print(f"{ok}/{len(targets)} figuras em {figdir}/")


if __name__ == "__main__":
    main()
