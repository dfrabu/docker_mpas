# Imagem leve só para scripts/visualize.py (netCDF4 + scipy + matplotlib + cartopy)
# Build: docker build -f docker/viz.Dockerfile -t mpas-viz:latest .
FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      libgeos-dev libproj-dev proj-data \
    && rm -rf /var/lib/apt/lists/*

COPY requirements-viz.txt /tmp/requirements-viz.txt
RUN pip install --no-cache-dir -r /tmp/requirements-viz.txt

# Pré-baixa os shapefiles Natural Earth 110m (coastline/land/ocean/borders).
# Se a rede falhar, o visualize.py cai para eixos lon/lat simples.
RUN python - <<'PY' || true
import cartopy, cartopy.io.shapereader as shp
cartopy.config["data_dir"] = "/opt/cartopy"
for cat, name in [("physical", "coastline"), ("physical", "land"),
                  ("physical", "ocean"), ("cultural", "admin_0_boundary_lines_land")]:
    try:
        shp.natural_earth(resolution="110m", category=cat, name=name)
        print("ok", name)
    except Exception as e:
        print("skip", name, e)
PY
RUN chmod -R a+rX /opt/cartopy 2>/dev/null || true
ENV MPAS_CARTOPY_DATA=/opt/cartopy

WORKDIR /work
