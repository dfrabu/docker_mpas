#!/usr/bin/env bash
# get_inputs.sh — baixa malhas, estáticos e dados GFS p/ América Central + do Sul
# Uso:
#   ./scripts/get_inputs.sh --quick            # teste leve 240km (~10 MB) p/ P100
#   ./scripts/get_inputs.sh --south-america    # produção 60-15km (~400 MB) + static (~2.3 GB)
#   ./scripts/get_inputs.sh --south-america --gfs-date 2026010100  # + GFS 0.25deg
#   ./scripts/get_inputs.sh --regional         # gera recorte regional via MPAS-Limited-Area
set -euo pipefail

MPAS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUTS="$MPAS_DIR/inputs"
mkdir -p "$INPUTS/intermediate" "$INPUTS/geog" "$INPUTS/wps"

MESH_BASE="https://www2.mmm.ucar.edu/projects/mpas/atmosphere_meshes"
# Dados geográficos estáticos (default terrestrial datasets). O antigo geog.tar.gz
# não existe mais no servidor NCAR/MMM — a URL correta é mpas_static.tar.bz2.
STATIC_URL="https://www2.mmm.ucar.edu/projects/mpas/mpas_static.tar.bz2"
# Opcionais p/ suite UGWP (config_gwdo_scheme='bl_ugwp_gwdo').
TOPO_UGWP_URL="https://www2.mmm.ucar.edu/projects/mpas/topo_ugwp.tar.gz"
UGWP_TAU_URL="https://www2.mmm.ucar.edu/projects/mpas/ugwp_limb_tau.nc"
# GFS 0.25°: NOMADS só mantém ~10 dias; datas antigas usam o arquivo AWS (desde 2021).
NOMADS_BASE="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod"
GFS_ARCHIVE="https://noaa-gfs-bdp-pds.s3.amazonaws.com"

MODE="quick"
GFS_DATE=""   # formato YYYYMMDDHH, ex: 2026010100
# Para previsão global só o f000 é usado como condição inicial (MPAS-A global
# não tem fronteiras laterais). f003/f006 só servem p/ conferência/IAU.
GFS_HOURS="000 003 006"
REGIONAL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) MODE="quick"; shift ;;
    --south-america) MODE="south-america"; shift ;;
    --gfs-date) GFS_DATE="$2"; shift 2 ;;
    --gfs-hours) GFS_HOURS="$2"; shift 2 ;;
    --regional) REGIONAL=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; exit 1 ;;
  esac
done

dl() { # dl <url> <destino>
  if [[ -s "$2" ]]; then echo "[skip] $2 já existe"; return 0; fi
  echo "[dl] $1 -> $2"
  wget --continue -O "$2" "$1" || { rm -f "$2"; return 1; }
}

dl_gfs() { # dl_gfs <YYYYMMDDHH> <dir_destino> <fhh>  — tenta NOMADS e cai p/ arquivo AWS
  local ymdhh="$1" dest="$2" fhh="$3" yyyy mm dd hh file base
  yyyy="${ymdhh:0:4}"; mm="${ymdhh:4:2}"; dd="${ymdhh:6:2}"; hh="${ymdhh:8:2}"
  file="gfs.t${hh}z.pgrb2.0p25.f${fhh}"
  if [[ -s "$dest/$file" ]]; then echo "[skip] $dest/$file já existe"; return 0; fi
  for base in "$NOMADS_BASE/gfs.${yyyy}${mm}${dd}/${hh}/atmos" \
              "$GFS_ARCHIVE/gfs.${yyyy}${mm}${dd}/${hh}/atmos"; do
    echo "[dl] $base/$file -> $dest/$file"
    if wget --continue -O "$dest/$file" "$base/$file" && [[ -s "$dest/$file" ]]; then
      return 0
    fi
    rm -f "$dest/$file"
    echo "[aviso] origem indisponível, tentando a próxima..."
  done
  echo "[erro] GFS $ymdhh f$fhh não encontrado em NOMADS nem no arquivo AWS." >&2
  return 1
}

echo "== MPAS inputs -> $INPUTS (modo: $MODE) =="

if [[ "$MODE" == "quick" ]]; then
  # 240 km, 10.242 células — cabe em qualquer GPU, ideal p/ validar o container P100
  dl "$MESH_BASE/x1.10242.tar.gz" "$INPUTS/x1.10242.tar.gz"
  dl "$MESH_BASE/x1.10242_static.tar.gz" "$INPUTS/x1.10242_static.tar.gz"
  (cd "$INPUTS" && tar xzf x1.10242.tar.gz && tar xzf x1.10242_static.tar.gz)
  echo "Pronto: $INPUTS/x1.10242.grid.nc"
  echo "DICA: aponte streams.init_atmosphere p/ x1.10242.grid.nc e rode com dt=720."
