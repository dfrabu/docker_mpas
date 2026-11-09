#!/usr/bin/env bash
# test_gpu.sh — valida P100 + runtime NVIDIA + binários OpenACC
# Uso:
#   ./scripts/test_gpu.sh           # host + CUDA pequena + container MPAS (sem rodar modelo)
#   ./scripts/test_gpu.sh --full    # + checagens de binários/streams/tabelas
#   ./scripts/test_gpu.sh --smoke   # + roda o smoke-test completo do MPAS (recomendado)
set -euo pipefail

MPAS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FULL=false
SMOKE=false
for a in "$@"; do
  case "$a" in
    --full) FULL=true ;;
    --smoke) SMOKE=true; FULL=true ;;
  esac
done

echo "== Host =="
nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv

echo
echo "== Runtime NVIDIA no Docker (imagem CUDA pequena, sem MPAS) =="
docker run --rm --gpus all nvcr.io/nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi -L

if [[ "$FULL" != true ]]; then
  echo
  echo "OK (teste leve). Para validar dentro do container MPAS:"
  echo "  ./scripts/test_gpu.sh --full"
  exit 0
fi

echo
echo "== Container MPAS =="
COMPOSE=(docker compose -f "$MPAS_DIR/docker-compose.yml")
"${COMPOSE[@]}" up -d mpas >/dev/null
"${COMPOSE[@]}" exec -T mpas bash -lc '
  set -e
  echo "-- nvidia-smi (container) --"; nvidia-smi -L
  echo "-- binários --"; ls -lh /opt/MPAS-Model/atmosphere_model /opt/MPAS-Model/init_atmosphere_model
  echo "-- OpenACC (ldd) --"; ldd /opt/MPAS-Model/atmosphere_model | grep -E "libacc|libcuda" || true
  echo "-- streams oficiais --"; ls /opt/MPAS-Model/default_inputs/streams.atmosphere /opt/MPAS-Model/default_inputs/stream_list.atmosphere.* | head
  echo "-- tabela Noah-MP --"; ls -lh /opt/MPAS-Model/tables/NoahmpTable.TBL
  if command -v nvfortran >/dev/null 2>&1; then
    echo "-- OpenACC hello (compilando com nvfortran cc60) --"
    cat > /tmp/acc_hello.f90 <<EOF
program hello
  use openacc
  print *, "OpenACC NVIDIA devices:", acc_get_num_devices(acc_device_nvidia)
end program
EOF
    nvfortran -acc -gpu=cc60 /tmp/acc_hello.f90 -o /tmp/acc_hello
    CUDA_VISIBLE_DEVICES=0 /tmp/acc_hello
  else
    echo "[info] nvfortran não existe na imagem de runtime (esperado);"
    echo "       a validação real de OpenACC é o smoke-test do modelo."
  fi
'

if [[ "$SMOKE" == true ]]; then
  echo
  echo "== Smoke-test do MPAS (init + atmosphere na GPU) =="
  "$MPAS_DIR/scripts/run_mpas.sh" --smoke
else
  echo
  echo "OK. Para validar OpenACC de verdade: ./scripts/test_gpu.sh --smoke"
fi
