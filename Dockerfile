###############################################################################
# 达梦 DM8 镜像 —— x86_64 / rh7(CentOS7 · RHEL7) 版安装包
#
# 安装包：dm8_20260710_x86_rh7_64.zip
#         （zip 内是 dm8_20260710_x86_rh7_64.iso，ISO 内是 DMInstall.bin）
# 构建：  docker build -t dm8:20260710_x86_rh7_64 .
#
# 为什么用 rh7 包：按 glibc 2.17 / SSE2 老基线编译，几乎所有 x86_64 Linux 都能跑；
# Ubuntu22 包要求新指令集，会在老 CPU 上 SIGILL（崩在 libdmutl.so）。
#
# 为什么 base 选 almalinux:8：glibc 2.28 ≥ rh7 包要求的 2.17，RPM 系与 rh7 包契合，
# 且仍在维护，漏洞数量远少于已 EOL 的 centos:7。
###############################################################################

ARG BASE_IMAGE=almalinux:8

##### 基础环境
FROM ${BASE_IMAGE} AS base

ARG DM_INSTALL_DIR=/opt/dmdbms
ARG DM_DATA_DIR=/opt/dmdbms/data
ARG DM_UID=12001
ARG DM_GID=12001
# rh7 安装器会校验操作系统，1=把 os-release 伪装成 CentOS 7
ARG FAKE_OS=1

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV DM_INSTALL_DIR=${DM_INSTALL_DIR}
ENV DM_DATA_DIR=${DM_DATA_DIR}
# 注意：DM_HOME / LD_LIBRARY_PATH / PATH 只在最终阶段设置，
# 否则安装器会认为"已存在其他版本达梦"。

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
# DM 8.4 密码规则：8~48 位，需大小写+数字；且两个密码必须同时给
ENV SYSDBA_PWD=Dmdba_123
ENV SYSAUDITOR_PWD=Dmauditor_123
ENV PORT_NUM=5236

# 1) 先升级到当前 8 的最新补丁（直接决定扫描漏洞数量）
# 2) rh7 包的运行期依赖：libaio、libnsl(libnsl.so.1)、ncurses-compat-libs(libncurses.so.5)
# 3) 兼容库 compat-openssl10：rh7 包若链接 libssl.so.10 时需要
# 4) dmdba:dinstall 用户；/opt 交给 dmdba，安装器才能自己创建 /opt/dmdbms
RUN set -eux; \
    dnf -y upgrade; \
    dnf -y install libaio libnsl ncurses-compat-libs procps-ng tar gzip shadow-utils; \
    dnf -y install compat-openssl10 || echo "WARN: compat-openssl10 未安装（多数情况不影响）"; \
    dnf clean all; \
    rm -rf /var/cache/dnf /var/log/dnf*; \
    groupadd -g ${DM_GID} dinstall 2>/dev/null || true; \
    useradd -m -u ${DM_UID} -g dinstall -d /home/dmdba -s /bin/bash dmdba 2>/dev/null || true; \
    chown -R dmdba:dinstall /home/dmdba; \
    chown dmdba:dinstall /opt; \
    if [ "${FAKE_OS}" = "1" ]; then \
        printf '%s\n' \
            'NAME="CentOS Linux"' \
            'VERSION="7 (Core)"' \
            'ID="centos"' \
            'ID_LIKE="rhel fedora"' \
            'VERSION_ID="7"' \
            'PRETTY_NAME="CentOS Linux 7 (Core)"' \
            'ANSI_COLOR="0;31"' \
            'CPE_NAME="cpe:/o:centos:centos:7"' \
            'HOME_URL="https://www.centos.org/"' \
            'BUG_REPORT_URL="https://bugs.centos.org/"' \
            > /etc/os-release; \
        echo "CentOS Linux release 7.9.2009 (Core)" > /etc/redhat-release; \
        echo "CentOS Linux release 7.9.2009 (Core)" > /etc/centos-release; \
    fi

# 构建期切换 USER 后 BuildKit 默认 HOME=/root，安装器要往 HOME 写文件
ENV HOME=/home/dmdba


##### 安装阶段（安装包不进入最终镜像）
FROM base AS install

ARG DM_ARCH=x86_64
ARG DM_INSTALL_DIR=/opt/dmdbms
ARG SLIM=1

# COPY 落地属主是 root，必须在切到 dmdba 之前加执行位；
# 放 /home/dmdba 下，dmdba 才有权限删掉装完后的安装包
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
        echo "ERROR: 当前架构 ${arch} 与安装包架构 ${DM_ARCH} 不一致" >&2; \
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

# 安装目录由安装器创建，这里只拷过来；数据目录在最终镜像里建
COPY --from=install ${DM_INSTALL_DIR} ${DM_INSTALL_DIR}
COPY startup.sh /opt/startup.sh

RUN set -eux; \
    chmod +x /opt/startup.sh; \
    mkdir -p ${DM_DATA_DIR}; \
    chown -R dmdba:dinstall ${DM_INSTALL_DIR} ${DM_DATA_DIR}

# 运行期才需要的环境变量
ENV DM_HOME=${DM_INSTALL_DIR}
ENV LD_LIBRARY_PATH=${DM_INSTALL_DIR}/bin
ENV PATH=${DM_INSTALL_DIR}/bin:${PATH}

LABEL org.opencontainers.image.title="dm8-20260710-x86-rh7" \
      org.opencontainers.image.description="Dameng DM8 server (rh7 build) on AlmaLinux 8, non-root runtime"

USER dmdba

WORKDIR /home/dmdba

EXPOSE 5236

STOPSIGNAL SIGTERM

ENTRYPOINT ["/opt/startup.sh"]
