-- 资产访问地址拼接方式：slash=路径(域名/后缀)，dot=子域(域名.后缀)
ALTER TABLE `user_assets`
    ADD COLUMN `entry_join_mode` varchar(16) NOT NULL DEFAULT 'slash'
        COMMENT '访问地址拼接：slash 或 dot' AFTER `frontend_entry`;
