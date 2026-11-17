# Contributing

## 报告问题前

先看 [`docs/troubleshooting.md`](docs/troubleshooting.md) 的判定矩阵。大部分故障都在里面。

提交 issue 时请附：

1. 设备内核版本：`uname -a`
2. 驱动版本：`lsmod | grep ice_sw` 或 `dmesg | grep ice_sw`
3. netdev 列表：`ip link show`（**先脱敏**）
4. `docs/troubleshooting.md` 里对应层的判定结果
5. 日志片段（`nat.log` / `dnsmasq.log`）

## 禁止提交的内容

这些一律不接受，PR 会被直接关闭：

| 类型 | 原因 |
|---|---|
| 真实 IP / MAC / 主机名 | 隐私与安全 |
| 私钥、证书、口令 | 安全 |
| 厂商固件（`.stk` / `.bin` / `.img`） | 无分发授权 |
| 反编译/反汇编产物 | 法律风险 |
| 厂商二进制（`natd` 等） | 无分发授权；请提供构建脚本 |

`.gitignore` 已覆盖大部分，但**提交前请自己再扫一遍**：

```sh
git diff --cached | grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
```

## 代码风格

- Shell：POSIX `sh`，不用 bashism；所有脚本必须**幂等**
- 配置：所有环境相关值走环境变量，不硬编码
- 注释：解释**为什么**，不是**做什么**

## 提交流程

1. Fork → 分支
2. 改完自测：`sh -n` 语法检查 + 在真机验证
3. PR 描述写清：改了哪层、为什么、怎么验证的
