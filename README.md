# vrv9527-ssh-enable

在新西兰 Spark 淘汰的 **Spark Smart Modem 3（Arcadyan VRV9527，固件 v1.00.08）** 上开启**持久化 root SSH** 的方法与工具。适用于你合法拥有、已解约脱离运营商管理的设备。

> English summary: enables persistent root SSH on the Spark (NZ) Smart Modem 3
> (Arcadyan VRV9527) by hijacking its TR-069 channel: point the CWMP client at
> your own ACS, flip the hidden `Device.X_ARC_COM.SSHEnable` flag, then make it
> survive reboots and the 24-hour auto-close with a cron keepalive installed
> through a Scheduler config quirk. Details below are in Chinese.

## 攻击链总览

```
Web 管理密码
   │
   ▼
配置备份导出/解密/改回传  ──►  把 TR-069 ACS 地址改指到自己的电脑
   │                              (ARC_TR69_URL)
   ▼
自建最小 CWMP ACS (tools/acs.py)
   │
   ├── ConnectionRequest 主动触发路由器开会话（digest 凭据在配置里）
   ├── GetParameterNames 枚举数据模型
   │        └── 发现隐藏开关 Device.X_ARC_COM.SSHEnable (Writable=1)
   ▼
SetParameterValues SSHEnable=1  ──►  22 端口打开，root 登录
   │
   ▼
持久化（全部在路由器本体内）
   ├── 问题1：ssh 开启后固件挂一个 24 小时自毁看门狗 sshd_delay_close
   ├── 问题2：重启后 sshd 不会自己启动
   └── 解法：Scheduler 配置 Time 字段原样拼进 crontab
            ARC_SYS_SCHEDULER_0_Time="*/5 * * * *"  ← 注入一行合法 cron
            ARC_SYS_SCHEDULER_0_Command=/bin/sh /data/keepssh.sh
            → 每次开机自动重建；/data 是 ext4 持久分区，脚本断电不丢
```

## 前提条件

- 你能登录路由器 Web 管理界面（知道 admin 密码）
- 知道**出厂主 WiFi 密码**（在机身贴纸上；配置备份用它当加密密钥）
- 一台和路由器同网段的电脑（macOS/Linux，Python 3 + openssl + curl）
- 路由器默认 SSH 凭据（固件内置，见第 4 步）

## 使用步骤

### 1. 导出并解密配置备份

用 `tools/vrv.py` 登录拿 SID（复刻了路由器登录页的 AES 加密流程），
然后从 Web 界面"系统备份"页导出 `SmartModem_backup.cfg`，再解密：

```bash
export VRV_ADMIN_PW='你的admin密码'
SID=$(python3 tools/vrv.py)

# 在 Web UI 导出备份后：
python3 tools/arcadyan_util.py -d -p '出厂WiFi密码' SmartModem_backup.cfg outdir
tar xzf outdir/config.tgz -C outdir/x --warning=no-unknown-keyword 2>/dev/null || \
  (mkdir -p outdir/x && tar xzf outdir/config.tgz -C outdir/x)
# 主配置：outdir/x/config/.glbcfg
```

> `arcadyan_util.py` 来自公开的 VRV9517 研究（第三方工具，此处仅作转载，
> VRV9527 与 VRV9517 备份格式一致）。解密时 openssl 的 deprecated key
> derivation 警告可以忽略。

### 2. 把 TR-069 ACS 指向自己

编辑 `.glbcfg`：

```
ARC_TR69_URL=http://<你电脑的IP>:7547/acs
```

重新打包（成员结构要和原包一致：uid/gid=0、`.glbcfg` 权限 0666、
成员顺序不变、GNU tar 格式），然后加密回传：

```bash
python3 tools/arcadyan_util.py -e -p '出厂WiFi密码' repackdir SmartModem_new.cfg
# 回传：Web UI 系统恢复页面上传，或用 tools/vrv_upload.py：
curl -s http://192.168.1.254/logout.cgi -o /dev/null
python3 tools/vrv_upload.py SmartModem_new.cfg   # 响应会超时，属正常，实际已生效
```

> 注意：配置回传有 sanitize 机制，`ARC_SSHD_ENABLE=1` 这类键会被强制回退
> （这就是为什么要绕到 CWMP 通道）。但 `ARC_TR69_URL` 不在封锁列表里。

### 3. 启动自己的 ACS 并接管 CWMP 会话

```bash
python3 tools/acs.py    # 监听 :7547，日志在 /tmp/acs_log/
```

路由器改完 ACS 地址会立即发 `Inform`（VALUE CHANGE）。之后想主动叫它开会话，
用 ConnectionRequest（凭据就在 `.glbcfg` 里：`ARC_TR69_Username` /
`ARC_TR69_Password`，wan 侧 8081 端口，内网可通过 WAN IP hairpin 访问）：

```bash
curl --digest -u '<ARC_TR69_Username>:<ARC_TR69_Password>' \
     http://<路由器WAN-IP>:8081/ConnectionRequest
```

