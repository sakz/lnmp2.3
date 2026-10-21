# 计划：为 LNMP 脚本新增 PHP 单独安装模式（`./install.sh php`）

## 背景确认（回答用户问题）

**是的，原版脚本对 Debian 13 支持不完善**，上一轮已修复 4 处（freetype 下载候选、镜像证书过期、libmcrypt/GCC14、Debian 13 的 libaio.so.1t64/ncurses5 软链）。这些修复已在本地代码中，但**尚未推送到 GitHub，VPS 上还没有**。

当前 VPS 状态（基于 lnmp-install.log 分析）：

| 组件 | 状态 | 说明 |
|---|---|---|
| Nginx 1.30.0 | ✅ 已安装 | 无需重装 |
| MySQL 5.7.44（二进制） | ⚠️ 已安装但**启动失败过** | 日志 4922 行：缺 `libaio.so.1`（Debian 13 改名为 `libaio.so.1t64`）、4939 行：缺 `libncurses.so.5`。若用户未手动修复，MySQL 仍未运行 |
| PHP 8.4.20 | ❌ 编译失败 | 根因：freetype 下载失败（savannah 502 + 镜像证书过期） |
| `/bin/lnmp` | ✅ 已存在 | 上次失败安装残留，导致 `./install.sh lnmp` 会被 "You have installed LNMP!" 拦截 |

**因此需要新增"只装 PHP"模式**——现有 `install.sh` 只支持 `lnmp|lnmpa|lamp|nginx|db|mphp`，没有 php 单独安装入口。

## 现状分析（Phase 1 探索结论）

