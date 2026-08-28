# LNMP 2.3 改造版（官方源优先 + 二进制数据库优先）

基于 [lnmp.org](https://lnmp.org) LNMP 2.3 一键安装包的改造版本，主要改动：

- **官方源优先下载**：所有软件包优先从官方渠道下载（nginx.org、php.net、cdn.mysql.com、archive.mariadb.org、pecl.php.net、GitHub Releases、ftp.gnu.org 等），官方源不可用时自动回退到 lnmp 镜像，彻底解决第三方链接失效导致安装失败的问题
- **数据库默认使用二进制安装**：MySQL / MariaDB 默认使用官方通用二进制包（glibc builds）部署，无需漫长编译，性能与官方编译参数一致，且可选择源码编译
- 修复了原脚本若干下载 Bug（MariaDB 5.5 二进制包名、MySQL 8.x aarch64 glibc 版本等）

## 环境要求

- 系统：CentOS / RHEL / Rocky / Alma / Debian / Ubuntu / Amazon Linux / openEuler 等主流发行版
- 需要 root 权限
- 磁盘空间：至少 10GB 以上可用空间（二进制安装数据库时可大幅减少）
- 已安装 `wget`（如未安装：`yum install wget` 或 `apt-get install wget`）
- 国内 VPS 建议先配置好 DNS，安装过程中需要联网下载软件包

## 一、下载本仓库到 VPS

### 方式 1：git clone（推荐）

```bash
# VPS 已安装 git
yum -y install git    # CentOS/RHEL
apt-get -y install git    # Debian/Ubuntu

git clone https://github.com/sakz/lnmp2.3.git
cd lnmp2.3
```

> 国内 VPS 访问 GitHub 缓慢时，可使用加速代理：
> ```bash
> git clone https://ghproxy.net/https://github.com/sakz/lnmp2.3.git
> cd lnmp2.3
> ```

### 方式 2：直接下载压缩包

```bash
yum -y install wget || apt-get -y install wget

wget https://github.com/sakz/lnmp2.3/archive/refs/heads/main.tar.gz -O lnmp2.3.tar.gz
tar zxf lnmp2.3.tar.gz
cd lnmp2.3-main
```

> 国内 VPS 可用加速代理：
> ```bash
> wget https://ghproxy.net/https://github.com/sakz/lnmp2.3/archive/refs/heads/main.tar.gz -O lnmp2.3.tar.gz
> ```

## 二、安装部署

### 1. 建议使用 screen 防止 SSH 掉线中断安装

```bash
yum -y install screen || apt-get -y install screen
screen -S lnmp
# 掉线后可用 screen -r lnmp 恢复
```

### 2. 开始安装

```bash
chmod +x ./*.sh
./install.sh lnmp
```

安装模式可选：

| 模式 | 组成 | 命令 |
|---|---|---|
| LNMP | Nginx + MySQL/MariaDB + PHP | `./install.sh lnmp` |
| LNMPA | Nginx + Apache + MySQL/MariaDB + PHP | `./install.sh lnmpa` |
| LAMP | Apache + MySQL/MariaDB + PHP | `./install.sh lamp` |

### 3. 按提示选择版本

- 数据库：推荐直接回车选择默认（MySQL 8.4 LTS）；数据库安装方式**默认使用二进制包，回车即可**，大幅缩短安装时间
  - 也可选 MariaDB 10.4 ~ 11.8 LTS 等版本
  - 输入 `n` 可改回传统源码编译方式
- PHP 版本：可选 8.4 / 8.5 / 8.3 / 7.4 等（回车默认 8.4）
- 其余选项（内存分配、网站目录、是否安装内存优化等）按需回车或输入

提示：**MySQL 8.x / MariaDB 二进制包约 600MB~1GB，下载时间取决于 VPS 带宽，但相比编译可节省 30 分钟以上**。

### 4. 安装完成后

安装成功会显示访问地址和数据库 root 密码位置，检查状态：

```bash
lnmp status
```

访问 `http://服务器IP/` 应看到 LNMP 默认页面，探针 `http://服务器IP/p.php`。

## 三、常用功能

```bash
# 添加虚拟主机（域名、SSL证书、数据库一步完成）
lnmp vhost add

# 安装扩展插件（redis、memcached、opcache、imagemagick、swoole 等）
./addons.sh install redis
./addons.sh uninstall redis

# 安装 FTP 服务
./pureftpd.sh

# 升级各组件
./upgrade.sh {nginx|mysql|mariadb|php|mphp|m2m|phpmyadmin}
```

## 四、无人值守安装（可选）

```bash
DBSelect='4' PHPSelect='9' ./install.sh lnmp
```

常用环境变量（不设置则使用默认值，数据库默认二进制安装）：

| 变量 | 说明 | 示例 |
|---|---|---|
| `DBSelect` | 数据库版本编号 1~13（对应 MySQL 5.1~8.4、MariaDB 5.5~11.8） | `4`=MySQL 5.7，`11`=MySQL 8.4 |
| `Bin` | 数据库安装方式：`y`=二进制，`n`=源码编译，默认 `y` | `y` |
| `PHPSelect` | PHP 版本编号 1~16（对应 5.2~8.5） | `14`=PHP 8.4，`9`=PHP 7.4 |
| `Nginx_Select` | Nginx 版本 | `2`=1.30 |
| `Install_InnoDB` | 是否安装 InnoDB | `y` |

完整参数说明参考：https://lnmp.org/faq/v1-5-auto-install.html

## 五、常用管理命令

```bash
lnmp {start|stop|reload|restart|kill|status}    # LNMP 整体状态
lnmp nginx {start|stop|reload|restart}          # Nginx
lnmp mysql {start|stop|restart|status}          # MySQL
lnmp mariadb {start|stop|restart|status}        # MariaDB
lnmp php-fpm {start|stop|restart|reload}        # PHP-FPM

# 卸载
./uninstall.sh
```

## 六、目录与配置文件

| 内容 | 位置 |
|---|---|
| Nginx | `/usr/local/nginx/`（主配置 `/usr/local/nginx/conf/nginx.conf`） |
| MySQL / MariaDB | `/usr/local/mysql/` 或 `/usr/local/mariadb/`（配置 `/etc/my.cnf`） |
| PHP | `/usr/local/php/`（配置 `/usr/local/php/etc/php.ini`） |
| 默认网站目录 | `/home/wwwroot/default/` |
| Nginx 日志 | `/home/wwwlogs/` |
| phpMyAdmin | `http://服务器IP/phpmyadmin/` |

## 七、关于官方源下载说明

本改造版新增 `Get_Official_Url()` 下载映射，下载优先级：

1. **官方源**（每个包支持多个官方候选地址）
2. **lnmp.conf 中配置的镜像**（默认 `https://soft.lnmp.com`，仅作兜底）

如需自定义下载源或查看全部映射，见 `include/main.sh` 中的 `Get_Official_Url` 函数；镜像地址可在 `lnmp.conf` 中修改 `Download_Mirror`。

---

> 原版 LNMP 由 licess 开发，官网 https://lnmp.org ，原版 README 见本仓库 [README](README) 文件。
> 本改造版仅修改下载源逻辑与安装默认值，不改变 LNMP 原有的目录结构、管理命令与配置方式。