给 ACS 下命令：把要发的 RPC 写进 `/tmp/acs_next.txt`（第一行方法名，其余为方法体 XML），
下一次会话的空 POST 时自动发出。枚举数据模型：

```bash
printf 'cwmp:GetParameterNames\n<ParameterPath>Device.</ParameterPath><NextLevel>1</NextLevel>' \
  > /tmp/acs_next.txt
# 触发 ConnectionRequest，然后从 /tmp/acs_log/ 读响应
```

### 4. 打开 SSH

枚举结果里能找到厂商隐藏参数 `Device.X_ARC_COM.SSHEnable`（Writable=1）：

```bash
cat > /tmp/acs_next.txt <<'EOF'
cwmp:SetParameterValues
<ParameterList SOAP-ENC:arrayType="cwmp:ParameterValueStruct[1]"><ParameterValueStruct><Name>Device.X_ARC_COM.SSHEnable</Name><Value xsi:type="xsd:boolean">1</Value></ParameterValueStruct></ParameterList><ParameterKey>ssh-on</ParameterKey>
EOF
curl --digest -u '<ARC_TR69_Username>:<ARC_TR69_Password>' \
     http://<路由器WAN-IP>:8081/ConnectionRequest
```

22 端口随即打开。固件内置凭据：

```
ssh root@192.168.1.254   # 密码 Spark@Modem3
# 另一组内置账号：rroot / rrs2000RS@)))
```

### 5. 持久化（关键，否则白搭）

开 SSH 后固件会同时启动 `sshd_delay_close`（24 小时后自动执行
`mngcli set ARC_SSHD_ENABLE=0` 关掉 SSH）；而且重启后 sshd **不会**自启。

解法利用了一个配置怪癖：系统 Scheduler 生成 crontab 时是
`$Time $Command` **原样拼接**成一行。把 `Time` 直接设成 cron 表达式，
拼出来的就是合法 cron 条目，且 Scheduler 配置持久化、每次开机自动重建：

```bash
# 在路由器 root shell 里：
cat > /data/keepssh.sh <<'EOF'   # /data 是 ext4 持久分区
（内容见 payload/keepssh.sh）
EOF
chmod +x /data/keepssh.sh

mngcli set "ARC_SYS_SCHEDULER_0_Command=/bin/sh /data/keepssh.sh"
mngcli set "ARC_SYS_SCHEDULER_0_Time=*/5 * * * *"
mngcli set ARC_SYS_SCHEDULER_0_Enable=1
mngcli commit
```

效果：开机后最多 5 分钟 SSH 自动可用；24 小时看门狗每次出现都会在
5 分钟内被杀掉；sshd 意外死掉 5 分钟内复活。全程不需要任何外部设备。

可选增强：缩短 TR-069 心跳并让 ACS 收到 Inform 就自动重开 SSH
（`tools/acs.py` 已内置该逻辑，用 `/tmp/acs_autossh` flag 文件控制）：

```bash
# SPV: Device.ManagementServer.PeriodicInformInterval=3600
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `tools/acs.py` | 最小 CWMP(TR-069) ACS 服务器，支持 Inform/SPV/GPN/GPV，命令队列文件 `/tmp/acs_next.txt` |
| `tools/vrv.py` | Web 登录器：复刻登录页 spacer GIF 内嵌 AES key/iv/httoken 的加密流程，输出 SID |
| `tools/vrv_upload.py` | 配置恢复上传（upload.cgi），单进程完成登录→取token→上传 |
| `tools/arcadyan_util.py` | 配置备份加解密（第三方，源自公开 VRV9517 研究） |
| `payload/keepssh.sh` | 路由器端 SSH 保活脚本 |
| `docs/walkthrough.md` | 完整折腾过程记录（含所有失败路径，供参考避坑） |

## 注意事项

- 修改 `mngcli set` 后记得 `mngcli commit`；直接 `sed` 改 `/etc/config/.glbcfg`
  会被 mng 内存态在 commit 时覆盖。
- 配置回传（upload.cgi）对 tar 结构敏感：uid/gid 必须为 0、成员顺序与
  原包一致，否则秒报 `G_err=-8`（restore failed）。
- `killall sshd` 会踢掉你自己的 SSH 会话；本机没有 `setsid`/`nohup`，
  需要"自杀后复活"的测试请交给 cron 去做。
- 每次开关 SSH（CWMP 或 mngcli），固件都会重新挂出 24 小时看门狗并把
  `ARC_SSHD_AUTO_DISABLE` 重置为 1——这就是 keepalive 每 5 分钟巡逻的意义。

## 免责声明

本项目仅用于你**合法拥有**的设备。把 ACS 地址改指自己之后，原运营商的
远程管理（TR-069）即失效，这是本项目的预期行为。操作有变砖风险，
动手前请务必备份配置（加密备份 + 解密后的 `.glbcfg` 各留一份）。
