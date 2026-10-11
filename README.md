# QMS-Signature

一个在安卓Termux中使用的APK签名与打包脚本。

## 功能

- 移除APK旧签名
- 使用apksigner重新签名
- 验证签名
- 打包已签名APK为ZIP
- 输出证书SHA256、APK SHA256、ZIP SHA256
- 支持Argon2id + AES-256加密保存配置
- 自动备份/恢复Keystore

## 依赖

在Termux中安装：

```bash
pkg install openssl-tool argon2 zip openjdk-17
