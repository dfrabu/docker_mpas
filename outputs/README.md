# outputs/ — saídas do modelo e artefatos de execução

Estrutura criada por `scripts/run_mpas.sh`:

```
outputs/
  runs/<UTC>-<modo>/     # init.nc, history.*.nc, diag.*.nc, logs, namelists
  static/                # cache de estáticos por malha (reuso no init)
  figs/                  # figuras geradas por scripts/visualize.py
  latest -> runs/...     # symlink para o último run
```

- O run dir é persistente (fica no host, não na camada gravável do container).
- `outputs/latest` é usado por `make viz` / `scripts/viz.sh`.
- O cache `static/static.<malha>.nc` acelera o init real de ~1 h para ~6 s.

Comandos úteis:

```bash
make logs          # lista runs e conteúdo do último
make latest        # caminho absoluto do último run
make viz           # gera outputs/figs/*.png
```