fi

if [[ "$MODE" == "south-america" ]]; then
  # 60-15 km, 535.554 células, refinamento ~55°lat x 110°lon centrado em 0,0.
  # Vamos rotacionar o refinamento p/ América do Sul (-15S, -60W).
  dl "$MESH_BASE/x4.535554.tar.gz" "$INPUTS/x4.535554.tar.gz"
  (cd "$INPUTS" && tar xzf x4.535554.tar.gz)
  echo "[info] Malha extraída. Arquivos:"
  ls -lh "$INPUTS"/x4.535554* | head

  echo "[info] Para centralizar o refinamento na América do Sul, use grid_rotate:"
  echo "  docker compose exec mpas bash -c 'cd /tmp && git clone --depth 1 https://github.com/MPAS-Dev/MPAS-Tools.git && cd MPAS-Tools/mesh_tools/grid_rotate && make'"
  echo "  printf '&input\nconfig_original_latitude_degrees = 0\nconfig_original_longitude_degrees = 0\nconfig_new_latitude_degrees = -15\nconfig_new_longitude_degrees = -60\nconfig_birdseye_rotation_counter_clockwise_degrees = 0\n/\n' > rotate.nl"
  echo "  ./grid_rotate x4.535554.grid.nc SouthAmerica_60-15km.grid.nc < rotate.nl"
  echo "  (depois gere o static com init_atmosphere: config_static_interp=.true.)"

  # Dados geográficos estáticos (2.3 GB; extrai p/ inputs/geog/ removendo o prefixo mpas_static/)
  if [[ -d "$INPUTS/geog/topo_gmted2010_30s" ]]; then
    echo "[skip] $INPUTS/geog/ já contém os dados estáticos"
  else
    dl "$STATIC_URL" "$INPUTS/mpas_static.tar.bz2" \
      && tar xjf "$INPUTS/mpas_static.tar.bz2" -C "$INPUTS/geog" --strip-components=1 \
      || echo "[aviso] mpas_static falhou — veja https://www2.mmm.ucar.edu/projects/mpas/site/downloads/static.html"
  fi
fi

# --- GFS 0.25° (para ungrib -> init_atmosphere) ---
if [[ -n "$GFS_DATE" ]]; then
  if [[ ! "$GFS_DATE" =~ ^[0-9]{10}$ ]]; then
    echo "[erro] --gfs-date deve ser YYYYMMDDHH (ex: 2026010100)" >&2; exit 1
  fi
  echo "[info] Baixando GFS $GFS_DATE (f: $GFS_HOURS, 0.25°). Pode levar vários GB — interrompa se for só teste."
  for FH in $GFS_HOURS; do
    dl_gfs "$GFS_DATE" "$INPUTS" "$FH" || true
  done
  cat <<'EOF'
[próximo passo] Converta GRIB2 -> intermediário com WPS/ungrib:
  docker run --rm -v ./inputs:/data -w /data \
    -e DISPLAY --entrypoint bash wrfchem/wps:latest \
    -c "ln -sf /opt/wps/ungrib.exe . && ln -sf /opt/wps/GFS:Vtable Vtable && ./ungrib.exe"
Ou use o container gbnz/mpas_containerized:v8.2 que já traz ungrib.exe.
Depois aponte config_met_prefix=GFS e rode init_atmosphere_model.
EOF
fi

# --- Recorte regional América Central+Sul via MPAS-Limited-Area ---
if [[ "$REGIONAL" == true ]]; then
  echo "[info] Gerando malha regional lat -60..18, lon -105..-30..."
  pip install --quiet mpas-limited-area 2>/dev/null || pip3 install --quiet mpas-limited-area || true
  python3 - "$INPUTS" <<'PY'
import sys
inp = sys.argv[1]
try:
    from mpas_limited_area import create_region
    create_region(
        parent_mesh=f"{inp}/x4.535554.grid.nc",
        out_mesh=f"{inp}/CentralSouthAmerica.region.grid.nc",
        lat_bounds=(-60, 18), lon_bounds=(-105, -30),
    )
    print("OK: CentralSouthAmerica.region.grid.nc")
except Exception as e:
    print(f"[aviso] MPAS-Limited-Area falhou ({e}).")
    print("Instale manual: pip install mpas-limited-area && veja https://github.com/MPAS-Dev/MPAS-Limited-Area")
PY
  echo "[info] Se gerou a malha regional, ative config_apply_lbcs=.true. nos namelists."
fi

echo "== Concluído. Conteúdo de inputs: =="
ls -lh "$INPUTS" | head -n 30
