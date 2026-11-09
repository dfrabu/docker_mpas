# Dockerfile MPAS-Atmosphere 8.4.2 com OpenACC para NVIDIA Tesla P100 (Pascal, cc60, 16GB)
#
# ESTRATÉGIA:
# - Não existe imagem oficial GPU do MPAS no Docker Hub.
#   A única imagem comunitária madura é CPU-only: gbnz/mpas_containerized:v8.2
# - Aqui construímos MPAS v8.4.2 (primeira série com núcleo dinâmico GPU via OpenACC,
#   documentado como testado em V100/A100/H100 com NVHPC) sobre o HPC SDK da NVIDIA.
# - Tesla P100 = arquitetura Pascal, compute capability 6.0 (sm_60).
#   Versões novas do HPC SDK (25.x+) exigem sm_70+ (Turing/Ampere/Hopper/Blackwell),
#   por isso PINAMOS a base em 23.11 (CUDA 11.8 + 12.3), última série com bom suporte a Pascal.
#   Driver do host 580.x é compatível (driver >= runtime).
#
# Build:  docker compose build
#         (leva 30-90 min na primeira vez, ~15 GB)
# Fallback CPU puro: ver serviço "mpas-cpu" no docker-compose.yml

ARG NVHPC_TAG=23.11-devel-cuda_multi-ubuntu22.04
FROM nvcr.io/nvidia/nvhpc:${NVHPC_TAG} AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    MPAS_VERSION=8.4.2 \
    PIO_VERSION=pio2_6_5 \
    PNETCDF_VERSION=1.12.3 \
    NETCDF_C_VERSION=4.9.2 \
    NETCDF_F_VERSION=4.6.1 \
    HDF5_VERSION=1.14.3 \
    OPT=/opt/mpas-deps \
    MPAS_ROOT=/opt/MPAS-Model

