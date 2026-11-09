#!/usr/bin/env bash
# watch.sh — acompanha o run mais recente (progresso do init / log do atmosphere)
#
# Uso:
#   ./scripts/watch.sh            # tail do log principal (Ctrl-C para sair)
#   ./scripts/watch.sh --status   # só imprime o resumo e sai
set -euo pipefail
MPAS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$(readlink -f "$MPAS_DIR/outputs/latest" 2>/dev/null || true)"
[[ -n "$RUN" && -d "$RUN" ]] || { echo "[erro] nenhum run em outputs/latest" >&2; exit 1; }

echo "run: $RUN"
ls -lh "$RUN"/init.nc "$RUN"/history.*.nc 2>/dev/null | tail -5 || true

INIT_LOG="$(ls -t "$RUN"/log.init_atmosphere.*.out 2>/dev/null | head -1 || true)"
ATM_LOG="$(ls -t "$RUN"/log.atmosphere.*.out 2>/dev/null | head -1 || true)"
if [[ -n "$INIT_LOG" ]]; then
  echo "init: $(grep -c 'Processing tile' "$INIT_LOG" 2>/dev/null || echo 0) tiles processados"
fi
[[ "${1:-}" == "--status" ]] && exit 0

if [[ -n "$ATM_LOG" ]]; then
  echo "--- atmosphere ---"
  tail -f "$ATM_LOG"
elif [[ -n "$INIT_LOG" ]]; then
  echo "--- init (Ctrl-C para sair) ---"
  tail -f "$INIT_LOG"
else
  echo "[info] ainda sem logs; aguardando..."
  ls -lt "$RUN" | head
fi
