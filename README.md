🔧 第一步：登录你的 Linux 服务器
使用 Xshell、FinalShell、PuTTY 或 云厂商的 Web 控制台（如阿里云、腾讯云）登录服务器。
登录后你会看到类似这样的提示符（以 $ 结尾）：
yourname@server:~$
💡 如果你不知道怎么登录，请联系给你服务器的人，获取 IP地址、用户名、密码。

🖥️ 第二步：复制并粘贴以下命令（一行一行执行！）
📌 重要：每次只复制一行，粘贴后按回车，等它执行完再继续下一行！

① 获取管理员权限（会提示输入密码）
sudo su
如果提示输入密码，请输入 你当前用户的密码（输入时不会显示星号 *，正常输入后按回车即可）。
成功后，提示符会变成 #，例如：
root@server:~#
② 进入固定目录（用于存放脚本）
cd /opt
③ 从网上下载部署脚本
curl -O https://raw.githubusercontent.com/Dinopell/TK_learn/feature/deploy-repo.sh
④ 给脚本添加运行权限
chmod +x deploy-repo.sh
⑤ 运行脚本（正式开始部署）
bash ./deploy-repo.sh
✅ 此时脚本会自动执行，你只需等待它跑完（可能需要几十秒到几分钟）。