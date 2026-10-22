###############################################################################
# 达梦 DM8 —— ARM64 / aarch64 镜像（鲲鹏 920 + 银河麒麟 V10 SP1 安装包）
#
# 安装包：dm8_20260708_HWarm920_kylin10_sp1_64.zip
#         zip 内是 .iso，ISO 内是 DMInstall.bin（build.sh 会自动解出来）
#
# 构建：bash build.sh
#   或：docker build -t dm8:arm64 .
#
# 可覆盖的构建参数（--build-arg）：
#   BASE_IMAGE     aarch64 基础镜像，默认 almalinux:8（glibc 2.28，与麒麟 V10 SP1 一致）
#   DM_ARCH        目标架构，默认 aarch64
#   DM_INSTALL_DIR 程序安装目录，默认 /opt/dmdbms
#   DM_DATA_DIR    数据目录，默认 /opt/dmdbms/data
#   DM_UID/DM_GID  dmdba 用户 uid/gid，默认 12001
#   FAKE_KYLIN     1=把 os-release 伪装成麒麟 V10 SP1（安装器会做 OS 校验）
#   SLIM           1=删掉 DM 自带的 jdk/tool/doc/samples/drivers
#   TRIM           1=再删掉容器用不到的 vim/less/gawk/gnupg2/tar/libarchive（降扫描噪音）
###############################################################################

ARG BASE_IMAGE=almalinux:8

##### 基础环境
FROM ${BASE_IMAGE} AS base

ARG DM_INSTALL_DIR=/opt/dmdbms
ARG DM_DATA_DIR=/opt/dmdbms/data
ARG DM_UID=12001
ARG DM_GID=12001
ARG FAKE_KYLIN=1

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV DM_INSTALL_DIR=${DM_INSTALL_DIR}
ENV DM_DATA_DIR=${DM_DATA_DIR}
# 注意：DM_HOME / LD_LIBRARY_PATH / PATH 只在最终阶段设置。
# 安装阶段若已存在这些变量，安装器会判定"本系统已存在其他版本达梦数据库"。

# 与官方镜像一致的初始化参数（docker run -e 覆盖即可）
ENV MODE=dmsingle
ENV INSTANCE_NAME=dm8_test
ENV PAGE_SIZE=8
ENV EXTENT_SIZE=16
ENV CASE_SENSITIVE=1
ENV UNICODE_FLAG=0
ENV LENGTH_IN_CHAR=0
ENV BLANK_PAD_MODE=0
ENV BUFFER=1000
ENV LOG_SIZE=256
# DM 8.4 密码规则：8~48 位，必须同时含大写、小写、数字；
# 且 dminit 要求 SYSDBA_PWD 与 SYSAUDITOR_PWD 同时给出，缺一个就初始化失败
ENV SYSDBA_PWD=Dmdba_123
ENV SYSAUDITOR_PWD=Dmauditor_123
ENV PORT_NUM=5236

# 1) 升级到当前补丁（决定扫描漏洞数量）
# 2) 运行期依赖：libaio、libnsl(libnsl.so.1)、ncurses-compat-libs(libncurses.so.5)
# 3) dmdba:dinstall 用户；/opt 交给 dmdba，安装器才能自己创建 /opt/dmdbms
# 4) 伪装 os-release 为麒麟 V10 SP1（仅 FAKE_KYLIN=1）
RUN set -eux; \
    dnf -y upgrade; \
    dnf -y install libaio libnsl ncurses-compat-libs procps-ng tar gzip shadow-utils; \
    dnf clean all; \
    rm -rf /var/cache/dnf /var/log/dnf*; \
    groupadd -g ${DM_GID} dinstall 2>/dev/null || true; \
    useradd -m -u ${DM_UID} -g dinstall -d /home/dmdba -s /bin/bash dmdba 2>/dev/null || true; \
    chown -R dmdba:dinstall /home/dmdba; \
    chown dmdba:dinstall /opt; \
    if [ "${FAKE_KYLIN}" = "1" ]; then \
        printf '%s\n' \
            'NAME="Kylin Linux Advanced Server"' \
            'VERSION="V10 (SP1)"' \
            'ID="kylin"' \
            'ID_LIKE="centos rhel fedora"' \
            'VERSION_ID="V10"' \
            'PRETTY_NAME="Kylin Linux Advanced Server V10 (SP1)"' \
            'ANSI_COLOR="0;31"' \
            'HOME_URL="https://www.kylinos.cn/"' \
            'BUG_REPORT_URL="https://www.kylinos.cn/"' \
            > /etc/os-release; \
        echo "Kylin Linux Advanced Server release V10 (SP1)" > /etc/kylin-release; \
    fi