# --- dependências de sistema ---
# NOTA: 'cmake' é obrigatório p/ compilar PIO2 logo abaixo.
RUN apt-get update && apt-get install -y --no-install-recommends \
      wget curl git ca-certificates build-essential pkg-config cmake \
      zlib1g-dev libcurl4-openssl-dev libssl-dev libxml2-dev \
      python3 python3-pip file \
    && rm -rf /var/lib/apt/lists/*

# NVHPC já traz nvc/nvc++/nvfortran + OpenMPI + HPC-X em /opt/nvidia/hpc_sdk
# Garante que estão no PATH (caminho varia por versão; 23.11 = Linux_x86_64/23.11)
ENV PATH=/opt/nvidia/hpc_sdk/Linux_x86_64/23.11/compilers/bin:/opt/nvidia/hpc_sdk/Linux_x86_64/23.11/comm_libs/mpi/bin:${PATH} \
    MANPATH=/opt/nvidia/hpc_sdk/Linux_x86_64/23.11/compilers/man:${MANPATH}

WORKDIR /tmp/build

# --- HDF5 (necessário p/ netCDF4) ---
# Fonte: tarball oficial do HDFGroup. (O GitHub do HDFGroup NÃO tem a tag
# 'hdf5_1.14.3' — o wget recebia 404, que era o 'exit code: 8' anterior.
# 'curl -fSL' falha com mensagem clara em vez de silencioso.)
# I/O paralelo exige wrappers MPI (mpicc/mpifort); nvc puro reprova no teste
# de MPI do configure (era o 'exit code: 1'). Mesma toolchain das demais libs.
RUN HDF5_MM="${HDF5_VERSION%.*}" && \
    command -v mpicc && command -v mpifort && \
    curl -fSL "https://support.hdfgroup.org/ftp/HDF5/releases/hdf5-${HDF5_MM}/hdf5-${HDF5_VERSION}/src/hdf5-${HDF5_VERSION}.tar.gz" -o hdf5.tar.gz && \
    tar xzf hdf5.tar.gz && cd hdf5-${HDF5_VERSION} && \
    CC=mpicc FC=mpifort CFLAGS="-fPIC" FCFLAGS="-fPIC" FFLAGS="-fPIC" ./configure --prefix=${OPT} --enable-fortran --enable-parallel --with-pic || { echo '=== configure falhou; tail de config.log ==='; tail -n 80 config.log; exit 1; } && \
    make -j$(nproc) && make install && rm -f ${OPT}/lib/*.la && cd /tmp/build && rm -rf hdf5*

# --- PnetCDF (I/O paralelo do MPAS) ---
RUN wget -q https://parallel-netcdf.github.io/Release/pnetcdf-${PNETCDF_VERSION}.tar.gz && \
    tar xzf pnetcdf-${PNETCDF_VERSION}.tar.gz && cd pnetcdf-${PNETCDF_VERSION} && \
    CC=mpicc FC=mpifort CFLAGS="-fPIC" CXXFLAGS="-fPIC" FCFLAGS="-fPIC" FFLAGS="-fPIC" ./configure --prefix=${OPT} || { echo '=== PnetCDF configure falhou; tail de config.log ==='; tail -n 60 config.log; exit 1; } && \
    make -j$(nproc) && make install && rm -f ${OPT}/lib/*.la && cd /tmp/build && rm -rf pnetcdf*

# --- netCDF-C ---
RUN wget -q https://github.com/Unidata/netcdf-c/archive/refs/tags/v${NETCDF_C_VERSION}.tar.gz -O netcdf-c.tar.gz && \
    tar xzf netcdf-c.tar.gz && cd netcdf-c-${NETCDF_C_VERSION} && \
    CC=mpicc CPPFLAGS="-I${OPT}/include" LDFLAGS="-L${OPT}/lib" \
    ./configure --prefix=${OPT} --enable-parallel-tests --enable-netcdf-4 --with-hdf5=${OPT} --enable-pnetcdf --with-pnetcdf=${OPT} || { echo '=== netCDF-C configure falhou; tail de config.log ==='; tail -n 80 config.log; exit 1; } && \
    make -j$(nproc) && make install && rm -f ${OPT}/lib/*.la && cd /tmp/build && rm -rf netcdf-c*

# --- netCDF-Fortran (DEVE usar os mesmos compiladores NVHPC) ---
# FIX build: configure checa `nc_open` linkando libnetcdf; sem LIBS falha
# ("Could not link to netcdf C library"). Usa nc-config --libs + rpath.
RUN wget -q https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v${NETCDF_F_VERSION}.tar.gz -O netcdf-f.tar.gz && \
    tar xzf netcdf-f.tar.gz && cd netcdf-fortran-${NETCDF_F_VERSION} && \
    export PATH=${OPT}/bin:${PATH} LD_LIBRARY_PATH=${OPT}/lib:${LD_LIBRARY_PATH} && \
    CC=mpicc FC=mpifort CFLAGS="-fPIC" FCFLAGS="-fPIC" FFLAGS="-fPIC" CPPFLAGS="-I${OPT}/include" LDFLAGS="-L${OPT}/lib -Wl,-rpath,${OPT}/lib" LIBS="$(${OPT}/bin/nc-config --libs)" \
    ./configure --prefix=${OPT} || { echo '=== netCDF-Fortran configure falhou; tail de config.log ==='; tail -n 80 config.log; exit 1; } && \
    make -j$(nproc) && make install && rm -f ${OPT}/lib/*.la && cd /tmp/build && rm -rf netcdf-f*

# --- PIO2 (ParallelIO, exigido pelo MPAS com USE_PIO2=true) ---
RUN git clone --depth 1 --branch ${PIO_VERSION} https://github.com/NCAR/ParallelIO.git pio2 && \
    mkdir pio2-build && cd pio2-build && \
    CC=mpicc FC=mpifort cmake ../pio2 \
      -DCMAKE_INSTALL_PREFIX=${OPT} \
      -DNetCDF_C_PATH=${OPT} -DNetCDF_Fortran_PATH=${OPT} \
      -DPnetCDF_PATH=${OPT} -DHDF5_PATH=${OPT} \
      -DPIO_ENABLE_TIMING=OFF -DPIO_ENABLE_TESTS=OFF && \
    make -j$(nproc) && make install && cd /tmp/build && rm -rf pio2 pio2-build

# --- MPAS-Model v8.4.2 ---
RUN git clone --depth 1 --branch v${MPAS_VERSION} https://github.com/MPAS-Dev/MPAS-Model.git ${MPAS_ROOT}

WORKDIR ${MPAS_ROOT}

# IMPORTANTE P100 (Pascal cc60):
# O Makefile nvhpc + OPENACC=true usa por padrão -gpu=cc70,cc80 (V100/A100).
# Sobrescrevemos para cc60 via variável de ambiente do NVHPC.
# Se o build falhar com "compute capability not supported", edite a linha make abaixo.
ENV NV_ACC_TIME=1 \
    MPAS_OPENACC_GPU=cc60

RUN export NETCDF=${OPT} PNETCDF=${OPT} PIO=${OPT} HDF5=${OPT} && \
    export PATH=${OPT}/bin:${PATH} LD_LIBRARY_PATH=${OPT}/lib:${LD_LIBRARY_PATH} && \
    echo "NETCDF=$NETCDF PNETCDF=$PNETCDF PIO=$PIO" && \
    echo "nc-config: $(nc-config --libs)" && echo "nf-config: $(nf-config --flibs)" && \
    ls -lh ${OPT}/lib/libpio* ${OPT}/lib/libnetcdf* ${OPT}/include/pio.mod && \
    # P100 (cc60): Makefile nvhpc fixa -gpu=cc70,cc80; patch para cc60
    sed -i 's/-gpu=cc70,cc80/-gpu=cc60/g' Makefile && grep -n "FFLAGS_ACC" Makefile | head && \
    # NVHPC 23.11 + OpenMPI: mpi_f08 gera S-0155 Ambiguous (MPI_Init/Finalize/Wtime).
    # Força fallback para `use mpi` legado removendo mpi_f08_test das deps.
    sed -i 's/^MAIN_DEPS = .*/MAIN_DEPS = rebuild_check openmp_test openacc_test pnetcdf_test pio_test/' Makefile && grep -n "^MAIN_DEPS" Makefile && \
    export MPAS_EXTERNAL_LIBS="$(nc-config --libs) $(nf-config --flibs) -lhdf5_hl -lhdf5 -lm -lz -lsz -lcurl -lxml2" && \
    echo "MPAS_EXTERNAL_LIBS=$MPAS_EXTERNAL_LIBS" && \
    # init_atmosphere (sempre CPU; usado p/ gerar condições iniciais)
    make nvhpc CORE=init_atmosphere USE_PIO2=true PRECISION=single MPAS_EXTERNAL_LIBS="$MPAS_EXTERNAL_LIBS" -j$(nproc) && \
    ls -lh init_atmosphere_model atmosphere_model 2>/dev/null || true && \
    cp -f init_atmosphere_model /tmp/init_atmosphere_model && \
    make nvhpc CORE=init_atmosphere USE_PIO2=true PRECISION=single clean && \
    cp -f /tmp/init_atmosphere_model ./init_atmosphere_model && \
    # atmosphere com OpenACC (dinâmica na GPU; física ainda na CPU na v8.4.x)
    # NOTA: se nvfortran reclamar de cc60 nesta versão do SDK, troque
    # OPENACC=true por OPENACC=false abaixo para build CPU-only funcional na P100.
    make nvhpc CORE=atmosphere OPENACC=true USE_PIO2=true PRECISION=single MPAS_EXTERNAL_LIBS="$MPAS_EXTERNAL_LIBS" -j$(nproc) && \
    ls -lh init_atmosphere_model atmosphere_model

