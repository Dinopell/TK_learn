-- 资产访问地址拼接方式：slash=路径(域名/后缀)，dot=子域(域名.后缀)
-- 幂等：列已存在则跳过（支持部署脚本自动补跑 / FORCE_MIGRATIONS=1）
SET @tk_mig_col_exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'user_assets'
      AND COLUMN_NAME = 'entry_join_mode'
);
SET @tk_mig_sql := IF(
    @tk_mig_col_exists = 0,
    'ALTER TABLE `user_assets` ADD COLUMN `entry_join_mode` varchar(16) NOT NULL DEFAULT ''slash'' COMMENT ''访问地址拼接：slash 或 dot'' AFTER `frontend_entry`',
    'SELECT 1'
);
PREPARE tk_mig_stmt FROM @tk_mig_sql;
EXECUTE tk_mig_stmt;
DEALLOCATE PREPARE tk_mig_stmt;
