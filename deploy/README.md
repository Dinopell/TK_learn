# 子台部署说明（RSA 签名总台配置）

## 架构

- 运维机持有 **RSA 私钥**（`scripts/keys/master-sign-private.pem`，**勿提交 Git**）
- 仓库内仅有 **公钥**（打包进 `springboot-app.jar`）与 **签名包** `master.endpoint.pkg`
- 子台部署用户 **不能** 设置 `MASTER_URL`；只能使用仓库中的 `.pkg` 文件

## 一、运维首次准备（只做一次）

### 1. 生成密钥对（若尚未生成）

```bash
cd TK_learn
mkdir -p scripts/keys
openssl genrsa -out scripts/keys/master-sign-private.pem 2048
openssl rsa -in scripts/keys/master-sign-private.pem -pubout \
  -out scripts/keys/master-sign-public.pem
```

将公钥同步到后端工程（与私钥配对）：

```bash
cp scripts/keys/master-sign-public.pem \
  ../TK_projects/RuoYi-Vue/ruoyi-common/src/main/resources/certs/master-sign-public.pem
```

### 2. 打包后端 JAR（JDK 17）

```bash
cd ../TK_projects/RuoYi-Vue
mvn -pl ruoyi-admin -am package -DskipTests
cp ruoyi-admin/target/ruoyi-admin.jar ../../TK_learn/springboot-app.jar
```

### 3. 签发总台配置包

在**运维本机**（勿在子台服务器输入明文）：

```bash
cd TK_learn
export MASTER_PLAIN_URL='https://你的总台/prod-api'
export MASTER_PLAIN_API_KEY='你的API密钥'
export MASTER_PLAIN_SSL_INSECURE=1   # 总台为自签 HTTPS 时
# 可选：默认 365 天（1 年）；10 年用 export MASTER_SIGN_DAYS=3650
export MASTER_SIGN_DAYS=365

bash scripts/sign-master-endpoint.sh
# 输出: deploy/master.endpoint.pkg
```

### 4. 提交并推送

```bash
git add deploy/master.endpoint.pkg springboot-app.jar deploy-repo.sh
git push origin feature
```

---

## 二、子台服务器部署（给用户执行的步骤）

```bash
sudo su
cd /opt
curl -O https://raw.githubusercontent.com/Dinopell/TK_learn/feature/deploy-repo.sh
chmod +x deploy-repo.sh
bash ./deploy-repo.sh
```

脚本会：克隆 `feature` 分支 → 读取 `deploy/master.endpoint.pkg` → 注入容器环境变量 `MASTER_ENDPOINT_PKG` → 后端启动时 **验签** 后连接总台。

部署完成后访问（示例）：

- 管理端：`http://服务器IP/<随机入口>/`
- 默认账号：`admin` / `admin123`（登录后请改密）

---

## 三、更换总台地址

1. 运维本机重新执行「签发总台配置包」（第三节 3）
2. 提交新的 `deploy/master.endpoint.pkg` 并推送
3. 子台服务器重新执行 `bash deploy-repo.sh`（或进入 `app-deploy/repo_source` 后 `git pull` 再跑脚本）

**无需**改 `deploy-repo.sh`，**无需**子台部署者知道新地址。

---

## 四、签名包过期

`master.endpoint.pkg` 内 `exp` 字段到期后，子台后端将拒绝启动。请提前重新签发并部署。

---

## 五、禁止事项

| 禁止 | 说明 |
|------|------|
| 提交私钥 | `scripts/keys/master-sign-private.pem` 已在 `.gitignore` |
| 子台设置 `MASTER_URL` | 后端启动失败 |
| 子台自行伪造 `.pkg` | 无私钥无法通过验签 |
