# 达梦 DM8 镜像（dm8_20260710_x86_rh7_64）

## 文件

| 文件 | 说明 |
|---|---|
| `Dockerfile` | `almalinux:8` 打底 + 伪装 CentOS 7 + rh7 包安装 + 瘦身，多阶段 |
| `startup.sh` | 首启 `dminit` 建库、之后拉起 `dmserver`；自动跳过新版不支持的 dminit 参数 |
| `.dockerignore` | 不把 zip/iso 送进构建上下文 |

## 构建

```bash
# 1) 取 DMInstall.bin（放到本目录，和 Dockerfile 同级）
mkdir -p pkg && unzip -o dm8_20260710_x86_rh7_64.zip -d pkg
ISO=$(find pkg -name '*.iso' | head -1)
7z x -y -o./iso "$ISO" || (mkdir -p /mnt/dm8iso && mount -o loop,ro "$ISO" /mnt/dm8iso && cp /mnt/dm8iso/DMInstall.bin ./iso/ && umount /mnt/dm8iso)
cp ./iso/DMInstall.bin . && chmod +x DMInstall.bin

# 2) 构建
docker build -t dm8:20260710_x86_rh7_64 .
```

## 运行

```bash
docker run -d --name dm8 --restart=always -p 5236:5236 \
  -v dm8data:/opt/dmdbms/data \
  --ulimit nofile=65536:65536 -e TZ=Asia/Shanghai \
  -e SYSDBA_PWD='ChangeMe_123' -e SYSAUDITOR_PWD='ChangeMe_123' \
  -e UNICODE_FLAG=1 -e PAGE_SIZE=16 -e EXTENT_SIZE=16 \
  dm8:20260710_x86_rh7_64
```

## 构建参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `BASE_IMAGE` | `almalinux:8` | 支持 aarch64 时也可换 `openeuler/openeuler:22.03-lts` |
| `DM_ARCH` | `x86_64` | 架构校验 |
| `DM_INSTALL_DIR` / `DM_DATA_DIR` | `/opt/dmdbms` / `/opt/dmdbms/data` | 目录 |
| `FAKE_OS` | `1` | 伪装 `/etc/os-release`、`/etc/redhat-release` 为 CentOS 7 |
| `SLIM` | `1` | 删 `jdk/tool/doc/samples/drivers`（要用 DTS/管理工具就设 0） |

## 环境变量（`docker run -e`）

`MODE`、`DB_NAME`、`INSTANCE_NAME`、`PORT_NUM`、`PAGE_SIZE`、`EXTENT_SIZE`、`CASE_SENSITIVE`、`UNICODE_FLAG`（0=GB18030，1=UTF-8）、`LENGTH_IN_CHAR`、`BLANK_PAD_MODE`、`BUFFER`、`LOG_SIZE`、`SYSDBA_PWD`、`SYSAUDITOR_PWD`、`TIME_ZONE`。
以上建库参数**只在首次初始化生效**，改之前清空数据目录。

## 说明

- **DM 8.4 移除了 `LENGTH_IN_CHAR`**，`startup.sh` 会先跑 `dminit help` 探测，不认识就跳过并告警，不会因此起不来。
- 密码规则（8.4）：8~48 位，必须同时含大写、小写、数字；`SYSDBA_PWD` 与 `SYSAUDITOR_PWD` 必须同时给出。
- 初始化被中断会留下只有 `dm.ini` 没有 `dm.ctl` 的残库，脚本会直接报错提示清空数据目录，而不是带着残库反复重启。
- 开发版 license 到期 `2027-07-07`，正式交付前把 `dm.key` 放到 `/opt/dmdbms/bin/dm.key`。
