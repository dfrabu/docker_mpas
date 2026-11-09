#!/usr/bin/env bash
# make_intermediate.sh — converte GRIB2 do GFS em arquivos intermediários WPS
#   (GFS:YYYY-MM-DD_HH) exigidos pelo init_atmosphere_model (config_init_case=7).
#
# Usa um container com o WPS/ungrib (default: gbnz/mpas_containerized:v8.2).
# Uso:
#   ./scripts/make_intermediate.sh                          # GFS 2026-01-01 00z
#   ./scripts/make_intermediate.sh --gfs-date 2026010100
#   ./scripts/make_intermediate.sh --image <img> --vtable Vtable.GFS
set -euo pipefail

MPAS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUTS="$MPAS_DIR/inputs"
GFS_DATE="2026010100"
IMAGE="gbnz/mpas_containerized:v8.2"
VTABLE="Vtable.GFS"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gfs-date) GFS_DATE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --vtable) VTABLE="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; exit 1 ;;
  esac
done

[[ "$GFS_DATE" =~ ^[0-9]{10}$ ]] || { echo "[erro] --gfs-date deve ser YYYYMMDDHH" >&2; exit 1; }
YYYY="${GFS_DATE:0:4}"; MM="${GFS_DATE:4:2}"; DD="${GFS_DATE:6:2}"; HH="${GFS_DATE:8:2}"
START="${YYYY}-${MM}-${DD}_${HH}:00:00"
START_EPOCH=$(date -u -d "${YYYY}-${MM}-${DD} ${HH}:00:00" +%s)

# Arquivos GRIB2 presentes (baixados por get_inputs.sh) em ordem cronológica.
shopt -s nullglob
GRIBS=("$INPUTS"/gfs.t${HH}z.pgrb2.0p25.f*)
shopt -u nullglob
if [[ ${#GRIBS[@]} -eq 0 ]]; then
  echo "[erro] nenhum GRIB ($INPUTS/gfs.t${HH}z.pgrb2.0p25.f*) — rode ./scripts/get_inputs.sh --south-america --gfs-date $GFS_DATE" >&2
  exit 1
fi
IFS=$'\n' GRIBS=($(printf '%s\n' "${GRIBS[@]}" | sort)); unset IFS
echo "[info] GRIB encontrados: ${#GRIBS[@]} arquivo(s)"
printf '  %s\n' "${GRIBS[@]##*/}"
# end_date cobre exatamente os arquivos presentes (intervalo GFS = 3 h).
END=$(date -u -d "@$(( START_EPOCH + (${#GRIBS[@]} - 1) * 10800 ))" +%Y-%m-%d_%H:%M:%S)

# Comandos de link (ungrib exige GRIBFILE.AAA, .AAB, ... em ordem).
LETTERS=(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z)
LINKS=""
for i in "${!GRIBS[@]}"; do
  [[ $i -lt 26 ]] || { echo "[erro] >26 arquivos GRIB não suportado" >&2; exit 1; }
  LINKS+="ln -sf '/data/${GRIBS[$i]##*/}' GRIBFILE.AA${LETTERS[$i]}"$'\n'
done

echo "[info] Rodando ungrib ($IMAGE) para $START .. $END ..."
docker run --rm -v "$INPUTS":/data -w /tmp/ungrib "$IMAGE" bash -lc "
set -e
rm -rf /tmp/ungrib && mkdir -p /tmp/ungrib && cd /tmp/ungrib
# localiza a Vtable e deriva a raiz do WPS
VT=\$(find / -name '$VTABLE' -type f 2>/dev/null | head -1)
if [[ -z \"\$VT\" ]]; then echo '[erro] $VTABLE não encontrado na imagem' >&2; exit 2; fi
WPS=\$(cd \"\$(dirname \"\$VT\")/../..\" && pwd)
echo \"[info] Vtable: \$VT\"; echo \"[info] WPS: \$WPS\"
UNG=\$WPS/ungrib.exe; [[ -x \"\$UNG\" ]] || UNG=\$WPS/ungrib/ungrib.exe
[[ -x \"\$UNG\" ]] || { echo '[erro] ungrib.exe não encontrado' >&2; exit 3; }
ln -sf \"\$VT\" Vtable
$LINKS
ls -l GRIBFILE.* | head
cat > namelist.wps <<'NML'
&share
 wrf_core = 'ARW',
 max_dom = 1,
 start_date = '$START',
 end_date   = '$END',
 interval_seconds = 10800,
/
&ungrib
 out_format = 'WPS',
 prefix = 'GFS',
/
NML
cat namelist.wps
\"\$UNG\"
ls -lh GFS:* 2>/dev/null || { echo '[erro] ungrib não gerou saída' >&2; exit 4; }
cp -f GFS:* /data/
echo '[ok] intermediários em inputs/:'; ls -lh /data/GFS:*
"

echo "[ok] Intermediários prontos em $INPUTS (GFS:...) — rode: ./scripts/run_mpas.sh --real"
