# 达梦 DM8 ARM64 镜像（dm8_20260708_HWarm920_kylin10_sp1_64）

在原仓库 [GreaterBuilder/dm8-docker](https://github.com/GreaterBuilder/dm8-docker)（x86/centos:7）基础上改成 ARM64 版，
在 aarch64 Linux 上直接出镜像。

## 文件

| 文件 | 说明 |
|---|---|
| `Dockerfile` | 多阶段构建，基础镜像 `almalinux:8`（aarch64，glibc 2.28，与麒麟 V10 SP1 一致） |
| `docker-entrypoint.sh` | 首次启动自动 `dminit` 建库，之后拉起 `dmserver` |
| `build.sh` | 解包 `zip → ISO → DMInstall.bin` 并构建 |
| `.dockerignore` | 只上传 Dockerfile / entrypoint / DMInstall.bin |

## 构建

把 `dm8_20260708_HWarm920_kylin10_sp1_64.zip` 和这几个文件放同一目录：

```bash
bash build.sh                     # 自动找当前目录的 dm8_*.zip
# 或
bash build.sh /path/dm8_20260708_HWarm920_kylin10_sp1_64.zip
```

不用脚本（已手工取出 `DMInstall.bin` 时）：

```bash
docker build -t dm8:arm64 .
```

## 关键改动

1. **基础镜像** `centos:7` → `almalinux:8`（aarch64；centos:7 无 arm64）。
   要换成真麒麟镜像：`--build-arg BASE_IMAGE=kylin:v10-sp1 --build-arg FAKE_KYLIN=0`。
2. **OS 校验**：安装器只认麒麟，`FAKE_KYLIN=1`（默认）把 `/etc/os-release` 伪装成
   `Kylin Linux Advanced Server V10 (SP1)`，否则 ARM 安装包会因“系统不支持”退出。
3. **架构保护**：安装阶段校验 `uname -m`，非 aarch64 直接报错退出，不会静默装出一堆废文件。
4. **安装包**：自动 `zip → iso → DMInstall.bin`（zip 里直接是 bin 也支持），带 7z/bsdtar/loop 挂载三种解 ISO 方式。
5. **entrypoint 修复**：原版 `declare -g` 是 bash 专属（dash 下报错）；`CASE_SENSITIVE` 定义了却没写进
   `dminit` 应答文件。现在 `CASE_SENSITIVE`/`PORT_NUM`/`PAGE_SIZE`/`CHARSET`/`TIME_ZONE` 全部生效。
6. **依赖**：补 `libaio`、`libnsl`、`ncurses-compat-libs`（disql 需要 `libncurses.so.5`）。
7. **构建上下文**：`.dockerignore` 排掉 zip/iso，避免几 GB 数据推给 daemon。

## 运行

```bash
docker run -d --name dm8 -p 5236:5236 \
  -v /mnt/data/dm8:/mnt/data/dm8 \
  -e SYSDBA_PWD=DMdba_123 \
  -e SYSAUDITOR_PWD=DMauditor_123 \
  dm8:arm64
```

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `DATABASE_NAME` | `DAMENG` | 库名 |
| `INSTANCE_NAME` | `DMSERVER` | 实例名 |
| `PORT_NUM` | `5236` | 端口 |
| `CASE_SENSITIVE` | `Y` | 大小写敏感（仅建库时生效） |
| `PAGE_SIZE` | `16` | 页大小 |
| `CHARSET` | `1` | 1=UTF-8，0=GB18030 |
| `TIME_ZONE` | `+08:00` | 时区 |
| `SYSDBA_PWD` / `SYSAUDITOR_PWD` | `DMdba_123` / `DMauditor_123` | 密码 |

## 排错

- **`exec format error`**：装的不是 aarch64 包 / 构建时平台不对。`bash build.sh` 已强制 `--platform linux/arm64`。
- **“操作系统版本不支持”**：`FAKE_KYLIN` 被设成 0 了，或基础镜像不是 EL 系。
- **找不到 `DMInstall.bin`**：`unzip -l 包名.zip` 看下结构；若不是 iso 套 bin，把列表发我。
- **`unable to find image` / 拉取慢**：`--build-arg BASE_IMAGE=你的加速器/almalinux:8`。
- **bind mount 后启动 `Permission denied`**：`sudo chown -R 12001:12001 /mnt/data/dm8`。
