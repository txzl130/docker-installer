# docker-installer

一条命令，把我的私有 compose 项目装到任意一台 Linux 服务器上。

```bash
# 推荐：先下载再运行（这样能交互选择项目、目录，也能自动装 Docker）
curl -fsSL https://raw.githubusercontent.com/txzl130/docker-installer/main/install.sh -o /tmp/i.sh
sudo bash /tmp/i.sh
```

## 这是什么

- 源码仍然放在**私有仓库**里，这个仓库里只有：`install.sh`（明文）+ 每个项目的**加密安装包**。
- 安装时输入密码 → 本地解密 → 释放到目录 → `docker compose build` → `up -d` → 打印访问地址和首次令牌。
- 仓库公开，但包是 AES-256 加密的；没有密码打不开。
- 机器没装 Docker 时会**问你要不要自动装**（用官方 get.docker.com，失败再换阿里云镜像）。

## 用法

```bash
# 最省事：不带参数 → 列出编号，输入编号（可多选，如 1 3），再问一次根目录
sudo bash /tmp/i.sh

# 直接按编号装（编号见 --list），可一次装多个
sudo bash /tmp/i.sh 1
sudo bash /tmp/i.sh 1 2 --dir /opt/ysf/docker

# 看有哪些项目（带编号）
bash /tmp/i.sh --list

# 已经装过的项目：同一条命令会自动识别成「升级」，data/、proxies/、.env 都保留
sudo bash /tmp/i.sh 1

# 只看会做什么，不构建不启动
bash /tmp/i.sh 1 --dry-run
```

**目录规则**：`--dir` 是**统一根目录**（默认 `/opt/ysf/docker`），每个项目装到 `<根目录>/<项目名>`。
不需要为每个项目单独选目录；根目录只在开头问一次。

也可以直接管道执行（交互提示会从 `/dev/tty` 读，仍然可选项目/目录）：

```bash
curl -fsSL https://raw.githubusercontent.com/txzl130/docker-installer/main/install.sh | sudo bash -s -- 1
```

卸载（连容器、镜像、目录里的 `data/` 一起删；不加 `--yes` 会先问你）：

```bash
sudo bash /tmp/i.sh --uninstall 1
```

> **用 raw 地址，别用 jsDelivr 的 `@main`**：jsDelivr 缓存很顽固，改了脚本它还发旧版。
> 国内拉 raw 慢就走代理：`https://ghfast.top/https://raw.githubusercontent.com/txzl130/docker-installer/main/install.sh`。
> 脚本内部下载安装包时会自动在 ghfast → raw → gh-proxy → jsDelivr 之间切换；**每次请求都带时间戳绕缓存**，
> 并且会把所有源的 `project.conf` 都拉一遍、**挑版本号最高的那个源**再下载包（1.3.6 起）。
> 原因：旧 conf + 旧包是自洽的，校验和能对上，光靠 sha256 校验挡不住「静默装成旧版本」。

| 参数 | 作用 |
|---|---|
| `--list` | 列出所有项目（带编号、版本号） |
| `--dir <路径>` | 统一安装根目录（默认 `/opt/ysf/docker`；不给会交互询问） |
| `--upgrade` | 强制按升级处理（默认：目录里已有 compose 文件就自动升级） |
| `--reinstall` / `--force` | 整目录先备份成 `.bak.<时间>`，再按全新安装 |
| `--clean-src` | 装完删源码，只留镜像和 `data/`（之后不能再重建） |
| `-u` / `--uninstall` | 卸载：停容器 → 删容器 → 删目录（含 `data/`）→ 删镜像 |
| `-y` / `--yes` | 删除类操作不再询问（非交互删除必须加） |
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
  --title "显示名" --ports 9000,5088 \
  --container <容器名> --image <镜像tag> --env-from .env.example
```

3. 它会：打包（自动排除 `.env`/`data/`/证书/日志）→ 扫凭据 → 加密 → 写 `projects/<名字>/` → 重新生成 `projects/list.txt` → 提交并推送。

`install.sh` 不需要改；编号是自动按 `list.txt` 顺序生成的。

## 顺便签 HTTPS 证书（cert.sh）

装完 `install.sh` 会问一句「现在签一张证书吗？」。答 `y`、填一个域名就行 —— **不用填任何服务商密钥，也不停现有网站**：

```bash
sudo bash /opt/ysf/docker/cert.sh emby.你的域名.com
```

它自己判断怎么验证：

| 80 端口情况 | 做法 |
|---|---|
| 空着 | 起一个临时 acme.sh 容器用 80 验证，签完立刻撤掉 |
| 被别的网站占着 | 找到那个网站挂载的目录，借它放验证文件（网站不受影响，不需要停） |
| 被非网站程序占着 | 停下来，告诉你改用 `--webroot 目录` 或项目自带的 DNS 验证 |

签名后的流程：

```bash
# 1) 先在管理台建好代理，把域名填成同一个域名
# 2) 再跑一次（证书还有效，不会重复签，只问你要装到哪个代理）
sudo bash /opt/ysf/docker/cert.sh emby.你的域名.com

