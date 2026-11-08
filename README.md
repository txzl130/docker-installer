# docker-installer

一条命令，把我的私有 compose 项目装到任意一台 Linux 服务器上。

```bash
# 推荐：先下载再运行（这样能交互选择项目、目录，也能自动装 Docker）
curl -fsSL https://cdn.jsdelivr.net/gh/txzl130/docker-installer@main/install.sh -o /tmp/i.sh
sudo bash /tmp/i.sh
```

## 这是什么

- 源码仍然放在**私有仓库**里，这个仓库里只有：`install.sh`（明文）+ 每个项目的**加密安装包**。
- 安装时输入密码 → 本地解密 → 释放到目录 → `docker compose build` → `up -d` → 打印访问地址和首次令牌。
- 仓库公开，但包是 AES-256 加密的；没有密码打不开。
- 机器没装 Docker 时会**问你要不要自动装**（用官方 get.docker.com，失败再换阿里云镜像）。

## 用法

```bash
# 最省事：不带参数，脚本会列出项目、问你要装哪个、装到哪个目录
sudo bash /tmp/i.sh

# 看有哪些项目
bash /tmp/i.sh --list

# 直接指定项目和目录（非交互，适合脚本化）
sudo bash /tmp/i.sh emby-proxy-manager --dir /opt/ysf/docker/emby-proxy-manager

# 已经装过的目录：同一条命令会自动识别成「升级」，data/、proxies/、.env 都保留
sudo bash /tmp/i.sh emby-proxy-manager --dir /opt/ysf/docker/emby-proxy-manager

# 只看会做什么，不构建不启动
bash /tmp/i.sh emby-proxy-manager --dry-run
```

也可以直接管道执行（交互提示会从 `/dev/tty` 读，仍然可选项目/目录）：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/txzl130/docker-installer@main/install.sh | sudo bash -s -- emby-proxy-manager
```

> 国内服务器如果拉 `raw.githubusercontent.com` 很慢或卡住，用上面 jsDelivr 地址即可。
> 脚本内部下载安装包时也会自动在 jsDelivr → ghfast → raw → gh-proxy 之间切换，并打印实际用的源。

| 参数 | 作用 |
|---|---|
| `--list` | 列出所有项目（带版本号） |
| `--dir <路径>` | 安装目录（不给就交互询问，回车用默认值） |
| `--upgrade` | 强制按升级处理（默认：目录里已有 compose 文件就自动升级） |
| `--reinstall` / `--force` | 整目录先备份成 `.bak.<时间>`，再按全新安装 |
| `--clean-src` | 装完删源码，只留镜像和 `data/`（之后不能再重建） |
| `--dry-run` | 只下载/校验/解密/解压 |
| `--no-start` | 只构建镜像，不启动容器 |
| `--password-stdin` | 从标准输入读密码（脚本化用） |
| `--base <URL>` | 换安装器来源（测试用，可指本地目录） |

环境变量：`UI_PORT` / `HEALTH_PORT` 覆盖端口，`INSTALLER_PASSWORD` 免交互给密码。

## 加一个新项目（维护者用）

1. 项目照常在**私有仓库**开发、提交。
2. 在任意一台有 `git`/`tar`/`openssl` 的机器上跑：

```bash
./publish.sh <项目名> <源码目录> \
  --title "显示名" --dir /opt/ysf/docker/<项目名> \
  --ports 9000,5088 --container <容器名> --image <镜像tag> \
  --env-from .env.example
```

3. 它会：打包（自动排除 `.env`/`data/`/证书/日志）→ 扫凭据 → 加密 → 写 `projects/<名字>/` → 重新生成 `projects/list.txt` → 提交并推送。

`install.sh` 不需要改。

## 安全说明（务必看）

- **密码是唯一的门**：24 位随机串，别截图、别发群里。忘了可以用新密码重新打包，不影响已装好的服务器。
- **包被改动会解不开**：`install.sh` 内置包的 sha256，对不上直接中止。
- 加密只保护「下载和存放」这一段。装上之后，服务器 root 能看到源码（`--clean-src` 可以缓解），镜像里也含着代码——这一点无法避免。
- 本仓库和私有仓库都请开 **2FA**：账号被盗比密码被猜现实得多。

## 目录结构

```
.
├── install.sh              # 安装入口
├── publish.sh              # 打包发布（维护者用）
├── projects/
│   ├── list.txt            # install.sh --list 用
│   └── <项目名>/
│       ├── project.conf    # 元数据 + 校验和
│       └── <项目名>.tar.gz.enc
└── README.md
```

## 常见问题

**解密失败**：密码不对，或者包被改过。重新确认密码。

**`docker compose build` 失败、报 DNS 或 apk 错误**：这台机器的 bridge 网络出不了网。`install.sh` 会自动回退到 `docker build --network host`；如果还失败，手动执行那条命令。

**端口被占用**：先看 `ss -ltnp`，改 `.env` 或项目的 `LISTEN_PORT`。

**想重装**：`--force` 会把旧目录备份成 `<目录>.bak.<时间>`。
