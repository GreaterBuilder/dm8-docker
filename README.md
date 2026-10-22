# 达梦 DM8 ARM64 镜像（dm8_20260708_HWarm920_kylin10_sp1_64）

鲲鹏 920 / 银河麒麟 V10 SP1 安装包，在 **aarch64 Linux** 上构建。

## 文件

| 文件 | 说明 |
|---|---|
| `Dockerfile` | `almalinux:8`(aarch64) 打底 + 伪装麒麟 V10 SP1 + 安装 + 瘦身，多阶段 |
| `docker-entrypoint.sh` | 首启 `dminit` 建库、之后拉起 `dmserver`；自动跳过新版不支持的 dminit 参数 |
| `build.sh` | 自动 `zip → ISO → DMInstall.bin` 并构建 |
| `.dockerignore` | 不把几 GB 的 zip/iso 送进构建上下文 |

## 构建 / 运行

```bash
bash build.sh                       # 自动找当前目录的 dm8_*.zip
# 或直接：
docker build -t dm8:arm64 .
```

```bash
docker run -d --name dm8 -p 5236:5236 \
  -v dm8data:/opt/dmdbms/data \
  -v dm8log:/opt/dmdbms/log \
  --ulimit nofile=65536:65536 \
  -e SYSDBA_PWD='ChangeMe_123' -e SYSAUDITOR_PWD='ChangeMe_123' \
  -e UNICODE_FLAG=1 -e PAGE_SIZE=16 -e EXTENT_SIZE=16 \
  dm8:arm64
```

## 构建参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `BASE_IMAGE` | `almalinux:8` | 必须有 aarch64；glibc 2.28 与麒麟 V10 SP1 一致 |
| `DM_ARCH` | `aarch64` | 架构校验，防止拿 x86 包构建 |
| `DM_INSTALL_DIR` / `DM_DATA_DIR` | `/opt/dmdbms` / `/opt/dmdbms/data` | 与 x86 版、官方镜像保持一致 |
| `FAKE_KYLIN` | `1` | 把 `os-release`、`kylin-release` 伪装成麒麟 V10 SP1，安装器才放行 |
| `SLIM` | `1` | 删 `jdk/tool/doc/samples/drivers`；要用 DTS 就设 `0` |
| `TRIM` | `1` | 再删 `vim-minimal/less/gawk/gnupg2/tar/libarchive`，每删一个扫描报告就少一串组件漏洞；要保留这些工具就设 `0` |

## 环境变量（docker run -e）

`MODE`、`DB_NAME`、`INSTANCE_NAME`、`PORT_NUM`、`PAGE_SIZE`、`EXTENT_SIZE`、`CASE_SENSITIVE`、`UNICODE_FLAG`（0=GB18030，1=UTF-8）、`LENGTH_IN_CHAR`、`BLANK_PAD_MODE`、`BUFFER`、`LOG_SIZE`、`SYSDBA_PWD`、`SYSAUDITOR_PWD`、`TIME_ZONE`。建库参数只在首次初始化生效。

## 踩过的坑（本版本已处理）

1. **安装阶段 `chmod` 无权限**：`COPY` 落地属主是 root，`chmod` 必须放在 `USER dmdba` 之前（由 root 执行）。
2. **`/opt/startup.sh: Permission denied`**：脚本在镜像里没有读/执行权限。本版本在最终阶段用 root 的 `RUN chmod 0755 /opt/startup.sh` 兜底；注意 `COPY --chmod` 只有 BuildKit 支持，classic builder 会直接报错，所以没用它。
3. **“本系统已存在其他版本达梦数据库”**：安装应答里补了 `y`；同时不在安装阶段设置 `DM_HOME/PATH`、不预建安装目录。
4. **DM 8.4 移除 `LENGTH_IN_CHAR`**：`dminit` 会报 `Invalid parameter`，脚本改为先 `dminit help` 探测再传参。
5. **两个密码必须同时给**：8.4 要求 `SYSDBA_PWD` + `SYSAUDITOR_PWD`，且 8~48 位含大小写+数字，缺一个就 `fail to init db`。
6. **残库导致 `Database first startup failed`**：脚本区分“完整实例（dm.ini+dm.ctl）”和“残库”，残库直接报错提示清空，不再反复重启。
7. **日志泄露密码**：参数打印时把两个密码打码成 `******`。
8. **`dmserver` 日志随容器丢失**：运行命令建议挂 `-v dm8log:/opt/dmdbms/log`。
9. **健康检查**：镜像内置 `HEALTHCHECK`（探测 5236 是否可连），`docker ps` 里能看到 healthy/unhealthy。

## 注意

- 这是 **Kylin V10 SP1 / 鲲鹏 920** 的包，ARM 服务器必须是鲲鹏 920（或完全兼容 ARMv8.2 的 CPU）。飞腾等其他 ARM 平台请换成对应平台的包。
- 开发版 license 到期 `2027-07-07`，正式交付前把 `dm.key` 放到 `/opt/dmdbms/bin/dm.key`。
- ARM 镜像只能在 aarch64 上跑；x86 机器上执行需要 binfmt 模拟（不推荐用于生产）。