# --- runtime enxuto ---
FROM nvcr.io/nvidia/nvhpc:23.11-runtime-cuda11.8-ubuntu22.04

ENV OPT=/opt/mpas-deps \
    MPAS_ROOT=/opt/MPAS-Model \
    NETCDF=/opt/mpas-deps \
    PNETCDF=/opt/mpas-deps \
    PIO=/opt/mpas-deps \
    LD_LIBRARY_PATH=/opt/mpas-deps/lib:/opt/nvidia/hpc_sdk/Linux_x86_64/23.11/compilers/lib:${LD_LIBRARY_PATH} \
    PATH=/opt/MPAS-Model:/opt/nvidia/hpc_sdk/Linux_x86_64/23.11/compilers/bin:${PATH}

# 'ncdump' NÃO é um pacote apt — é o binário dentro de 'netcdf-bin'.
# (Era essa a causa do exit code 100 no seu build.)
RUN apt-get update && apt-get install -y --no-install-recommends \
      openmpi-bin libopenmpi-dev netcdf-bin python3 \
      wget curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/mpas-deps /opt/mpas-deps
COPY --from=builder /opt/MPAS-Model/atmosphere_model /opt/MPAS-Model/
COPY --from=builder /opt/MPAS-Model/init_atmosphere_model /opt/MPAS-Model/
# streams.atmosphere / stream_list.atmosphere.* oficiais, gerados pelo build a partir
# do Registry (default_inputs). Sem eles, streams manuais pedem campos inexistentes.
COPY --from=builder /opt/MPAS-Model/default_inputs /opt/MPAS-Model/default_inputs
# build_tables nem sempre existe no top-level; copia tabelas de física (sempre existem).
COPY --from=builder /opt/MPAS-Model/src/core_atmosphere/physics/physics_wrf/files /opt/MPAS-Model/tables/
# Tabela do LSM Noah-MP (não fica em physics_wrf/files).
COPY --from=builder /opt/MPAS-Model/src/core_atmosphere/physics/physics_noahmp/parameters/NoahmpTable.TBL /opt/MPAS-Model/tables/

WORKDIR /opt/mpas/run
CMD ["sleep", "infinity"]
