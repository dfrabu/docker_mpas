# MPAS-Atmosphere na NVIDIA Tesla P100 — `~/mpas`

Setup Docker + GPU para rodar o **MPAS-Atmosphere v8.4.2** com a dinâmica
acelerada por **OpenACC** na **Tesla P100 16GB (Pascal, sm_60)** desta máquina
(Ubuntu 24.04, driver 580.x, Docker + Compose, runtime `nvidia`).

## Estado atual (validado nesta máquina)

- Imagem `mpas-atmosphere:8.4.2-p100`: MPAS 8.4.2 + NVHPC 23.11, `-gpu=cc60`.
- `atmosphere_model` roda na P100 (log confirma `OpenACC support: yes`,
  `Device name: Tesla P100-PCIE-16GB`).
- `make smoke` conclui init + 6 h de dinâmica em segundos.
- `init_atmosphere` com dados reais leva **~6 s** quando o cache de estáticos
  existe; sem cache, a primeira interpolação do geog 30" leva ~1 h em 1 rank
  (ou ~5 min com 8 ranks, já automatizado).
- Saídas, namelists e logs de cada execução ficam em `outputs/runs/<UTC>-<modo>/`.

## 1. Começo rápido

```bash
cd ~/mpas

make doctor          # host, driver, GPU, imagem, inputs e cache
make build           # reconstrói a imagem (reaproveita o cache do builder)
make smoke           # init + atmosphere ideal: valida OpenACC/P100
make viz             # figuras em outputs/figs/
```

`make doctor --smoke` (na verdade `./scripts/doctor.sh --smoke`) faz o
diagnóstico e já roda o smoke.

## 2. Dados reais (GFS) — fluxo completo

```bash
# 1) malha 240 km + GFS da data desejada (YYYYMMDDHH)
make gfs GFS_DATE=2026010100

# 2) GRIB2 -> intermediários WPS (GFS:2026-01-01_00) usando ungrib no container
make intermediate GFS_DATE=2026010100

# 3) UMA vez por malha: gera o cache de estáticos (geog 30")
#    ~5 min com 8 ranks; sem isso o init interpola ~1 h
make static-cache GFS_DATE=2026010100

# 4) roda 6 h na GPU (init ~6 s + atmosphere)
make real GFS_DATE=2026010100

# 5) figuras
make viz
```

Sem `GFS_DATE` o padrão é `2026010100` (data dos dados já presentes em `inputs/`).

### Previsão de 48 h a partir de hoje

```bash
# ciclo GFS mais recente disponível (YYYYMMDDHH, UTC)
make forecast48 GFS_DATE=2026110906

# outro horizonte
make forecast48 GFS_DATE=2026110906 DURATION=24:00:00
```

O alvo baixa **só o f000** (MPAS-A global não usa fronteiras laterais), roda o
ungrib, o init com cache e 48 h de modelo na GPU. A previsão fica em
`outputs/runs/<UTC>-real/` e as figuras em `outputs/figs/` (`make viz`).

Ciclos GFS ficam prontos ~3,5 h após o horário nominal (00Z ≈ 03:30 UTC,
06Z ≈ 10:30 UTC, 12Z ≈ 15:30 UTC, 18Z ≈ 22:30 UTC). `make gfs-full` baixa
também f003/f006 (não necessários para o run global).

> Atenção: a x1 tem 240 km — serve para padrões sinóticos, não para previsão
> local. Detalhe regional exige a malha x4 (60–15 km).

### Animação (GIF)

```bash
make gifviz                                  # t2m, pressão, precipitação, vento
./scripts/gifviz.sh --var t2m,precip         # só as escolhidas
./scripts/gifviz.sh --stride 2 --duration-ms 600
```

Cada GIF usa **um quadro por `history`** (3 h) e **escala de cores fixa** no
tempo, para a animação não "piscar". Saída em `outputs/figs/<var>_anim.gif`.
Variáveis disponíveis: as mesmas do `visualize.py` (`t2m`, `theta`, `mslp`,
`surface_pressure`, `precip`, `wind`, `qv`, `relhum`, `olrtoa`, ...).

### Por que existe o cache de estáticos?