# 构建期切换 USER 后 BuildKit 默认 HOME=/root，安装器要往 HOME 写文件
ENV HOME=/home/dmdba


##### 安装阶段（安装包不进入最终镜像）
FROM base AS install

ARG DM_ARCH=aarch64
ARG DM_INSTALL_DIR=/opt/dmdbms
ARG SLIM=1

# COPY 落地属主是 root，执行位必须在切到 dmdba 之前由 root 加上。
# 这里不用 COPY --chmod，classic builder（DOCKER_BUILDKIT=0）也兼容。
COPY DMInstall.bin /home/dmdba/DMInstall.bin
RUN chmod 0755 /home/dmdba/DMInstall.bin

USER dmdba

# 静默安装应答顺序：
#   1    安装语言：1=中文
#   y    "本系统已存在其他版本达梦数据库…是否继续"（容器是空环境，继续）
#   n    是否输入 Key 文件路径
#   y    是否设置时区
#   21   中国标准时间（+08:00）
#   2    安装类型：2=服务器
#   dir  安装路径 /opt/dmdbms
#   y    确认安装路径
#   y    确认安装
RUN set -e; \
    ulimit -n 65536 || true; \
    arch="$(uname -m)"; \
    if [ "$arch" != "${DM_ARCH}" ]; then \
        echo "==========================================================" >&2; \
        echo " ERROR: 当前架构 ${arch}，与安装包架构 ${DM_ARCH} 不一致。" >&2; \
        echo " 请在 aarch64 机器上构建，或 docker buildx --platform linux/arm64。" >&2; \
        echo "==========================================================" >&2; \
        exit 1; \
    fi; \
    printf '%s\n' '1' 'y' 'n' 'y' '21' '2' "${DM_INSTALL_DIR}" 'y' 'y' \
        | /home/dmdba/DMInstall.bin -i; \
    rm -f /home/dmdba/DMInstall.bin || true; \
    test -x "${DM_INSTALL_DIR}/bin/dmserver"; \
    test -x "${DM_INSTALL_DIR}/bin/dminit"

# 瘦身：容器只跑数据库，jdk/tool/doc/samples/drivers 都是扫描器的靶子
RUN set -eux; \
    if [ "${SLIM}" = "1" ]; then \
        cd "${DM_INSTALL_DIR}"; \
        rm -rf jdk doc samples drivers tool uninstall; \
        rm -f bin/dts bin/manager bin/console bin/analyzer bin/dmfldr bin/dtsc bin/logmnr; \
        rm -rf /home/dmdba/.cache /home/dmdba/.local; \
    fi


##### 输出阶段
FROM base

ARG DM_INSTALL_DIR=/opt/dmdbms
ARG DM_DATA_DIR=/opt/dmdbms/data
ARG TRIM=1

# 安装目录由安装器创建，这里只拷过来；数据目录在最终镜像里建。
# 脚本权限统一在下面 RUN 里用 root 加（兼容 classic builder，不依赖 --chmod）
COPY --from=install ${DM_INSTALL_DIR} ${DM_INSTALL_DIR}
COPY docker-entrypoint.sh /opt/startup.sh

RUN set -eux; \
    chmod 0755 /opt/startup.sh; \
    mkdir -p ${DM_DATA_DIR}; \
    chown -R dmdba:dinstall ${DM_INSTALL_DIR} ${DM_DATA_DIR}

# 去掉容器里用不到的包（每删一个，扫描报告就少一串组件漏洞）
RUN set -eux; \
    if [ "${TRIM}" = "1" ]; then \
        for p in vim-minimal less gawk gnupg2 tar libarchive; do \
            if rpm -q "$p" >/dev/null 2>&1; then dnf -y remove "$p" || true; fi; \
        done; \
        dnf clean all || true; \
        rm -rf /var/cache/dnf /var/log/dnf*; \
    fi

# 运行期才需要的环境变量
ENV DM_HOME=${DM_INSTALL_DIR}
ENV LD_LIBRARY_PATH=${DM_INSTALL_DIR}/bin
ENV PATH=${DM_INSTALL_DIR}/bin:${PATH}

LABEL org.opencontainers.image.title="dm8-arm64" \
      org.opencontainers.image.description="Dameng DM8 server for aarch64 (Kylin V10 SP1 build), non-root runtime"

USER dmdba

WORKDIR /home/dmdba

EXPOSE 5236

STOPSIGNAL SIGTERM

# 就绪探针：能连上 5236 才算 healthy
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/${PORT_NUM:-5236}' || exit 1

ENTRYPOINT ["/opt/startup.sh"]
