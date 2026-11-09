#!/usr/bin/env bash
# run_mpas.sh — prepara um run dir persistente e roda init + atmosphere (GPU P100)
#
# Uso:
#   ./scripts/run_mpas.sh --smoke               # 240 km, 6 h, ideal (valida GPU/OpenACC)
#   ./scripts/run_mpas.sh --real                # 240 km, 6 h, GFS real (init case 7)
#   ./scripts/run_mpas.sh --real --date 2026010100
#   ./scripts/run_mpas.sh --south-america      # 60-15 km, 72 h (pesado)
#   ./scripts/run_mpas.sh --dry-run            # só mostra o que faria
#
# Opções:
#   --date YYYYMMDDHH  data do GFS intermediário (default 2026010100)
#   --duration D       sobrescreve config_run_duration (ex: 12:00:00)
#   --init-ranks N     ranks MPI só do init_atmosphere (default: auto)
#   --refresh-static   refaz o cache de estáticos (ignora o existente)
#   --no-cache         não usa nem grava cache
#   --require-cache    falha se o cache ainda não existir
#   --init-only        para depois do init_atmosphere (útil p/ gerar cache)
#   --cpu              roda o OpenACC no host (ACC_DEVICE_TYPE=host), sem GPU
#
# Estáticos (cache):
#   O init case 7 com config_static_interp=.true. interpola o geog global 30"
#   (milhares de tiles) e leva ~1 h em 1 rank (~5 min com 8 ranks). Depois do
#   primeiro init, o resultado fica em outputs/static/static.<malha>.nc e os
#   runs seguintes o reutilizam (só GWDO + grade vertical + met): ~6 s.
#
# Logs/namelists ficam em outputs/runs/<UTC>-<modo>/ (persistente, fora do
# container). outputs/latest aponta para o run mais recente.
set -euo pipefail

MPAS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="smoke"
DRY=false
INIT_ONLY=false
CACHE_MODE="auto"          # auto | never | require | off
WRITE_CACHE=true
GFS_DATE=""
DUR_OVERRIDE=""
INIT_RANKS="auto"
ACC_DEVICE=""

usage() { sed -n '2,28p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke)         MODE="smoke"; shift ;;
    --real)          MODE="real"; shift ;;
    --south-america|--sa) MODE="south-america"; shift ;;
    --date|--gfs-date) GFS_DATE="$2"; shift 2 ;;
    --duration)      DUR_OVERRIDE="$2"; shift 2 ;;
    --init-ranks)    INIT_RANKS="$2"; shift 2 ;;
    --refresh-static) CACHE_MODE="never"; WRITE_CACHE=true; shift ;;
    --no-cache)      CACHE_MODE="off";   WRITE_CACHE=false; shift ;;
    --require-cache) CACHE_MODE="require"; shift ;;
    --init-only)     INIT_ONLY=true; shift ;;
    --cpu)           ACC_DEVICE="host"; shift ;;
    --dry-run)       DRY=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# ---- parâmetros por modo -------------------------------------------------- #
case "$MODE" in
  smoke)
    MESH="x1.10242.grid.nc"; DT=720; LENDISP=240000; DUR="06:00:00"
    DECOMP="x1.10242.graph.info.part."; INIT_CASE=1
    ;;
  real)
    MESH="x1.10242.grid.nc"; DT=720; LENDISP=240000; DUR="06:00:00"
    DECOMP="x1.10242.graph.info.part."; INIT_CASE=7
    ;;
  south-america)
    MESH="x4.535554.grid.nc"; DT=90; LENDISP=15000; DUR="72:00:00"
    DECOMP="x4.535554.graph.info.part."; INIT_CASE=7
    ;;
esac
[[ -n "$DUR_OVERRIDE" ]] && DUR="$DUR_OVERRIDE"

# init_atmosphere não usa GPU: paraleliza com MPI se houver decomposição pronta.
# (atmosphere continua com 1 rank = 1 GPU.)
if [[ "$INIT_RANKS" == "auto" ]]; then
  if [[ "$MODE" == "smoke" ]]; then
    INIT_RANKS=1
  elif [[ -f "$MPAS_DIR/inputs/${DECOMP}8" && "$MESH" == x1.* ]]; then
    INIT_RANKS=8
  else
    INIT_RANKS=1
  fi
