#!/usr/bin/env bash
# viz.sh — roda scripts/visualize.py dentro de um container (sem instalar nada no host)
#
# Uso:
#   ./scripts/viz.sh --all
#   ./scripts/viz.sh --var t2m
#   ./scripts/viz.sh --build --all   # reconstrói a imagem de visualização
#   ./scripts/viz.sh --outputs outputs/runs/20260101T000000Z-real --all
#
# Saída: outputs/figs/*.png (estável, independente do run).
set -euo pipefail

MPAS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="mpas-viz:latest"
BUILD=false
ARGS=()
HAS_OUTPUTS=false

for a in "$@"; do
  case "$a" in
    --build) BUILD=true ;;
    --outputs) HAS_OUTPUTS=true; ARGS+=("$a") ;;
    *) ARGS+=("$a") ;;
  esac
done

if [[ "$BUILD" == true ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[viz] construindo $IMAGE (só na primeira vez / com --build)..."
  docker build -f "$MPAS_DIR/docker/viz.Dockerfile" -t "$IMAGE" "$MPAS_DIR"
fi

if [[ "$HAS_OUTPUTS" == false ]]; then
  [[ -e "$MPAS_DIR/outputs/latest" ]] || {
    echo "[erro] outputs/latest não existe. Rode um modelo primeiro (make smoke/real)." >&2
    exit 1
  }
  ARGS=(--outputs outputs/latest "${ARGS[@]}")
fi

mkdir -p "$MPAS_DIR/outputs/figs"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e MPLCONFIGDIR=/tmp/mpl \
  -v "$MPAS_DIR:/work" -w /work \
  "$IMAGE" python3 scripts/visualize.py --figdir outputs/figs "${ARGS[@]}"
