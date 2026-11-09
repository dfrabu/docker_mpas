#!/usr/bin/env bash
# doctor.sh — diagnóstico do setup MPAS/P100 (rápido, sem build)
#
# Uso:
#   ./scripts/doctor.sh            # checa host, Docker, GPU, imagem, inputs, cache
#   ./scripts/doctor.sh --smoke    # além disso roda o smoke-test completo
set -uo pipefail

MPAS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SMOKE=false
[[ "${1:-}" == "--smoke" ]] && RUN_SMOKE=true

FAIL=0
WARN=0
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "== Host =="
command -v docker >/dev/null && ok "docker $(docker --version | awk '{print $3}' | tr -d ,)" || bad "docker não encontrado"
if command -v nvidia-smi >/dev/null; then
  GPU_INFO=$(nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv,noheader 2>/dev/null || true)
  if [[ -n "$GPU_INFO" ]]; then
    echo "$GPU_INFO" | sed 's/^/  /'
    CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    [[ "$CC" == "6.0" ]] && ok "P100 (cc${CC}) — build em -gpu=cc60" || warn "compute capability $CC (o build está em cc60)"
  else
    bad "GPU não respondeu ao nvidia-smi (driver/Xid 79? 'fallen off the bus'?) — reinicie a máquina"
  fi
else
  bad "nvidia-smi não encontrado (driver NVIDIA?)"
fi
FREE_GB=$(df -BG --output=avail "$MPAS_DIR" | tail -1 | tr -dc '0-9')
[[ "${FREE_GB:-0}" -ge 20 ]] && ok "espaço livre em $MPAS_DIR: ${FREE_GB}G" || warn "espaço livre baixo: ${FREE_GB}G (recomendado >20G)"
ok "RAM: $(free -g | awk '/^Mem/{print $2"G total, "$7"G disponível"}')"
ok "CPUs: $(nproc)"

echo "== Docker / Compose =="
if docker info >/dev/null 2>&1; then
  ok "daemon Docker acessível"
else
  bad "sem acesso ao daemon Docker (grupo docker?)"
fi
docker compose -f "$MPAS_DIR/docker-compose.yml" config -q 2>/dev/null \
  && ok "docker-compose.yml válido" || bad "docker-compose.yml inválido"
if docker image inspect mpas-atmosphere:8.4.2-p100 >/dev/null 2>&1; then
  ok "imagem mpas-atmosphere:8.4.2-p100 ($(docker image inspect -f '{{.Size}}' mpas-atmosphere:8.4.2-p100 | awk '{printf "%.1fG", $1/1e9}'))"
else
  bad "imagem ausente — rode: make build"
fi

echo "== Container MPAS + GPU =="
if docker image inspect mpas-atmosphere:8.4.2-p100 >/dev/null 2>&1; then
  docker compose -f "$MPAS_DIR/docker-compose.yml" up -d mpas >/dev/null 2>&1
  if docker compose -f "$MPAS_DIR/docker-compose.yml" exec -T mpas bash -lc 'nvidia-smi -L' 2>/dev/null | grep -q GPU; then
    ok "GPU visível dentro do container"
  else
    bad "GPU não visível no container (runtime nvidia / deploy.resources?)"
  fi
  for b in atmosphere_model init_atmosphere_model; do
    docker compose -f "$MPAS_DIR/docker-compose.yml" exec -T mpas test -x "/opt/MPAS-Model/$b" \
      && ok "binário $b" || bad "binário $b ausente"
  done
  if docker compose -f "$MPAS_DIR/docker-compose.yml" exec -T mpas bash -lc 'ldd /opt/MPAS-Model/atmosphere_model 2>/dev/null | grep -q libaccdevice'; then
    ok "atmosphere_model linkado com OpenACC (libaccdevice)"
  else
    warn "não encontrei libaccdevice no ldd — binário pode ser CPU-only"
  fi
  docker compose -f "$MPAS_DIR/docker-compose.yml" exec -T mpas test -f /opt/MPAS-Model/default_inputs/streams.atmosphere \
    && ok "streams.atmosphere oficial presente" || bad "default_inputs/streams.atmosphere ausente (rebuild)"
  docker compose -f "$MPAS_DIR/docker-compose.yml" exec -T mpas test -f /opt/MPAS-Model/tables/NoahmpTable.TBL \
    && ok "tabela NoahmpTable.TBL presente" || bad "NoahmpTable.TBL ausente (rebuild)"
fi

echo "== Inputs =="
for f in x1.10242.grid.nc x4.535554.grid.nc; do
  [[ -f "$MPAS_DIR/inputs/$f" ]] && ok "malha inputs/$f" || warn "malha ausente: inputs/$f"
done
[[ -d "$MPAS_DIR/inputs/geog/topo_gmted2010_30s" ]] \
  && ok "geog 30s (inputs/geog)" || warn "geog 30s ausente (só necessário p/ gerar cache)"
shopt -s nullglob
GFS=("$MPAS_DIR"/inputs/GFS:*)
shopt -u nullglob
if ((${#GFS[@]})); then
  ok "intermediários GFS: ${#GFS[@]} arquivo(s)"
else
  warn "sem intermediários GFS (rode: make gfs && make intermediate)"
fi
for m in x1.10242.grid.nc x4.535554.grid.nc; do
  c="$MPAS_DIR/outputs/static/static.$m"
  if [[ -f "$c" ]]; then
    ok "cache de estáticos $m ($(du -h "$c" | cut -f1))"
  else
    warn "sem cache de estáticos $m — o próximo init interpolará o geog (~1 h)"
  fi
done

echo ""
if ((FAIL)); then
  echo "== $FAIL falha(s), $WARN aviso(s) =="
  exit 1
fi
echo "== OK ($WARN aviso(s)) =="

if [[ "$RUN_SMOKE" == true ]]; then
  echo ""
  echo "== smoke-test completo (init + atmosphere na GPU) =="
  "$MPAS_DIR/scripts/run_mpas.sh" --smoke
fi