fi

# Data do GFS (intermediário WPS): YYYYMMDDHH -> 2026-01-01_00:00:00 / GFS:2026-01-01_00
GFS_DATE="${GFS_DATE:-2026010100}"
if [[ ! "$GFS_DATE" =~ ^[0-9]{10}$ ]]; then
  echo "[erro] --date deve ser YYYYMMDDHH (ex: 2026010100)" >&2; exit 1
fi
START="${GFS_DATE:0:4}-${GFS_DATE:4:2}-${GFS_DATE:6:2}_${GFS_DATE:8:2}:00:00"
GFS_TAG="GFS:${GFS_DATE:0:4}-${GFS_DATE:4:2}-${GFS_DATE:6:2}_${GFS_DATE:8:2}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)-${MODE}"
RUN_HOST="$MPAS_DIR/outputs/runs/$STAMP"
RUN_CT="/opt/mpas/outputs/runs/$STAMP"
CACHE_CT="/opt/mpas/outputs/static/static.${MESH}"
CACHE_HOST="$MPAS_DIR/outputs/static/static.${MESH}"

USE_CACHE=false
if [[ "$MODE" != "smoke" ]]; then
  case "$CACHE_MODE" in
    never|off) USE_CACHE=false ;;
    require)   [[ -f "$CACHE_HOST" ]] || { echo "[erro] cache ausente: $CACHE_HOST (rode --refresh-static --init-only)" >&2; exit 1; }
               USE_CACHE=true ;;
    auto)      [[ -f "$CACHE_HOST" ]] && USE_CACHE=true || USE_CACHE=false ;;
  esac
fi

echo "== MPAS $MODE: mesh=$MESH dt=$DT run=$DUR init_case=$INIT_CASE =="
[[ "$MODE" == "smoke" ]] || echo "   GFS=$GFS_TAG  cache_static=$USE_CACHE"
echo "   run dir: outputs/runs/$STAMP  (init em $INIT_RANKS rank(s))"
[[ -n "$ACC_DEVICE" ]] && echo "   atmosphere: ACC_DEVICE_TYPE=$ACC_DEVICE (sem GPU)"

if [[ "$INIT_RANKS" != "1" && ! -f "$MPAS_DIR/inputs/${DECOMP}${INIT_RANKS}" ]]; then
  echo "[erro] decomposição ausente: inputs/${DECOMP}${INIT_RANKS}" >&2
  echo "       use --init-ranks 1 (ou 8/64, que existem para estas malhas)" >&2
  exit 1
fi

# ---- prepara arquivos do run no HOST (ficam persistidos) ------------------ #
mkdir -p "$RUN_HOST" "$MPAS_DIR/outputs/static"
cp -f "$MPAS_DIR/configs/namelist.atmosphere" \
      "$MPAS_DIR/configs/namelist.init_atmosphere" "$RUN_HOST"/

sed -i "s/config_dt *=.*/config_dt = $DT/" "$RUN_HOST/namelist.atmosphere"
sed -i "s/config_len_disp *=.*/config_len_disp = $LENDISP.0/" "$RUN_HOST/namelist.atmosphere"
sed -i "s/config_run_duration *=.*/config_run_duration = '$DUR'/" "$RUN_HOST/namelist.atmosphere"
sed -i "s/config_start_time *=.*/config_start_time = '$START'/" "$RUN_HOST/namelist.atmosphere" "$RUN_HOST/namelist.init_atmosphere"
sed -i "s|config_block_decomp_file_prefix *=.*|config_block_decomp_file_prefix = '/opt/mpas/inputs/$DECOMP'|" \
      "$RUN_HOST/namelist.atmosphere" "$RUN_HOST/namelist.init_atmosphere"

# streams.init_atmosphere: malha (primeira vez) ou cache de estáticos
INIT_INPUT="/opt/mpas/inputs/$MESH"
[[ "$USE_CACHE" == true ]] && INIT_INPUT="$CACHE_CT"
cat > "$RUN_HOST/streams.init_atmosphere" <<EOF
<streams>
<immutable_stream name="input"  type="input"  filename_template="$INIT_INPUT" input_interval="initial_only" />
<!-- saída relativa: fica dentro de outputs/runs/<stamp>/ -->
<immutable_stream name="output" type="output" filename_template="init.nc" output_interval="initial_only" clobber_mode="overwrite" />
</streams>
EOF