# 自动续期（30 天内到期才续）
(crontab -l 2>/dev/null; echo '0 3 * * * bash /opt/ysf/docker/cert.sh --renew >/var/log/cert-renew.log 2>&1') | crontab -
```

证书放在 `/opt/ysf/docker/_certs/<域名>/`；装到项目后同时写进 `data/certs/<代理名>/`，并自动重新生成 nginx 配置、reload 生效。

常用参数：`--staging`（测试签发，不消耗正式额度）、`--force`（强制重签）、`--no-install`（只签不装）、`--renew`（续期）、`--dir`（改了根目录时用）、`-v`（显示细节）。

> 域名必须真的解析到这台机器、且 80 端口能从公网访问，否则验证过不了。云服务器记得在安全组放行 80。


## 安全说明（务必看）

- **密码是唯一的门**：24 位随机串，别截图、别发群里。忘了可以用新密码重新打包，不影响已装好的服务器。
- **包被改动会解不开**：`install.sh` 内置包的 sha256，对不上直接中止。
- 加密只保护「下载和存放」这一段。装上之后，服务器 root 能看到源码（`--clean-src` 可以缓解），镜像里也含着代码——这一点无法避免。
- 本仓库和私有仓库都请开 **2FA**：账号被盗比密码被猜现实得多。

## 目录结构

```
.
├── install.sh              # 安装入口
├── cert.sh                 # 单独签 HTTPS 证书（可选）
├── publish.sh              # 打包发布（维护者用）
├── projects/
│   ├── list.txt            # install.sh --list 用
│   └── <项目名>/
│       ├── project.conf    # 元数据 + 校验和
│       └── <项目名>.tar.gz.enc
└── README.md
```

## 常见问题

**解密失败**：密码不对，或者包被改过。现在 `project.conf` 里有 `PW_CHECK`（密码指纹），密码和这个包对不上时会直接告诉你「这个安装包不是用这个密码加密的」，不会让你白试三次。

**想给已经装好的项目补证书**：`sudo bash /opt/ysf/docker/cert.sh 你的域名`（`cert.sh` 会在安装时自动放到根目录；没有就去仓库下载一份）。80 空着就不用填服务商密钥。

**`docker compose build` 失败、报 DNS 或 apk 错误**：这台机器的 bridge 网络出不了网。`install.sh` 会自动回退到 `docker build --network host`；如果还失败，手动执行那条命令。

**端口被占用**：安装前会预检并直接告诉你。可以 `UI_PORT=19000 HEALTH_PORT=18080 bash install.sh 1` 换端口，或装完改 `.env`。

**提示"目标磁盘只剩 0 MB"**：这是 1.2.0 及更早的 bug（目标目录还不存在时 `df` 失败被当成 0），1.3.0 已修。

**想重装**：`--reinstall`（=`--force`）会把旧目录备份成 `<目录>.bak.<时间>`。

**装错地方了/想彻底删掉**：`bash i.sh --uninstall 1`（加 `--yes` 免确认）。升级留下的
`*.code-*.tgz`、`*.bak.*` 备份不会被自动删，脚本会把路径列出来，确认没问题再手工删。

**云服务器装完外面打不开**：机器上的端口是通的，但云厂商的**安全组/防火墙**默认只放几个端口。
去控制台放行安装结束时打印的那几个端口（管理台 + 代理端口）。脚本管不到这一层。

**2G 小内存机器构建很慢/失败**：加 1~2G swap 会好很多（因此脚本会提前检测并提示）。

**jsDelivr 拿到的是旧脚本**：首发后 CDN 有缓存，用 `@<commit>` 固定版本的地址最稳，例如
`https://cdn.jsdelivr.net/gh/txzl130/docker-installer@<7位提交号>/install.sh`。脚本启动时会打印「安装器版本」。

**装完看到的版本比最新版旧**：CDN 的旧 `project.conf` + 旧包是自洽的，校验和能通过。1.3.6 起脚本会把所有镜像的
conf 都拉一遍、挑版本号最高的源，并且每个请求都带时间戳；如果还遇到，先确认脚本本身是不是新版（开头第一行会打印
`安装器版本`），必要时用 `--base https://ghfast.top/https://raw.githubusercontent.com/txzl130/docker-installer/main` 指定源。
