# docker-installer

一条命令，把我的私有 compose 项目装到任意一台 Linux 服务器上。

```bash
curl -fsSL https://raw.githubusercontent.com/txzl130/docker-installer/main/install.sh | bash -s -- emby-proxy-manager
```

## 这是什么

- 源码仍然放在**私有仓库**里，这个仓库里只有：`install.sh`（明文）+ 每个项目的**加密安装包**。
- 安装时输入密码 → 本地解密 → 释放到目录 → `docker compose build` → `up -d` → 打印访问地址和首次令牌。
- 仓库公开，但包是 AES-256 加密的；没有密码打不开。

## 用法

```bash
# 看有哪些项目
curl -fsSL .../install.sh | bash -s -- --list

# 安装（默认目录 /opt/ysf/docker/<项目名>）
curl -fsSL .../install.sh | bash -s -- emby-proxy-manager

# 换目录 / 覆盖旧目录 / 装完删源码
curl -fsSL .../install.sh | bash -s -- emby-proxy-manager --dir /data/epm --force --clean-src

# 只看会做什么，不构建不启动
curl -fsSL .../install.sh | bash -s -- emby-proxy-manager --dry-run
```

> 国内服务器如果拉 `raw.githubusercontent.com` 很慢或卡住，把地址换成 jsDelivr：
> `curl -fsSL https://cdn.jsdelivr.net/gh/txzl130/docker-installer@main/install.sh | bash -s -- emby-proxy-manager`
> （脚本内部下载安装包时也会自动在 raw → jsDelivr → ghfast 之间切换，不用手改。）

| 参数 | 作用 |
|---|---|
| `--list` | 列出所有项目 |
| `--dir <路径>` | 安装目录（默认取项目配置） |
| `--force` | 目录已存在时先备份再覆盖 |
| `--clean-src` | 装完删源码，只留镜像和 `data/`（之后不能再重建） |
| `--dry-run` | 只下载/校验/解密/解压 |
| `--base <URL>` | 换安装器来源（测试用，可指本地目录） |

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