O `init_atmosphere` com `config_static_interp=.true.` lê e interpola o dataset
geográfico global de 30" (milhares de tiles em `inputs/geog/`). Isso é **CPU-only
e single-thread**: é o passo que parece “travado” (fica 1 h em 1 rank, com o log
mostrando `Processing tile: ...`).

O script guarda o resultado em:

```
outputs/static/static.x1.10242.grid.nc   # 240 km
outputs/static/static.x4.535554.grid.nc  # 60-15 km
```

Nas execuções seguintes ele usa esse arquivo como entrada, recalcula apenas
**GWDO + grade vertical + interpolação meteorológica** (segundos). O cache é
específico da malha, não da data.

Opções úteis:

```bash
./scripts/run_mpas.sh --real --refresh-static --init-only --init-ranks 8
./scripts/run_mpas.sh --real --require-cache      # falha se o cache não existir
./scripts/run_mpas.sh --real --no-cache           # ignora/ não grava cache
./scripts/run_mpas.sh --real --duration 12:00:00 --date 2026010100
```

## 3. Malha de produção América Central + Sul (60–15 km)

```bash
make inputs-sa                 # x4.535554 (535.554 células) + geog 30"
make static-cache-sa           # cache da malha x4 (64 ranks; demorado)
make sa                        # 72 h a 90 s
```

O refinamento da `x4.535554` é centrado em (0,0). Para centralizar na América
do Sul, rotacione a malha com `MPAS-Tools/grid_rotate` (comando abaixo) e ajuste
`MESH`/`DECOMP` no `scripts/run_mpas.sh` ou use a malha regional.

```bash
docker compose exec mpas bash -c '
  cd /tmp && git clone --depth 1 https://github.com/MPAS-Dev/MPAS-Tools.git &&
  cd MPAS-Tools/mesh_tools/grid_rotate && make'
printf '&input\nconfig_original_latitude_degrees = 0\nconfig_original_longitude_degrees = 0\nconfig_new_latitude_degrees = -15\nconfig_new_longitude_degrees = -60\nconfig_birdseye_rotation_counter_clockwise_degrees = 0\n/\n' > rotate.nl
# ./grid_rotate x4.535554.grid.nc SouthAmerica_60-15km.grid.nc < rotate.nl
```

## 4. Comandos (Makefile)

| Comando | O que faz |
|---|---|
| `make doctor` | diagnóstico de host/GPU/imagem/inputs/cache |
| `make build` / `build-nocache` | constrói a imagem (cache do builder / do zero) |
| `make up` / `down` / `shell` | sobe, derruba, entra no container |
| `make test` | valida GPU + binários OpenACC dentro do container |
| `make inputs-quick` / `inputs-sa` | baixa malhas/estáticos (240 km / 60–15 km) |
| `make gfs GFS_DATE=...` | baixa GFS f000 0.25° (só o necessário p/ o run global) |
| `make gfs-full GFS_DATE=...` | baixa também f003/f006 |
| `make intermediate GFS_DATE=...` | GRIB2 → intermediários WPS (`ungrib`) |
| `make forecast48 GFS_DATE=...` | pipeline completo: GFS → ungrib → 48 h na GPU |
| `make static-cache [GFS_DATE=...]` | gera cache de estáticos da x1 (8 ranks) |
| `make static-cache-sa` | idem para a x4 (64 ranks) |
| `make smoke` | run ideal de 6 h (valida GPU) |
| `make real GFS_DATE=...` | run real de 6 h na x1 |
| `make sa GFS_DATE=...` | run de produção na x4 |
| `make viz` / `viz-build` | figuras (container Python com netCDF4/cartopy) |
| `make gifviz` | GIFs animados 3-em-3 h (t2m, pressão, chuva, vento) |
| `make logs` / `latest` / `outputs` | inspeciona runs e saídas |
| `make watch` | acompanha ao vivo o log do último run |
| `make cpu` | fallback CPU (`gbnz/mpas_containerized:v8.2`) |

## 5. Estrutura

