#!/usr/bin/env bash
# gifviz.sh — gera GIFs animados (quadros de 3 em 3 h) no container de visualização
#
# Uso:
#   ./scripts/gifviz.sh                      # anima t2m
#   ./scripts/gifviz.sh --all                # t2m, pressão, precipitação e vento
#   ./scripts/gifviz.sh --var t2m,precip
#   ./scripts/gifviz.sh --outputs outputs/runs/20261109T...-real --all
#   ./scripts/gifviz.sh --build --all        # reconstrói a imagem mpas-viz
#
# Saída: outputs/figs/<var>_anim.gif
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
  echo "[gifviz] construindo $IMAGE (só na primeira vez / com --build)..."
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
  "$IMAGE" python3 scripts/make_gif.py --figdir outputs/figs "${ARGS[@]}"
