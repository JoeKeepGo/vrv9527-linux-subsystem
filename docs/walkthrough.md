# VRV9527 获取 root SSH 完整过程记录

设备：Spark Smart Modem 3（Arcadyan VRV9527，固件 v1.00.08_build02，aarch64）
状态：运营商合约结束、设备归用户所有，目标是完全掌控。

本文记录完整的探索过程，包括所有走不通的路（比成功的路多得多），
方便后来者避坑。

## 0. 攻击面摸底

nmap 全端口扫描结果：

| 端口 | 服务 | 说明 |
|---|---|---|
| 53 | DNS | Akamai CacheServe |
| 80/443 | Web 管理 | Arcadyan 定制 |
| 8110 | halcap | 私有二进制协议，未深入 |
| 43597 | MiniUPnP | |
| 55661 | lighttpd 1.4.53 | JSON API 路径未知，常见路径全 404 |

22 (SSH)、23 (Telnet)、7547 (TR-069 服务端) 全部关闭。

## 1. Web 登录加密（已复刻，tools/vrv.py）

登录页 `login.htm` 里有一张 spacer GIF，data URI 的 base64 在标准 GIF
头（78 字符）之后还拖着一段数据：`key[32] + iv[16] + httoken[48]`。
用户名密码的提交值 = AES-256-CBC(key, iv, SHA512(MD5(x)) 的 hex 字符串
的 ASCII 字节)，nopad，输出 `%xx` 百分号编码。POST `/login.cgi` 字段
顺序 `httoken,pws,usr`，**必须带 Referer: /login.htm**。

坑：固件单会话限制（重复登录 err=2，先 logout.cgi）；连续错密码锁 15 秒
（err=7）；非登录页的 GIF 数据段结构不同，httoken 取法不一样。

## 2. 配置备份加解密（工具可用）

- 导出：`/cgi/cgi_sys_bk.js?_tn=<token>&_t=<ms>` 生成，`/tmp/SmartModem_backup.cfg` 下载
- 加解密：VRV9517 的 `arcadyan_util.py` 直接用得上（密钥 = 出厂主 WiFi 密码）
- 主配置 `.glbcfg`：7000+ 行 `ARC_*` 键值

回传验证了很多次才摸清：

- 响应**超时是正常的**，文件已生效（重新下载备份验证标记值即可）
- `G_err=-8` 秒回 = 打包不对：uid/gid 必须 0、成员顺序、`.glbcfg` 0666
- **sanitize 机制**：`ARC_SSHD_ENABLE`、`ARC_SSHD_AUTO_DISABLE`、
  `ARC_SYS_SCHEDULER_*` 等键会被强制回退成出厂值——配置回传这条路
  开不了 SSH，死了这条心

## 3. 走不通的路（都有实验证据）

- **Telnet**：`ARC_TELNETD_ENABLE=1` 能写进去并存活重启，但 23 端口不开，
  固件编译时阉割了 daemon
- **Scheduler 命令注入**（配置回传路径）：Command 被 sanitize 回 reboot
- **配置 tgz tar slip**：`../`、绝对路径全被过滤
- **服务配置文件注入**：改 tarball 里的 samba 配置无效，运行时配置从
  `.glbcfg` 重新生成
- **DDNS/NTP 分号注入**：服务端校验拦截
- **官方固件逆向**：官网能下到 v1.00.06 固件但整包加密，binwalk 零签名
- **SMB 符号链接逃逸**：ext4 U 盘 + debugfs 植入 `escape -> /`，路由器
  能挂载、marker 可读，但顺链接访问 Permission denied（smbd wide links=no）
- **FTP chroot 逃逸**：chroot 在 /tmp/usb，出不去

## 4. TR-069 通道（突破口）

`.glbcfg` 里 CWMP 是开着的（`ARC_TR69_EnableCWMP=1`），指向运营商 ACS。
关键键：

