# Makefile — atalhos para o setup MPAS-Atmosphere + Tesla P100
#
#   make help
#   make doctor            # diagnóstico do host/container/inputs
#   make build             # reconstrói a imagem (cache do builder é reaproveitado)
#   make smoke             # teste rápido validando GPU/OpenACC
#   make real GFS_DATE=2026010100
#   make forecast48 GFS_DATE=2026110906   # previsão de 48 h a partir do GFS
#   make viz
#   make gifviz                            # animação 3-em-3 h em GIF
#
SHELL       := /bin/bash
COMPOSE     ?= docker compose
MPAS_DIR    := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
GFS_DATE    ?= 2026010100
DURATION    ?= 48:00:00
STAMP       := $(shell date -u +%Y%m%dT%H%M%SZ)

.DEFAULT_GOAL := help

.PHONY: help doctor build build-nocache up down restart shell ps \
        test inputs-quick inputs-sa gfs gfs-full intermediate \
        static-cache static-cache-sa smoke real sa forecast forecast48 forecast-sa \
        viz viz-build gifviz cpu logs latest outputs watch

help:
	@sed -n '2,11p' Makefile | sed 's/^# \{0,1\}//'

doctor:
	./scripts/doctor.sh

build:
	@mkdir -p logs
	$(COMPOSE) build 2>&1 | tee logs/build-$(STAMP).log

build-nocache:
	@mkdir -p logs
	$(COMPOSE) build --no-cache 2>&1 | tee logs/build-nocache-$(STAMP).log

up:
	$(COMPOSE) up -d mpas

down:
	$(COMPOSE) down

restart: down up

shell:
	$(COMPOSE) exec mpas bash

ps:
	$(COMPOSE) ps

test:
	./scripts/test_gpu.sh --full

# ---- entradas ----------------------------------------------------------- #
inputs-quick:
	./scripts/get_inputs.sh --quick

inputs-sa:
	./scripts/get_inputs.sh --south-america

# baixa GFS f000 da data pedida (só o f000 é usado como condição inicial;
# MPAS-A global não precisa de fronteiras laterais)
gfs:
	./scripts/get_inputs.sh --quick --gfs-date $(GFS_DATE) --gfs-hours 000

gfs-full:
	./scripts/get_inputs.sh --quick --gfs-date $(GFS_DATE) --gfs-hours "000 003 006"

intermediate:
	./scripts/make_intermediate.sh --gfs-date $(GFS_DATE)

# gera o cache de estáticos (interpolação geog 30", lento: 1x por malha).
# init paraleliza com MPI (x1: 8 ranks; x4: 64 ranks já vêm na malha).
static-cache:
	./scripts/run_mpas.sh --real --date $(GFS_DATE) --refresh-static --init-only --init-ranks 8

static-cache-sa:
	./scripts/run_mpas.sh --south-america --date $(GFS_DATE) --refresh-static --init-only --init-ranks 64

# ---- execução ----------------------------------------------------------- #
smoke:
	./scripts/run_mpas.sh --smoke

real:
	./scripts/run_mpas.sh --real --date $(GFS_DATE)

# previsão de 48 h a partir do ciclo GFS pedido (baixa f000, ungrib, roda na GPU)
#   make forecast48 GFS_DATE=2026110906
forecast48: gfs intermediate
	./scripts/run_mpas.sh --real --date $(GFS_DATE) --duration $(DURATION)
	@echo "Figuras: make viz"

sa:
	./scripts/run_mpas.sh --south-america --date $(GFS_DATE)

# pipeline completo para uma data (baixa GFS, ungrib, roda, plota)
forecast: gfs intermediate real viz

forecast-sa: inputs-sa static-cache-sa sa viz

# ---- visualização ------------------------------------------------------- #
viz:
	./scripts/viz.sh --all

viz-build:
	./scripts/viz.sh --build --all

# animação: um GIF por variável, quadros de 3 em 3 h (t2m, pressão, chuva, vento)
gifviz:
	./scripts/gifviz.sh --all

# ---- inspeção ----------------------------------------------------------- #
watch:
	./scripts/watch.sh

logs:
	@ls -lt outputs/runs 2>/dev/null | head -20
	@echo "--- último run ---"
	@ls -lh outputs/latest/ 2>/dev/null | tail -20

latest:
	@readlink -f outputs/latest 2>/dev/null || echo "nenhum run ainda"

outputs:
	@ls -lh outputs/latest/ 2>/dev/null || echo "nenhum run ainda"

cpu:
	$(COMPOSE) --profile cpu up -d mpas-cpu