- [install.sh](file:///Users/saber/myProject/lnmp2.3/install.sh)：`case "${Stack}"` 分发模式；`nginx`/`db` 模式调用 only.sh 中的 `Install_Only_Nginx` / `Install_Only_Database`；lnmp 全量流程 = `Init_Install`（依赖+库+数据库）→ `Install_PHP` → `LNMP_PHP_Opt` → `Install_Nginx` → `Creat_PHP_Tools` → 启动/检查
- [include/only.sh](file:///Users/saber/myProject/lnmp2.3/include/only.sh)：单独安装模式的样板（banner → Press_Install → 依赖 → 下载 → 安装 → StartUp → 检查）
- [include/php.sh](file:///Users/saber/myProject/lnmp2.3/include/php.sh)：`Check_PHP_Option()`(L177 安装选项交互)、`LNMP_PHP_Opt()`(L1363 调整 php-fpm 进程数)、`Creat_PHP_Tools()`(L1388 生成 phpinfo/探针/phpMyAdmin 到 `/home/wwwroot/default`)
- [include/main.sh](file:///Users/saber/myProject/lnmp2.3/include/main.sh)：`PHP_Selection()`(L421 版本选择交互，默认 14=PHP 8.4)、`StartUp()`(L1115)、`StartOrStop()`(L1355)、`Check_Download`/`Install_Libiconv`/`Install_Freetype`/`Install_Pcre`/`Install_Icu4c`/`Deb_Lib_Opt` 等可直接复用
- [include/end.sh](file:///Users/saber/myProject/lnmp2.3/include/end.sh)：`Check_LNMP_Install()`(L270) 纯打印检查结果，可安全复用
- `Init_Install` 中的系统初始化步骤（Add_Swap、Set_Timezone、NTP、Modify_Source）上次安装已执行过，单独装 PHP 时应跳过，避免重复修改

## 改动内容

### 1. include/only.sh — 新增 `PHP_Dependent()` 和 `Install_Only_PHP()`

**`PHP_Dependent()`**：PHP 编译所需的最小依赖集（参照 `DB_Dependent` 的写法，apt 分支）：

```bash
PHP_Dependent()
{
    if [ "$PM" = "yum" ]; then
        for packages in make gcc gcc-c++ wget curl autoconf automake re2c openssl openssl-devel zlib zlib-devel bzip2 bzip2-devel libcurl-devel libjpeg-devel libpng-devel libXpm-devel libxml2-devel libicu-devel oniguruma-devel sqlite-devel pkg-config libzip-devel xz gzip ca-certificates;
        do yum -y install $packages; done
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make autoconf automake re2c wget curl openssl libssl-dev zlib1g zlib1g-dev libbz2-dev libcurl4-openssl-dev libjpeg-dev libpng-dev libxml2-dev libicu-dev libonig-dev libsqlite3-dev libsasl2-dev pkg-config libzip-dev bzip2 xz-utils gzip ca-certificates;
        do apt-get --no-install-recommends install -y $packages; done
    fi
}
```

**`Install_Only_PHP()`**（流程对齐 `Init_Install` 去掉数据库/系统初始化）：

```bash
Install_Only_PHP()
{
    clear + banner（仿 Install_Only_Nginx 的框，注明 "A tool to only install PHP."）
    Get_Dist_Name
    PHP_Selection          # 交互选版本（支持环境变量 PHPSelect 无人值守，默认 14=PHP 8.4）
    Check_PHP_Option       # fileinfo/opcache 等选项交互
    Press_Install
    cd ${cur_dir}/src
    Get_Dist_Version
    PHP_Dependent
    Disable_Selinux
    Check_Download         # 下载所有库源码（已存在文件自动跳过）
    Install_Libiconv
    Install_Libmcrypt
    Install_Mhash
    Install_Mcrypt
    Install_Freetype       # 修复后的多候选下载：savannah → sourceforge
    Install_Pcre
    Install_Icu4c
    if [ "$PM" = "yum" ]; then
        CentOS_Lib_Opt
    elif [ "$PM" = "apt" ]; then
        Deb_Lib_Opt        # 附带修复：会在 Debian 13 上补建 libaio.so.1/libncurses.so.5 软链 → 顺带修好 MySQL 启动
    fi
    Install_PHP            # 编译安装所选 PHP
    LNMP_PHP_Opt           # 按内存调整 php-fpm 进程数
    StartUp php-fpm
    StartOrStop start php-fpm
    Clean_PHP_Src_Dir
    Creat_PHP_Tools        # phpinfo/p.php/ocp.php/phpMyAdmin → /home/wwwroot/default（nginx 已装，直接可用）
    Check_LNMP_Install     # 打印 nginx/mysql/php-fpm 检查结果
}
```

**刻意跳过**（避免重复/副作用）：`Press_Install` 之前的 `Dispaly_Selection`、`Add_Swap`、`Set_Timezone`、`InstallNTP`、`Deb_RemoveAMP`（上次已执行过，且 RemoveAMP 无害但没必要）、`Modify_Source`、`Add_Iptables_Rules`（上次 nginx 安装时已加过规则）、`malloc` 编译选项（保持默认不装 jemalloc/tcmalloc）、`Creat_PHP_Tools` 中 `cp conf/lnmp /bin/lnmp`（only_nginx 模式才做，php 模式不需要）。

### 2. install.sh — 注册 php 模式

```bash
    php)
        Install_Only_PHP 2>&1 | tee /root/php-install.log
        ;;
```

- 放在 `mphp)` case 之后
- 更新 usage 提示：`Usage: $0 {nginx|db|php|mphp}`
- 无需改 38-44 行的已安装检查：它只拦截 `lnmp|lnmpa|lamp`，php 模式不受 `/bin/lnmp` 残留影响

## 假设与决策

1. **PHP 5.2/5.3（PHPSelect=1/2）不支持单独安装模式**：这两个版本链接的是 MySQL 客户端库且 `PHP_Selection` 里有 DBSelect=0 的保护，单独装 PHP 时未选数据库会直接退出。目标场景是 PHP 7.4/8.x（mysqlnd 自带），在文档/交互中默认 8.4 即可，不做额外兼容
2. `Deb_Lib_Opt` 在 php 模式中运行是**有意为之**：上轮修复的 libaio/ncurses 软链会随本次安装顺带创建，自动修复 VPS 上 MySQL 启动问题
3. 不改动 nginx/mysql 相关逻辑，不动已有数据库和站点数据

## VPS 上的操作步骤（写入最终回复给用户）

1. 本地推送修复后，VPS 上更新代码（git clone 新目录或下载新 zip，如 `/root/lnmp2.3`）
2. `cd /root/lnmp2.3 && chmod +x ./*.sh && screen -S lnmp && ./install.sh php`，回车默认 PHP 8.4
3. 安装完成后验证：`lnmp status`（mysql/nginx/php-fpm 均 running）、`http://服务器IP/p.php` 探针
4. 若 MySQL 仍未运行：php 模式安装完成后软链已补建，`lnmp mysql start` 即可；确认 root 密码在日志中

## 验证步骤

1. 本地 `bash -n install.sh include/only.sh` 语法校验
2. 本地模拟加载验证：`source` 各脚本后确认 `Install_Only_PHP`、`PHP_Dependent` 已定义、`Get_Official_Url` 对 freetype 输出双候选
3. VPS 实际执行 `./install.sh php`，检查 `/root/php-install.log`：freetype 环节必须成功（"Installing freetype-2.13.0" 后无 tar/configure 报错）、PHP make install 成功、php-fpm 启动、`Check_LNMP_Install` 三项 ok
4. 浏览器访问 `http://VPS_IP/p.php` 确认 PHP 生效；`lnmp mysql status` 确认数据库正常