```
~/mpas/
  Dockerfile               # MPAS 8.4.2 + NVHPC OpenACC cc60
  docker/viz.Dockerfile    # imagem só p/ visualização (netCDF4/cartopy)
  docker-compose.yml       # serviço mpas (GPU) + mpas-cpu (fallback)
  Makefile                 # atalhos (ver make help)
  configs/                 # templates de namelist/streams
  inputs/                  # malhas, geog, GFS, intermediários (rw)
  outputs/
    runs/<UTC>-<modo>/     # namelists, logs, init.nc, history/diag
    static/                # cache de estáticos por malha
    figs/                  # figuras
    latest -> runs/...     # último run
  scripts/
    doctor.sh              # diagnóstico
    get_inputs.sh          # malhas/geog/GFS
    make_intermediate.sh   # ungrib (GRIB2 -> WPS)
    run_mpas.sh            # orquestra init+atmosphere, cache, run dirs
    test_gpu.sh            # GPU/OpenACC no container
    viz.sh                 # visualize.py em container
    gifviz.sh              # make_gif.py em container (GIFs animados)
    make_gif.py            # animação com escala de cores fixa entre quadros
    visualize.py           # figuras (contorno/vetor) da América Central+Sul
  logs/                    # logs de build
```

## 6. Detalhes do build

- Base: `nvcr.io/nvidia/nvhpc:23.11-devel-cuda_multi-ubuntu22.04`
  (última série com bom suporte a Pascal; SDKs 25.x+ exigem sm_70+).
- Dependências: HDF5 1.14.3, PnetCDF 1.12.3, netCDF-C 4.9.2,
  netCDF-Fortran 4.6.1, PIO2 2.6.5.
- MPAS: `make nvhpc CORE=atmosphere OPENACC=true USE_PIO2=true PRECISION=single`.
- O Makefile é ajustado de `-gpu=cc70,cc80` para `-gpu=cc60`.
- A imagem final copia também `default_inputs/` (streams oficiais gerados pelo
  Registry) e `NoahmpTable.TBL` — ambos necessários para física real.
- `.dockerignore` mantém o contexto de build em poucos KB (sem `inputs/`).

## 7. Solução de problemas

**Init “travado” em `Processing tile`** — não está travado; é a interpolação
estática. Use o cache (`make static-cache` uma vez) ou `--init-ranks 8`.
Acompanhe:

```bash
make logs
tail -f outputs/latest/log.init_atmosphere.0000.out
```

**`The YSU GWDO scheme requires valid var2d, con, oa..., ol...`** — o
`init.nc`/cache foi gerado sem GWDO. Rode com `--refresh-static` (o modo cache
recalcula GWDO automaticamente).

**`Cannot find file NoahmpTable.TBL`** — imagem antiga; `make build` copia a
tabela do Noah-MP para `/opt/MPAS-Model/tables/`.

**`Requested field qv not available` / streams inválidos** — use a imagem com
`default_inputs/` (o `run_mpas.sh` já usa os streams oficiais para runs reais).

**Aviso `Open MPI tried to bind a process but failed`** — inofensivo no
container; os comandos usam `--bind-to none`.

**`Hcol library init failed`** — suprimido com
`OMPI_MCA_coll_hcoll_enable=0` no `run_mpas.sh`.

**P100 / 16 GB** — use 1 rank MPI para o `atmosphere_model`
(`CUDA_VISIBLE_DEVICES=0`). O `init_atmosphere` não usa GPU e pode usar mais
ranks. `config_gpu_aware_mpi=false` é o padrão.

**Arquivos >4 GB** — `streams` usam PIO/PnetCDF; para a x4 acompanhe o espaço em
disco (uma saída de 72 h pode passar de dezenas de GB).

## 8. Referências

- MPAS-Atmosphere User's Guide v8.2 / cap. 8 (GPU: `make nvhpc OPENACC=true`)
- Meshes: https://www2.mmm.ucar.edu/projects/mpas/site/downloads/meshes.html
- MPAS-Model v8.4.2: https://github.com/MPAS-Dev/MPAS-Model/releases
- NGC HPC SDK: `nvcr.io/nvidia/nvhpc:23.11-devel-cuda_multi-ubuntu22.04`
- Fallback CPU: `gbnz/mpas_containerized:v8.2` (Docker Hub)
# docker_mpas