# ---- namelist.init_atmosphere -------------------------------------------- #
sed -i "s/config_init_case *=.*/config_init_case = $INIT_CASE/" "$RUN_HOST/namelist.init_atmosphere"
if [[ "$INIT_CASE" == 1 ]]; then
  sed -i "s/config_static_interp *=.*/config_static_interp = .false./; \
          s/config_native_gwd_static *=.*/config_native_gwd_static = .false./; \
          s/config_vertical_grid *=.*/config_vertical_grid = .false./; \
          s/config_met_interp *=.*/config_met_interp = .false./" "$RUN_HOST/namelist.init_atmosphere"
elif [[ "$USE_CACHE" == true ]]; then
  # reaproveita estáticos do cache; recalcula GWDO (rápido, sem geog) + grade
  # vertical + met. GWDO precisa ser recalculado se o cache antigo não o tinha.
  sed -i "s/config_static_interp *=.*/config_static_interp = .false./; \
          s/config_native_gwd_static *=.*/config_native_gwd_static = .true./; \
          s/config_vertical_grid *=.*/config_vertical_grid = .true./; \
          s/config_met_interp *=.*/config_met_interp = .true./; \
          s/config_input_sst *=.*/config_input_sst = .false./; \
          s/config_frac_seaice *=.*/config_frac_seaice = .false./" "$RUN_HOST/namelist.init_atmosphere"
else
  # primeiro init: interpola estáticos do geog global (lento, ~1 h em 1 rank)
  sed -i "s/config_static_interp *=.*/config_static_interp = .true./; \
          s/config_native_gwd_static *=.*/config_native_gwd_static = .true./; \
          s/config_vertical_grid *=.*/config_vertical_grid = .true./; \
          s/config_met_interp *=.*/config_met_interp = .true./; \
          s/config_input_sst *=.*/config_input_sst = .false./; \
          s/config_frac_seaice *=.*/config_frac_seaice = .false./" "$RUN_HOST/namelist.init_atmosphere"
fi

# ---- namelist.atmosphere (smoke = dinâmica seca, sem física) ------------- #
if [[ "$MODE" == "smoke" ]]; then
  sed -i "s/config_physics_suite *=.*/config_physics_suite = 'none'/; \
          s/config_microp_scheme *=.*/config_microp_scheme = 'off'/; \
          s/config_convection_scheme *=.*/config_convection_scheme = 'off'/; \
          s/config_lsm_scheme *=.*/config_lsm_scheme = 'off'/; \
          s/config_pbl_scheme *=.*/config_pbl_scheme = 'off'/; \
          s/config_gwdo_scheme *=.*/config_gwdo_scheme = 'off'/; \
          s/config_radt_lw_scheme *=.*/config_radt_lw_scheme = 'off'/; \
          s/config_radt_sw_scheme *=.*/config_radt_sw_scheme = 'off'/; \
          s/config_sfclayer_scheme *=.*/config_sfclayer_scheme = 'off'/; \
          s/config_radt_cld_scheme *=.*/config_radt_cld_scheme = 'off'/" "$RUN_HOST/namelist.atmosphere"
  cat > "$RUN_HOST/streams.atmosphere" <<'STEOF'
<streams>
<immutable_stream name="input" type="input" filename_template="init.nc" input_interval="initial_only" />
<immutable_stream name="restart" type="input;output" filename_template="restart.$Y-$M-$D_$h.$m.$s.nc" input_interval="initial_only" output_interval="48:00:00" clobber_mode="overwrite" />
<stream name="output" type="output" filename_template="history.$Y-$M-$D_$h.$m.$s.nc" output_interval="3:00:00" io_type="pnetcdf,cdf5" clobber_mode="overwrite">
    <var name="theta" />
    <var name="rho" />
    <var name="u" />
    <var name="w" />
    <var name="surface_pressure" />
</stream>
</streams>
STEOF
fi

# aponta outputs/latest para este run (link relativo, válido no host)
ln -sfn "runs/$STAMP" "$MPAS_DIR/outputs/latest"

