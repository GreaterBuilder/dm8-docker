###############################################################################
# 达梦 DM8 —— ARM64 / aarch64 镜像
#
# 安装包：dm8_20260708_HWarm920_kylin10_sp1_64.zip
#         zip 里通常是 .iso（ISO 内才是 DMInstall.bin），也可能直接是 DMInstall.bin，
#         build.sh 会把它解出来放到本 Dockerfile 同目录。
#
# 构建：bash build.sh
#   或：docker build -t dm8:arm64 .
#
# 可覆盖的构建参数（--build-arg）：
#   BASE_IMAGE     aarch64 基础镜像，默认 almalinux:8（glibc 2.28，与麒麟 V10 SP1 一致）
#   DM_INSTALL_DIR 程序安装目录，默认 /opt/dm8
#   DM_DATA_DIR    数据目录，默认 /mnt/data/dm8
#   DM_UID/DM_GID  dmdba 用户 uid/gid，默认 12001
#   FAKE_KYLIN     1=把 /etc/os-release 伪装成麒麟 V10 SP1（DM 安装器会做系统检查），默认 1
###############################################################################

ARG BASE_IMAGE=almalinux:8

##### 基础镜像环境
FROM ${BASE_IMAGE} AS base

ARG DM_INSTALL_DIR=/opt/dm8
ARG DM_DATA_DIR=/mnt/data/dm8
ARG DM_UID=12001
ARG DM_GID=12001
ARG FAKE_KYLIN=1

ENV DM_INSTALL_DIR=${DM_INSTALL_DIR}
ENV DM_DATA_DIR=${DM_DATA_DIR}

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV PATH=${DM_INSTALL_DIR}/bin:${PATH}

# 1) 运行期依赖：libaio / libnsl / ncurses-compat-libs（disql 需要 libncurses.so.5）
# 2) dmdba:dinstall 用户
# 3) 安装目录、数据目录
# 4) 伪装 os-release（仅当 FAKE_KYLIN=1）
RUN set -eux; \
    if command -v dnf >/dev/null 2>&1; then \
        dnf install -y libaio libnsl ncurses-compat-libs unzip tar gzip shadow-utils procps || true; \
        dnf clean all || true; \
    elif command -v yum >/dev/null 2>&1; then \
        yum install -y libaio libnsl ncurses-compat-libs unzip tar gzip shadow-utils procps || true; \
        yum clean all || true; \
    fi; \
    if ! getent group dinstall >/dev/null 2>&1; then \
        groupadd -g ${DM_GID} dinstall; \
    fi; \
    if ! getent passwd dmdba >/dev/null 2>&1; then \
        useradd -g dinstall -m -u ${DM_UID} -d /home/dmdba -s /bin/bash dmdba; \
    fi; \
    mkdir -p ${DM_INSTALL_DIR} ${DM_DATA_DIR} /home/dmdba/install; \
    chown -R dmdba:dinstall ${DM_INSTALL_DIR} ${DM_DATA_DIR} /home/dmdba; \
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
        cp -f /etc/os-release /etc/kylin-release 2>/dev/null || true; \
    fi

# 构建期切换 USER 后 BuildKit 默认 HOME=/root，安装器要往 HOME 写文件，这里显式指定
ENV HOME=/home/dmdba


##### 安装阶段
FROM base AS install

COPY DMInstall.bin /home/dmdba/install/DMInstall.bin

USER dmdba

# 静默安装应答顺序（DM 安装器固定顺序）：
#   1       安装语言：1=中文 2=英文
#   n       是否输入 Key 文件路径
#   y       是否设置时区
#   21      时区：21=中国标准时间（+08:00）
#   2       安装类型：1=典型 2=服务器 3=客户端 4=自定义
#   <dir>   安装路径（由 DM_INSTALL_DIR 指定，默认 /opt/dm8）
#   y       确认安装路径
#   y       确认安装
RUN set -e; \
    arch="$(uname -m)"; \
    if [ "$arch" != "aarch64" ] && [ "$arch" != "arm64" ]; then \
        echo "==================================================================" >&2; \
        echo " ERROR: 当前构建架构是 ${arch}，但 DMInstall.bin 是 aarch64(ARM) 安装包。" >&2; \
        echo " 请确认在 aarch64 Linux 上构建，或使用 docker buildx --platform linux/arm64。" >&2; \
        echo "==================================================================" >&2; \
        exit 1; \
    fi; \
    chmod +x /home/dmdba/install/DMInstall.bin; \
    printf '%s\n' '1' 'n' 'y' '21' '2' "${DM_INSTALL_DIR}" 'y' 'y' \
        | sh /home/dmdba/install/DMInstall.bin -i; \
    test -x "${DM_INSTALL_DIR}/bin/dmserver"; \
    test -x "${DM_INSTALL_DIR}/bin/dminit"


##### 输出阶段
FROM base

COPY --from=install ${DM_INSTALL_DIR} ${DM_INSTALL_DIR}
COPY --from=install ${DM_DATA_DIR} ${DM_DATA_DIR}
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

USER dmdba

EXPOSE 5236

WORKDIR /home/dmdba

ENTRYPOINT ["/docker-entrypoint.sh"]
