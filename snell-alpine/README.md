# Alpine 低空间 Snell + ShadowTLS

这是针对 Alpine（包括 3.19+）的原生二进制方案，不安装 Docker，也不替换 Alpine 的 musl。

## 设计

- Snell v4/v5 的外层文件看起来像静态 ELF，但启动后解包出的程序仍会打开标准 GNU loader；v6 RC 则直接是 glibc 动态二进制。因此三个通道都使用从 Debian Bookworm 抽取到 `/usr/local/lib/snell-glibc` 的最小运行库。各通道仍分别保存为 `snell-server-v4/v5/v6`，可共存。
- ShadowTLS 使用上游发布的 musl 二进制，直接在 Alpine 运行。
- 两个服务均由 OpenRC 托管并设为开机启动。
- 状态页同时检查 PID/进程和真实 TCP/UDP 监听，不以“存在配置文件”或单独的 OpenRC 返回值冒充运行状态。
- 带标准 BBR + `fq` 管理；只有内核当前值实际成为 `bbr`/`fq` 才报告成功。受限容器无法修改宿主机内核时会明确报错。
- Snell 配置保持上游格式和位置：`/etc/snell/users/snell-main.conf`。
- 配置 ShadowTLS 后，Snell 会与上游脚本一样改为 `127.0.0.1:后端端口`，公网只开放 ShadowTLS TCP 端口。

## 使用

### 短链接一键运行

在 Alpine 服务器上，以 root 用户复制执行：

```sh
sh -c "$(curl -fsSL https://install.dry.li/snell-alpine)"
```

普通用户（已配置 sudo）使用：

```sh
sudo sh -c "$(curl -fsSL https://install.dry.li/snell-alpine)"
```

若提示 `curl: not found`，先以 root 执行：

```sh
apk add --no-cache curl ca-certificates
```

短链接返回当前已部署的脚本，运行后按菜单选择安装或管理功能。

### 本地文件运行

下载脚本后，也可以在脚本所在目录以 root 执行：

```sh
chmod +x snell-alpine-lowspace.sh
./snell-alpine-lowspace.sh
```

也可明确交给 `sh`：

```sh
sh snell-alpine-lowspace.sh
```

如果旧版曾停在“Snell 二进制兼容性测试失败”，直接用本版重新执行安装即可。v1.3.2 保留 `snell-server-v4/v5/v6` 多通道布局，从 Surge 发布历史按语义版本选取各通道最新版，并为 Alpine 补充 Snell 解包后所需的 GNU loader；同时修复首次安装 glibc 时临时目录变量被覆盖、包装器 `exec` 后进程名变化导致状态误判的问题，最后分别检查真实进程与监听端口。

ShadowTLS 也按原脚本的顺序配置：生成 16 位密码、询问 TLS 域名与 `wildcard-sni=authed`、显示协议选择、列出 Snell 主用户/其他用户端口，并支持单端口或全部端口。v1.3.2 改用 ShadowTLS 实际支持的 `--help` 做二进制验证；不再把 `--v` 的“unexpected argument”误当成兼容性结果；并修复端口列表循环占用标准输入、导致选择用户后无法读取 ShadowTLS 监听端口的问题。端口输入会直接显示在终端中，进程检查会识别 OpenRC 包装器后的真实命令行；若 Snell 改为回环监听后 ShadowTLS 启动或监听验证失败，脚本会删除失败服务并恢复原 Snell 配置。

v1.3.2 会在创建或发现现有 Snell/ShadowTLS OpenRC 服务后执行 `rc-update add ... default`，再使用 `rc-update -u` 强制刷新依赖树，并验证 `/etc/runlevels/default/` 中的有效链接。仅运行新版脚本即可修复现有服务的注册缓存，不需要重新安装 Snell 或 ShadowTLS。

也可以先运行不修改现有服务的独立测试：

```sh
chmod +x test-snell-binary.sh
./test-snell-binary.sh v5.0.1
```

它只在临时目录工作，并使用 `127.0.0.1:39127` 做两秒真实启动测试；结束后自动停止进程并删除文件。若端口已占用，可执行 `TEST_PORT=39128 ./test-snell-binary.sh v5.0.1`。

如需先检查脚本内容，可下载到本地，检查后按上述本地文件方式执行。

## 空间与功能边界

永久占用主要是 Snell、约 10 MB 的 ShadowTLS，以及约十几 MB 的隔离 glibc 运行库。下载的 Debian 包索引与 `.deb` 均在安装后清理。实际大小以菜单“查看服务状态”里的 `du` 输出为准。

本版复刻 Snell 主用户与 Snell + ShadowTLS 的核心交互、配置字段和 Surge 输出，并提供标准 BBR + `fq`。如果系统中已经存在原脚本格式的 `/etc/snell/users/snell-端口.conf` 和对应 OpenRC 服务，ShadowTLS 菜单也能逐个发现并配置；本脚本本身仍不负责创建多用户。它没有伪装实现 Debian 脚本中依赖 systemd socket activation 的 v5/v6 出口 netns，也没有带入 Shadowsocks和流量管理。OpenRC 服务文件位于 `/etc/init.d/`，日志位于 `/var/log/`。

## 重要行为

与上游 ShadowTLS 脚本一致，卸载 ShadowTLS 时不会自动把 Snell 从 `127.0.0.1` 改回公网监听。要恢复裸 Snell，重新执行“安装 Snell”即可。