# ---- checagens rápidas -------------------------------------------------- #
[[ -f "$MPAS_DIR/inputs/$MESH" ]] \
  || { echo "[erro] malha ausente: inputs/$MESH (rode ./scripts/get_inputs.sh)" >&2; exit 1; }
if [[ "$MODE" != "smoke" ]]; then
  [[ -f "$MPAS_DIR/inputs/$GFS_TAG" ]] \
    || { echo "[erro] intermediário ausente: inputs/$GFS_TAG (rode ./scripts/make_intermediate.sh --gfs-date $GFS_DATE)" >&2; exit 1; }
  if [[ "$USE_CACHE" == false && "$CACHE_MODE" != "never" ]]; then
    echo "[aviso] sem cache de estáticos: o init interpolará o geog 30\" (~1 h)."
  fi
fi

# ---- script executado DENTRO do container -------------------------------- #
CMDS=$(cat <<EOF
set -eo pipefail
cd $RUN_CT
ln -sf /opt/MPAS-Model/atmosphere_model .
ln -sf /opt/MPAS-Model/init_atmosphere_model .
ln -sf /opt/MPAS-Model/tables/* . 2>/dev/null || true
if [[ "$MODE" != "smoke" ]]; then
  ln -sf "/opt/mpas/inputs/$GFS_TAG" .
  # streams/stream_lists OFICIAIS gerados pelo build (default_inputs)
  cp -f /opt/MPAS-Model/default_inputs/streams.atmosphere .
  ln -sf /opt/MPAS-Model/default_inputs/stream_list.atmosphere.* .
  sed -i 's|filename_template="[^"]*\.init\.nc"|filename_template="init.nc"|' streams.atmosphere
  sed -i '0,/output_interval="1_00:00:00"/s//output_interval="48:00:00"/' streams.atmosphere
  sed -i '0,/output_interval="6:00:00"/s//output_interval="3:00:00"/' streams.atmosphere
fi

echo "--- \$(date -u +%T) init_atmosphere (input=$INIT_INPUT, ranks=$INIT_RANKS) ---"
export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
export OMPI_MCA_coll_hcoll_enable=0   # evita erros "Hcol library init failed" no container
mpiexec --allow-run-as-root --bind-to none -n $INIT_RANKS ./init_atmosphere_model 2>&1 | tee console.init.log

if [[ "$USE_CACHE" == false && "$INIT_CASE" == 7 && "$WRITE_CACHE" == true ]]; then
  echo "--- atualizando cache de estáticos: $CACHE_CT ---"
  mkdir -p /opt/mpas/outputs/static
  cp -f init.nc "$CACHE_CT"
  ls -lh "$CACHE_CT"
fi

if [[ "$INIT_ONLY" == true ]]; then
  echo "--- init-only: parando aqui ---"
  exit 0
fi

echo "--- \$(date -u +%T) atmosphere (OpenACC, 1 rank; device=${ACC_DEVICE:-nvidia}) ---"
${ACC_DEVICE:+export ACC_DEVICE_TYPE=$ACC_DEVICE}
nvidia-smi -L || true
CUDA_VISIBLE_DEVICES=0 mpiexec --allow-run-as-root --bind-to none -n 1 ./atmosphere_model 2>&1 | tee console.atmosphere.log

echo "--- \$(date -u +%T) outputs ---"
ls -lh init.nc history.*.nc diag.*.nc 2>/dev/null | tail -20 || true
grep -h "Critical error messages" log.*.out | tail -4 || true
EOF
)

if [[ "$DRY" == true ]]; then
  echo "-------- arquivos do run --------"
  ls -l "$RUN_HOST"
  echo "-------- comandos no container --------"
  echo "$CMDS"
  exit 0
fi

docker compose -f "$MPAS_DIR/docker-compose.yml" up -d mpas >/dev/null
docker compose -f "$MPAS_DIR/docker-compose.yml" exec -T mpas bash -c "$CMDS"

echo ""
echo "OK ($MODE). Run/logs: outputs/runs/$STAMP/"
echo "Saídas:     outputs/runs/$STAMP/ (init.nc, history.*.nc, diag.*.nc, logs)"
echo "Visualize:  make viz    (ou ./scripts/viz.sh --all)"
