> **运维**：总台 RSA 签名、换台、打包 JAR、GitHub Releases 上传大文件见 [deploy/README.md](deploy/README.md)

## 子台服务器部署（用户操作手册）

**适用环境**

| 项目 | 要求 |
|------|------|
| 系统 | Ubuntu 20.04 / 22.04（默认用户 `ubuntu`） |
| 网络 | 服务器能访问 GitHub |
| 安全组 | 放行 **TCP 80**（管理端 HTTP + 证书 HTTP-01 验证） |
| 安全组 | 放行 **TCP 443**（已部署源码 HTTPS 访问） |
| 仓库 | `feature` 分支含 `deploy/master.endpoint.pkg`（总台 RSA 签名包，缺则部署失败） |
| 大文件（运维） | GitHub **Published Release** 附件含 `dist.zip`、`springboot-app.jar`（Raw 失败时脚本会回退下载） |

---

### 第一步：登录 Linux 服务器

使用 Xshell、FinalShell、PuTTY 或云厂商 Web 控制台（阿里云、腾讯云等）登录。

登录成功后提示符类似：

```text
yourname@server:~$
```

若不知道如何登录，请联系提供服务器的人，获取 **IP 地址、用户名、密码**。

---

### 第二步：逐行执行命令

**重要：每次只复制一行，粘贴后按回车，等它执行完再继续下一行。**

#### ① 获取管理员权限

```bash
sudo su
```

若提示输入密码：输入**当前用户密码**（输入时不显示 `*`，属正常）。成功后提示符变为 `#`，例如 `root@server:~#`。

#### ② 进入目录（用于存放脚本）

```bash
cd /opt
```

也可使用 `cd /home/ubuntu`（或任意有写权限的目录）。**应用始终部署到** `/home/ubuntu/app-deploy/`，与当前目录无关。

#### ③ 下载最新部署脚本

```bash
curl -fsSL -o deploy-repo.sh https://raw.githubusercontent.com/Dinopell/TK_learn/feature/deploy-repo.sh
```

| 写法 | 是否正确 |
|------|----------|
| `curl -fsSL -o deploy-repo.sh https://raw.githubusercontent.com/...` | ✅ 推荐 |
| `curl -O https://raw.githubusercontent.com/...` | ❌ 不推荐：失败时可能把错误页保存成脚本；且文件名依赖 URL 末尾 |

#### ④ 确认脚本版本（必做）

```bash
grep DEPLOY_SCRIPT_VER deploy-repo.sh
```

应包含 `20260531-bypass-lfs-curl`。若仍是旧版本，请重新执行第 ③ 步，或联系运维推送新脚本后再部署。

#### ⑤ 添加执行权限

```bash
chmod +x deploy-repo.sh
```

#### ⑥ 开始部署

```bash
bash ./deploy-repo.sh
```

- 首次部署约 **3–10 分钟**（含 Docker 镜像、JAR 约 155MB 等）
- 默认静默：详细日志见 `/home/ubuntu/app-deploy/deploy.log`
- 需完整输出时：`DEPLOY_VERBOSE=1 bash ./deploy-repo.sh`
- 若提示宿主机 Nginx 强制 HTTPS：`FIX_HOST_NGINX=1 bash ./deploy-repo.sh`

---

### 第三步：部署成功标志

终端最后应出现类似：

```text
TK 子台部署完成！

子台管理端（仅 HTTP，请妥善保存入口）:
  http://你的服务器IP/<随机入口>/

默认登录账号: admin
默认登录密码: admin123
```

请记录管理端入口。若终端未显示，可执行：

```bash
cat /home/ubuntu/app-deploy/conf/admin-entry.txt
```

浏览器访问 **`http://服务器IP/<入口>/`** 打开管理端（地址栏请手输 `http://`，不要用 `https://`），**登录后立即修改默认密码**。

> 子台管理端使用 **HTTP**；已部署用户源码对外使用 **HTTPS**（需在管理端配置域名并申请证书，见下方说明）。**切勿把服务器公网 IP 填进资产「域名」**，否则可能无法打开管理端（见常见问题）。

---

### 第四步：验证（建议）