```
ARC_TR69_URL=http://<运营商ACS>:7547/...
ARC_TR69_Username=<OUI>-<ProductClass>-<Serial>   # ConnectionRequest digest 也用这对
ARC_TR69_Password=...
ARC_TR69_ConnectionRequestURL=http://<WAN-IP>:8081/ConnectionRequest
```

步骤：

1. 自建最小 ACS（tools/acs.py），改 `ARC_TR69_URL` 指过来（此键不在
   sanitize 列表），配置回传生效
2. 路由器立刻 Inform（VALUE CHANGE）；以后用 ConnectionRequest（digest
   认证，内网走 WAN IP hairpin）随叫随到
3. `GetParameterNames Device.` 一层层枚举，在 `Device.X_ARC_COM.` 下
   找到 **`SSHEnable`，Writable=1**
4. `SetParameterValues SSHEnable=1`（Status=0 立即生效）→ 22 开，
   `root / Spark@Modem3` 登录，uid=0

CWMP 协议要点：Inform→InformResponse；CPE 空 POST 时 ACS 才能下发请求；
响应头记得带 cwmp:ID；namespace 用设备自报的（urn:dslforum-org:cwmp-1-2）。

## 5. 持久化（最绕的一段）

开 SSH 后发现两个坑：

1. `sshd_delay_close -s restart -t 24:00:00`：24 小时后自动
   `mngcli set ARC_SSHD_ENABLE=0; mngcli commit`
2. 重启后即使 flash 里 `ARC_SSHD_ENABLE=1`，sshd 也**不会自启**
   （实测观测 10 分钟）；它是 mng 事件驱动的，只被 CWMP/UI 动作拉起
3. 每次 CWMP/mngcli 开 SSH，都会把 `ARC_SSHD_AUTO_DISABLE` 重置回 1
   并重新挂出看门狗——所以改配置关 auto-disable 没用

探索过的持久化原语：

- `/data`：ext4 rw 持久分区（断电不丢）✓ 可以放脚本
- `/etc/crond/root`：tmpfs，开机重建；busybox crond 本身可用（标准格式
  `* * * * *` 能跑）
- Scheduler → crontab：配置持久化、开机自动重建条目，但格式是
  `$Time $Command` 原样拼接，`Time=06:30` 会生成非法行（busybox crond
  不识别，甚至会把 crond 搞到反复重启）
- **突破**：既然原样拼接，把 `ARC_SYS_SCHEDULER_0_Time` 直接设成
  `*/5 * * * *`，拼出来就是合法 cron 行！mngcli 不做格式校验

最终方案：

```
mngcli set "ARC_SYS_SCHEDULER_0_Command=/bin/sh /data/keepssh.sh"
mngcli set "ARC_SYS_SCHEDULER_0_Time=*/5 * * * *"
mngcli set ARC_SYS_SCHEDULER_0_Enable=1
mngcli commit
```

`/data/keepssh.sh`：杀 sshd_delay_close；sshd 不在就 `/usr/sbin/sshd -p 22`
直启（直启不会触发看门狗，而且验证过可以直接密码登录）。

验证：cron 每 5 分钟触发 ✓；kill sshd 后 5 分钟内复活 ✓；重启后自启 ✓。

## 6. 杂项备忘

- 本机 busybox 没有 `setsid`/`nohup`，`killall sshd` 会踢掉自己；
  测试"死后复活"就用 cron 当 detacher
- `sed` 直接改 `/etc/config/.glbcfg` 无效：`mng_cli commit` 提交的是
  mng 内存态，会把你 sed 的内容覆盖掉。改配置一律 `mngcli set` + `commit`
- SSH host key 每次重启重新生成（/etc/ssh 是 ro squashfs + /tmp 临时区），
  客户端记得 `UserKnownHostsFile=/dev/null`
- 改完 `ARC_TR69_URL` 后运营商 ACS 即失效，这本来就是目的；
  心跳间隔可用 CWMP 改成 3600s 加快自愈
