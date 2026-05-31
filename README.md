> **运维**：总台 RSA 签名、换台、打包 JAR 见 [deploy/README.md](deploy/README.md)

## 子台服务器部署（用户操作手册）

适用：Ubuntu 20.04 / 22.04，需能访问 GitHub，安全组放行 **TCP 80**。

### 第一步：登录 Linux 服务器

使用 Xshell、FinalShell、PuTTY 或云厂商 Web 控制台登录。

登录成功后提示符类似：

```text
yourname@server:~$
```

若不知道如何登录，请联系提供服务器的人，获取 **IP 地址、用户名、密码**。

### 第二步：逐行执行命令

**重要：每次只复制一行，粘贴后按回车，等执行完再继续下一行。**

#### ① 获取管理员权限

```bash
sudo su
```

若提示输入密码：输入**当前用户密码**（输入时不显示 `*`，属正常）。成功后提示符变为 `#`，例如 `root@server:~#`。

#### ② 进入固定目录

```bash
cd /opt
```

> 应用实际部署到 `/home/ubuntu/app-deploy/`，与下载脚本的目录无关。

#### ③ 下载最新部署脚本

```bash
curl -fsSL -o deploy-repo.sh https://raw.githubusercontent.com/Dinopell/TK_learn/feature/deploy-repo.sh
```

#### ④ 确认脚本版本（推荐）

```bash
grep DEPLOY_SCRIPT_VER deploy-repo.sh
```

应包含 `20260531-bypass-lfs-curl`。若仍是旧版本，请联系运维推送新脚本后再部署。

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

### 第三步：部署成功标志

终端最后应出现类似：

```text
TK 子台部署完成！

子台管理端（仅 HTTP，请妥善保存入口）:
  http://你的服务器IP/<随机入口>/

默认登录账号: admin
默认登录密码: admin123
```

请记录 `/<随机入口>/`，浏览器访问 `http://服务器IP/<入口>/` 打开管理端，**登录后立即修改默认密码**。

### 第四步：验证（建议）

```bash
docker ps
file /home/ubuntu/app-deploy/repo_source/dist.zip
file /home/ubuntu/app-deploy/repo_source/springboot-app.jar
cat /home/ubuntu/app-deploy/conf/admin-entry.txt
```

预期：`dist.zip` 为 `Zip archive`，`springboot-app.jar` 为 `Java archive`。

### 重新部署 / 更新

```bash
cd /opt
curl -fsSL -o deploy-repo.sh https://raw.githubusercontent.com/Dinopell/TK_learn/feature/deploy-repo.sh
bash ./deploy-repo.sh
```

### 常见问题

| 现象 | 处理 |
|------|------|
| `smudge filter lfs failed` | 重新下载脚本，确认版本为 `20260531-bypass-lfs-curl` |
| `下载失败: dist.zip` 或 JAR | 检查网络；联系运维确认 GitHub Releases 已上传附件 |
| 浏览器打不开 | 云安全组放行 TCP 80 |
| HTTP 被强制跳 HTTPS | `FIX_HOST_NGINX=1 bash ./deploy-repo.sh` |

查看错误：`tail -100 /home/ubuntu/app-deploy/deploy.log`
