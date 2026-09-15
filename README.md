# Scripts

个人维护的安装和运维脚本集合。

## 脚本

| 目录 | 用途 | 当前版本 |
| --- | --- | --- |
| [snell-alpine](./snell-alpine/) | Alpine Linux 低空间环境下安装和管理 Snell + ShadowTLS | 1.3.2 |

各脚本的安装方法、兼容范围和注意事项请查看对应目录中的 README。

## 一键运行 Snell Alpine

在 Alpine 服务器上，以 root 用户复制执行：

```sh
sh -c "$(curl -fsSL https://install.dry.li/snell-alpine)"
```

普通用户（已配置 sudo）使用：

```sh
sudo sh -c "$(curl -fsSL https://install.dry.li/snell-alpine)"
```

若提示 `curl: not found`，先以 root 执行 `apk add --no-cache curl ca-certificates`。运行后按菜单选择安装或管理功能，详细说明见 [Snell Alpine README](./snell-alpine/README.md)。
