
# ================================
# MinIO Backup 用户权限配置案例
# 场景:
# 数据库备份服务器上传备份文件到 MinIO
#
# 目标:
# backup-user 用户只能访问 backup Bucket
# 可以上传/下载备份文件
# 不能访问其他 Bucket
# ================================

# 1. 管理员登录 MinIO
# 使用管理员账号创建资源和授权

mc alias set minio https://minio.example.com admin admin-password

# 2. 创建备份 Bucket
# Bucket 类似对象存储中的顶级目录

mc mb minio/backup

# 3. 创建备份专用用户
# AccessKey:
#     backup-user
#
# SecretKey:
#     backup-pass
#
# 应用后续使用这个账号上传备份

mc admin user add minio \
backup-user \
backup-pass



# 4. 创建权限策略文件
# 定义 backup-user 可以执行哪些操作
#
# s3:PutObject
#     上传对象
#
# s3:GetObject
#     下载对象
#
# s3:ListBucket
#     查看 Bucket 内容

cat > backup-policy.json <<EOF
{
 "Version":"2012-10-17",
 "Statement":[
  {
   "Effect":"Allow",
   "Action":[
    "s3:GetObject",
    "s3:PutObject",
    "s3:ListBucket"
   ],
   "Resource":[
    "arn:aws:s3:::backup",
    "arn:aws:s3:::backup/*"
   ]
  }
 ]
}
EOF



# 5. 创建 MinIO Policy
# 把权限规则导入 MinIO

mc admin policy create \
minio \
backup-policy \
backup-policy.json



# 6. 将 Policy 绑定给用户
#
# 用户:
# backup-user
#
# 权限:
# backup-policy
#
# 关系:
#
# backup-user
#       |
#       |
# backup-policy
#       |
#       |
# backup Bucket

mc admin policy attach \
minio \
backup-policy \
--user backup-user



# ================================
# 客户端使用
# ================================


# 7. 在备份服务器配置 MinIO 登录信息
#
# 这里不是创建用户
# 而是在本机保存访问凭证

mc alias set backup-store \
https://minio.example.com \
backup-user \
backup-pass



# 8. 测试访问权限

# 查看 Bucket
# 可以看到 backup

mc ls backup-store/backup



# 9. 上传数据库备份

# 本地文件:
# mysql.sql
#
# 上传目标:
# backup Bucket
# mysql目录

mc cp mysql.sql \
backup-store/backup/mysql/mysql.sql



# 10. MinIO最终存储结构

backup Bucket

backup
 └── mysql
      └── mysql.sql



# ================================
# 权限结果
# ================================

backup-user:

允许:
  ✓ 上传 backup/*
  ✓ 下载 backup/*
  ✓ 查看 backup/*


禁止:
  ✗ 访问 harbor Bucket
  ✗ 访问 log Bucket
  ✗ 使用管理员权限


# 最终权限模型:

用户(AccessKey)
        |
        |
权限策略(Policy)
        |
        |
Bucket/Object


# 生产最佳实践:

一个业务
 =
一个 MinIO 用户
 +
一个独立 Policy
 +
一个独立 Bucket
```