```bash
docker ps
file /home/ubuntu/app-deploy/repo_source/dist.zip
file /home/ubuntu/app-deploy/repo_source/springboot-app.jar
cat /home/ubuntu/app-deploy/conf/admin-entry.txt
curl -sI "http://127.0.0.1/$(tr -d '[:space:]' < /home/ubuntu/app-deploy/conf/admin-entry.txt)/" | head -3
```

预期：

- `docker ps` 中应有 `app-deploy-backend-1`、`app-deploy-frontend-1`、`app-deploy-mysql-1` 等容器
- `dist.zip` 为 `Zip archive`
- `springboot-app.jar` 为 `Java archive`
- 管理端 `curl` 首行含 `HTTP/1.1 200`（勿跟 `-L`，避免跟到 HTTPS）

---

### 重新部署 / 更新

```bash
sudo su
cd /opt
curl -fsSL -o deploy-repo.sh https://raw.githubusercontent.com/Dinopell/TK_learn/feature/deploy-repo.sh
grep DEPLOY_SCRIPT_VER deploy-repo.sh
bash ./deploy-repo.sh
```

**注意（HTTPS 证书）**：当前部署脚本在每次执行时，会将自签名占位证书复制到 `letsencrypt/live/tk-substation/`。若子台已通过管理端申请过 Let's Encrypt 证书，**重新跑部署脚本可能覆盖已有 HTTPS 证书**。更新前建议：

```bash
cp -a /home/ubuntu/app-deploy/letsencrypt /home/ubuntu/app-deploy/letsencrypt.bak.$(date +%F)
```

若更新后 HTTPS 异常，需在管理端重新申请证书（勿短时间内反复申请，避免 Let's Encrypt 频率限制），或联系运维恢复 `live/tk-substation/` 软链接。

---

### 申请 HTTPS 证书（已部署源码）

1. 登录子台管理端，完成源码部署（状态为「已部署」）
2. 在「配置」中填写**证书申请邮箱**并保存
3. 为每个用户访问域名配置 **A 记录** 指向子台公网 IP（填真实域名，**不要填服务器 IP**）
4. 确认安全组已放行 **TCP 80、443**
5. 在资产卡片点击「申请证书」

证书写入 `/etc/letsencrypt/live/tk-substation/`（多域名一张证）。若部分域名失败，界面会显示具体域名与原因。

---

### 常见问题

| 现象 | 处理 |
|------|------|
| `smudge filter lfs failed` | 重新下载脚本，确认版本为 `20260531-bypass-lfs-curl` |
| `下载失败: dist.zip` 或 JAR | 检查网络；联系运维确认 GitHub **Published** Release 已上传 `dist.zip`、`springboot-app.jar` |
| `缺少总台签名包` | 确认仓库 `deploy/master.endpoint.pkg` 存在，使用最新 `feature` 分支 |
| 浏览器「重定向太多次」 | 管理端必须用 `http://IP/<入口>/`；勿把 **IP 当域名** 配进资产；无痕窗口重试；见下条 |
| 残留 `domain-*.conf` | 新版脚本部署时会自动删除；或手动：`rm -f /home/ubuntu/app-deploy/backend-data/nginx-dynamic/assets/domain-*.conf` 后 `docker exec app-deploy-frontend-1 nginx -s reload` |
| 浏览器打不开管理端 | 安全组放行 TCP 80；确认 `admin-entry.txt` 与 URL 中入口一致 |
| HTTP 被强制跳 HTTPS | `FIX_HOST_NGINX=1 bash ./deploy-repo.sh`；关闭浏览器「始终使用安全连接」 |
| 申请证书报 DNS / 验证失败 | 确认域名 A 记录、80 端口可达；域名与配置一致（含后缀如 `.cn`） |
| 重新部署后 HTTPS 失效 | 见上方「重新部署 / 更新」证书备份说明 |

查看部署错误：

```bash
tail -100 /home/ubuntu/app-deploy/deploy.log
```

查看容器状态：

```bash
docker ps -a
docker logs --tail 50 app-deploy-backend-1
docker logs --tail 50 app-deploy-frontend-1
```
