#!/usr/bin/env bash

Nginx_Read_Pid()
{
    [ -s "$1" ] || return 0
    tr -d '[:space:]' < "$1"
}

Nginx_Worker_Count()
{
    local master_pid=$1
    local count="0"

    if command -v pgrep >/dev/null 2>&1; then
        count=$(pgrep -P "${master_pid}" -f "worker process" 2>/dev/null | wc -l)
    else
        count=$(ps -e -o pid= -o ppid= -o args= 2>/dev/null | awk -v ppid="${master_pid}" '$2 == ppid && /worker process/ {n++} END {print n+0}')
    fi
    count=$(printf '%s' "${count}" | tr -d '[:space:]')
    [ -n "${count}" ] || count=0
    echo "${count}"
}

Nginx_Master_Is_Healthy()
{
    local master_pid=$1
    local nginx_bin=$2
    local exe_link=""
    local exe_path=""

    [[ "${master_pid}" =~ ^[0-9]+$ ]] || return 1
    kill -0 "${master_pid}" 2>/dev/null || return 1
    [ -r "/proc/${master_pid}/exe" ] || return 1

    exe_link=$(readlink "/proc/${master_pid}/exe" 2>/dev/null)
    exe_path="${exe_link% (deleted)}"
    [ "${exe_path}" = "${nginx_bin}" ] || return 1
    [ "$(Nginx_Worker_Count "${master_pid}")" -gt 0 ] || return 1

    return 0
}

Nginx_Get_Unit_Value()
{
    local key=$1
    local unit_file="/etc/systemd/system/nginx.service"

    awk -v key="${key}" '
        $0 ~ "^[[:space:]]*" key "=" {
            value = substr($0, index($0, "=") + 1)
            sub(/[[:space:]]+$/, "", value)
            if (value != "") {
                print value
                exit
            }
        }
    ' "${unit_file}"
}

Nginx_Systemd_Unit_Is_Lnmp()
{
    local nginx_bin=$1
    local nginx_pid_file=$2
    local unit_file="/etc/systemd/system/nginx.service"
    local unit_exec=""
    local unit_pid=""

    [ -s "${unit_file}" ] || return 2

    unit_exec=$(Nginx_Get_Unit_Value "ExecStart")
    unit_pid=$(Nginx_Get_Unit_Value "PIDFile")

    [ -n "${unit_exec}" ] || return 1
    [ "${unit_exec%% *}" = "${nginx_bin}" ] || return 1
    [ "${unit_pid}" = "${nginx_pid_file}" ] || return 1

    return 0
}

Nginx_Atomic_Restore_Binary()
{
    local backup=$1
    local target=$2
    local tmp_file="${target}.rollback.$$"

    [ -s "${backup}" ] || return 1
    install -m 755 "${backup}" "${tmp_file}" || { rm -f "${tmp_file}"; return 1; }
    mv -f "${tmp_file}" "${target}" || { rm -f "${tmp_file}"; return 1; }

    return 0
}

Nginx_Restore_Config()
{
    local conf_backup=$1
    local nginx_conf=$2
    local conf_changed=$3
    local tmp_file="${nginx_conf}.rollback.$$"

    [ "${conf_changed}" = "y" ] || return 0
    [ -s "${conf_backup}" ] || return 1
    cp -p "${conf_backup}" "${tmp_file}" || { rm -f "${tmp_file}"; return 1; }
    mv -f "${tmp_file}" "${nginx_conf}" || { rm -f "${tmp_file}"; return 1; }

    return 0
}

Nginx_Restore_Config_Or_Exit()
{
    if ! Nginx_Restore_Config "$1" "$2" "$3"; then
        Echo_Red "Error: failed to restore $2 from $1."
        exit 1
    fi
}

Nginx_Start_Instance()
{
    local nginx_bin=$1
    local nginx_conf=$2
    local nginx_pid_file=$3
    local unit_status=0

    Nginx_Systemd_Unit_Is_Lnmp "${nginx_bin}" "${nginx_pid_file}"
    unit_status=$?
    if [ "${unit_status}" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
        if systemctl start nginx; then
            return 0
        fi
    fi

    "${nginx_bin}" -c "${nginx_conf}"
}

Nginx_Wait_For_New_Master()
{
    local old_pid=$1
    local nginx_bin=$2
    local nginx_pid_file=$3
    local timeout=$4
    local waited=0
    local new_pid=""

    while [ "${waited}" -lt "${timeout}" ]; do
        new_pid=$(Nginx_Read_Pid "${nginx_pid_file}")
        if [ -n "${new_pid}" ] && [ "${new_pid}" != "${old_pid}" ] && Nginx_Master_Is_Healthy "${new_pid}" "${nginx_bin}"; then
            echo "${new_pid}"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

Nginx_Rollback()
{
    local old_pid=$1
    local new_pid=$2
    local nginx_bin=$3
    local nginx_conf=$4
    local nginx_pid_file=$5
    local nginx_oldbin_file=$6
    local nginx_backup=$7
    local conf_backup=$8
    local conf_changed=$9
    local old_quit_sent=${10}
    local i=0
    local pid_from_file=""

    Echo_Red "Error: nginx upgrade did not complete, rolling back..."

    if [ -n "${new_pid}" ] && [ "${new_pid}" != "${old_pid}" ] && kill -0 "${new_pid}" 2>/dev/null; then
        Echo_Red "Stopping new nginx master ${new_pid}..."
        kill -QUIT "${new_pid}" 2>/dev/null
        for ((i = 0; i < 5; i++)); do
            kill -0 "${new_pid}" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "${new_pid}" 2>/dev/null; then
            kill -TERM "${new_pid}" 2>/dev/null
            sleep 1
        fi
    fi
    rm -f "${nginx_bin}.new"

    if ! Nginx_Atomic_Restore_Binary "${nginx_backup}" "${nginx_bin}"; then
        Echo_Red "Error: failed to restore ${nginx_bin} from ${nginx_backup}."
        Echo_Red "Manual recovery is required."
        exit 1
    fi
    if ! Nginx_Restore_Config "${conf_backup}" "${nginx_conf}" "${conf_changed}"; then
        Echo_Red "Error: failed to restore ${nginx_conf} from ${conf_backup}."
        exit 1
    fi

    if [ -n "${new_pid}" ] && [ "${new_pid}" != "${old_pid}" ] && kill -0 "${new_pid}" 2>/dev/null; then
        Echo_Red "Error: new nginx master ${new_pid} is still running after rollback."
        Echo_Red "The old binary was restored on disk; manual intervention is required."
        return 1
    fi

    if kill -0 "${old_pid}" 2>/dev/null; then
        if [ "${old_quit_sent}" = "y" ]; then
            Echo_Red "Old nginx master ${old_pid} already received QUIT and cannot be revived."
            Echo_Red "Waiting for it to finish draining before starting the restored binary..."
            for ((i = 0; i < 30; i++)); do
                kill -0 "${old_pid}" 2>/dev/null || break
                sleep 1
            done
            if kill -0 "${old_pid}" 2>/dev/null; then
                Echo_Red "Old nginx master is still draining; sending TERM to release the listening sockets..."
                kill -TERM "${old_pid}" 2>/dev/null
                for ((i = 0; i < 5; i++)); do
                    kill -0 "${old_pid}" 2>/dev/null || break
                    sleep 1
                done
            fi
            if kill -0 "${old_pid}" 2>/dev/null; then
                Echo_Red "Error: old nginx master ${old_pid} did not exit, manual recovery is required."
                return 1
            fi
        else
            if [ "$(Nginx_Worker_Count "${old_pid}")" -eq 0 ]; then
                Echo_Red "Old nginx master has no workers, sending HUP to restart them..."
                kill -HUP "${old_pid}" 2>/dev/null
            fi

            for ((i = 0; i < 5; i++)); do
                pid_from_file=$(Nginx_Read_Pid "${nginx_pid_file}")
                [ "${pid_from_file}" = "${old_pid}" ] && break
                sleep 1
            done
            if [ "${pid_from_file}" != "${old_pid}" ]; then
                echo "${old_pid}" > "${nginx_pid_file}"
            fi

            for ((i = 0; i < 5; i++)); do
                if Nginx_Master_Is_Healthy "${old_pid}" "${nginx_bin}"; then
                    rm -f "${nginx_oldbin_file}"
                    Echo_Green "Rollback completed. Old nginx master ${old_pid} is serving."
                    return 0
                fi
                sleep 1
            done

            if kill -0 "${old_pid}" 2>/dev/null; then
                Echo_Red "Error: old nginx master ${old_pid} is alive but not healthy."
                Echo_Red "Check ${nginx_pid_file} and the nginx error log manually."
                return 1
            fi
            Echo_Red "Old nginx master exited while rolling back."
        fi
    fi

    Echo_Red "Old nginx master is gone, starting the restored nginx binary..."
    Echo_Red "Warning: nginx was down between the failed cutover and this rollback start."
    rm -f "${nginx_oldbin_file}"
    Nginx_Start_Instance "${nginx_bin}" "${nginx_conf}" "${nginx_pid_file}"

    for ((i = 0; i < 5; i++)); do
        pid_from_file=$(Nginx_Read_Pid "${nginx_pid_file}")
        if Nginx_Master_Is_Healthy "${pid_from_file}" "${nginx_bin}"; then
            Echo_Green "Rollback completed. Old nginx binary is serving again."
            return 0
        fi
        sleep 1
    done

    Echo_Red "First start attempt did not become healthy, trying ${nginx_bin} directly..."
    "${nginx_bin}" -c "${nginx_conf}"
    sleep 1

    for ((i = 0; i < 5; i++)); do
        pid_from_file=$(Nginx_Read_Pid "${nginx_pid_file}")
        if Nginx_Master_Is_Healthy "${pid_from_file}" "${nginx_bin}"; then
            Echo_Green "Rollback completed. Old nginx binary is serving again."
            return 0
        fi
        sleep 1
    done

    Echo_Red "Error: restored nginx did not become healthy. Manual recovery is required."
    return 1
}

Upgrade_Nginx()
{
    local nginx_dir="/usr/local/nginx"
    local nginx_bin="${nginx_dir}/sbin/nginx"
    local nginx_conf="${nginx_dir}/conf/nginx.conf"
    local nginx_pid_file="${nginx_dir}/logs/nginx.pid"
    local nginx_oldbin_file="${nginx_dir}/logs/nginx.pid.oldbin"
    local nginx_backup="${nginx_bin}.${Upgrade_Date}"
    local nginx_new_bin="${nginx_bin}.new"
    local conf_backup="${nginx_conf}.bak.${Upgrade_Date}"
    local conf_changed="n"
    local old_pid=""
    local oldbin_pid=""
    local old_exe_link=""
    local old_exe=""
    local old_exe_unlinked="n"
    local new_pid=""
    local Cur_Nginx_Version=""
    local New_Nginx_Version=""
    local Nginx_Version=""
    local Nginx_Ver_Com=""
    local old_configure_args=""
    local new_configure_args=""
    local old_add_modules=""
    local new_add_modules=""
    local missing_modules=""
    local backup_src=""
    local unit_status=0
    local cpu_num=1
    local mem_mb=1024
    local build_jobs=1
    local continue_upgrade=""
    local old_quit_sent="n"
    local i=0

    echo "============================check running nginx=========================="
    if [ ! -x "${nginx_bin}" ] || [ ! -s "${nginx_conf}" ] || [ ! -s "${nginx_pid_file}" ]; then
        Echo_Red "Error: LNMP nginx was not found under ${nginx_dir}, aborting."
        exit 1
    fi

    old_pid=$(Nginx_Read_Pid "${nginx_pid_file}")
    if ! [[ "${old_pid}" =~ ^[0-9]+$ ]] || ! kill -0 "${old_pid}" 2>/dev/null; then
        Echo_Red "Error: nginx master from ${nginx_pid_file} is not running, aborting."
        exit 1
    fi

    old_exe_link=$(readlink "/proc/${old_pid}/exe" 2>/dev/null)
    old_exe="${old_exe_link% (deleted)}"
    if [ "${old_exe}" != "${nginx_bin}" ]; then
        Echo_Red "Error: PID ${old_pid} is running ${old_exe:-an unknown binary}, not ${nginx_bin}."
        Echo_Red "This script only upgrades the LNMP nginx instance and will not touch a system nginx."
        exit 1
    fi
    if ! tr '\0' ' ' < "/proc/${old_pid}/cmdline" 2>/dev/null | grep -q "nginx: master process"; then
        Echo_Red "Error: PID ${old_pid} does not look like an nginx master process, aborting."
        exit 1
    fi
    if [ "$(Nginx_Worker_Count "${old_pid}")" -eq 0 ]; then
        Echo_Red "Error: nginx master ${old_pid} has no worker processes, aborting."
        exit 1
    fi
    if [ -s "${nginx_oldbin_file}" ]; then
        Echo_Red "Error: ${nginx_oldbin_file} exists, a previous binary upgrade is unfinished."
        Echo_Red "Check nginx.pid and nginx.pid.oldbin before retrying."
        exit 1
    fi

    Nginx_Systemd_Unit_Is_Lnmp "${nginx_bin}" "${nginx_pid_file}"
    unit_status=$?
    if [ "${unit_status}" -eq 1 ]; then
        Echo_Red "Error: /etc/systemd/system/nginx.service does not point to the LNMP nginx instance."
        echo "ExecStart=$(Nginx_Get_Unit_Value "ExecStart")"
        echo "PIDFile=$(Nginx_Get_Unit_Value "PIDFile")"
        Echo_Red "Refusing to continue; system nginx and certbot are not touched."
        exit 1
    fi

    if [ "${old_exe_link}" != "${old_exe}" ]; then
        old_exe_unlinked="y"
        Echo_Yellow "Warning: the running nginx master uses an unlinked binary."
        Echo_Yellow "The on-disk binary version is shown below; downgrade check will be skipped."
    fi

    Cur_Nginx_Version=$("${nginx_bin}" -v 2>&1 | sed -n 's#^nginx version: nginx/##p' | awk '{print $1}')
    Cur_Nginx_Version=$(printf '%s' "${Cur_Nginx_Version}" | tr -d '\r')
    if [ -z "${Cur_Nginx_Version}" ]; then
        Echo_Red "Error: unable to read the current nginx version, aborting."
        exit 1
    fi

    if [ -s /usr/local/include/jemalloc/jemalloc.h ] && "${nginx_bin}" -V 2>&1 | grep -Eqi 'ljemalloc'; then
        NginxMAOpt="--with-ld-opt='-ljemalloc'"
    elif [ -s /usr/local/include/gperftools/tcmalloc.h ] && grep -Eqi "google_perftools_profiles" "${nginx_conf}"; then
        NginxMAOpt='--with-google_perftools_module'
    else
        NginxMAOpt=""
    fi

    echo "Current Nginx Version:${Cur_Nginx_Version}"
    echo "You can get version number from http://nginx.org/en/download.html"
    read -r -p "Please enter nginx version you want, (example: 1.30.0): " Nginx_Version
    if ! [[ "${Nginx_Version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        Echo_Red "Error: invalid nginx version '${Nginx_Version}'. Expected format: 1.30.0"
        exit 1
    fi
    if [ "${Nginx_Version}" = "${Cur_Nginx_Version}" ]; then
        Echo_Red "Error: target version ${Nginx_Version} is the same as the current version."
        exit 1
    fi
    if [ "${old_exe_unlinked}" != "y" ]; then
        Nginx_Ver_Com=$("${cur_dir}/include/version_compare" "${Cur_Nginx_Version}" "${Nginx_Version}")
        if [ "${Nginx_Ver_Com}" = "1" ]; then
            Echo_Red "Error: downgrade from ${Cur_Nginx_Version} to ${Nginx_Version} is not allowed."
            exit 1
        fi
    fi

    echo "+---------------------------------------------------------+"
    echo "|    You will upgrade nginx version to ${Nginx_Version}"
    echo "+---------------------------------------------------------+"

    Press_Start

    echo "============================check files=================================="
    cd "${cur_dir}/src" || { Echo_Red "Error: ${cur_dir}/src not found."; exit 1; }
    if ! Download_Files "${Download_Mirror}/web/nginx/nginx-${Nginx_Version}.tar.gz" "nginx-${Nginx_Version}.tar.gz"; then
        Echo_Red "Error: unable to download nginx-${Nginx_Version}.tar.gz."
        exit 1
    fi
    echo "============================check files=================================="

    Install_Nginx_Openssl
    Install_Nginx_Lua
    Install_Pcre
    Install_Ngx_FancyIndex

    if ! Tar_Cd "nginx-${Nginx_Version}.tar.gz" "nginx-${Nginx_Version}" || [ ! -x ./configure ] || [ ! -s ./src/core/nginx.c ]; then
        Echo_Red "Error: failed to extract nginx-${Nginx_Version}.tar.gz or enter its source directory."
        exit 1
    fi

    Get_Dist_Version
    if [[ "${DISTRO}" = "Fedora" && ${Fedora_Version} -ge 28 ]]; then
        if ! patch -p1 < "${cur_dir}/src/patch/nginx-libxcrypt.patch"; then
            Echo_Red "Error: failed to apply nginx-libxcrypt.patch."
            exit 1
        fi
    fi
    Nginx_Ver_Com=$("${cur_dir}/include/version_compare" 1.14.2 "${Nginx_Version}")
    if gcc -dumpversion | grep -q "^[8]" && [ "${Nginx_Ver_Com}" == "1" ]; then
        if ! patch -p1 < "${cur_dir}/src/patch/nginx-gcc8.patch"; then
            Echo_Red "Error: failed to apply nginx-gcc8.patch."
            exit 1
        fi
    fi

    Nginx_Ver_Com=$("${cur_dir}/include/version_compare" 1.9.4 "${Nginx_Version}")
    if [[ "${Nginx_Ver_Com}" == "0" || "${Nginx_Ver_Com}" == "1" ]]; then
        if ! ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_spdy_module --with-http_gzip_static_module --with-ipv6 --with-http_sub_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_FancyIndex} ${Nginx_Modules_Options}; then
            Echo_Red "Error: nginx configure failed, the running nginx was not changed."
            exit 1
        fi
    else
        if ! ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_gzip_static_module --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_FancyIndex} ${Nginx_Modules_Options}; then
            Echo_Red "Error: nginx configure failed, the running nginx was not changed."
            exit 1
        fi
    fi

    cpu_num=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    if ! [[ "${cpu_num}" =~ ^[0-9]+$ ]] || [ "${cpu_num}" -lt 1 ]; then
        cpu_num=1
    fi
    mem_mb=$(awk '/^MemTotal:/{printf "%d", $2 / 1024; exit}' /proc/meminfo 2>/dev/null)
    if ! [[ "${mem_mb}" =~ ^[0-9]+$ ]] || [ "${mem_mb}" -lt 1 ]; then
        mem_mb=1024
    fi
    build_jobs=$((mem_mb / 1024))
    if [ "${build_jobs}" -lt 1 ]; then
        build_jobs=1
    fi
    if [ "${build_jobs}" -gt "${cpu_num}" ]; then
        build_jobs=${cpu_num}
    fi

    echo "Building nginx with -j${build_jobs} (CPU: ${cpu_num}, Mem: ${mem_mb}MB)..."
    if ! make -j"${build_jobs}"; then
        Echo_Red "Parallel build failed, retrying with a serial build..."
        if ! make; then
            Echo_Red "Error: nginx build failed, the running nginx was not changed."
            exit 1
        fi
    fi
    if [ ! -x ./objs/nginx ]; then
        Echo_Red "Error: objs/nginx was not built, the running nginx was not changed."
        exit 1
    fi

    old_configure_args=$("${nginx_bin}" -V 2>&1 | sed -n 's/^configure arguments: //p')
    new_configure_args=$(./objs/nginx -V 2>&1 | sed -n 's/^configure arguments: //p')
    echo "Old configure arguments: ${old_configure_args}"
    echo "New configure arguments: ${new_configure_args}"

    if [ -n "${old_configure_args}" ]; then
        old_add_modules=$(printf '%s\n' "${old_configure_args}" | grep -o -- '--add-module=[^ ]*' | sed 's#.*/##' | LC_ALL=C sort -u)
        new_add_modules=$(printf '%s\n' "${new_configure_args}" | grep -o -- '--add-module=[^ ]*' | sed 's#.*/##' | LC_ALL=C sort -u)
        if [ -n "${old_add_modules}" ]; then
            missing_modules=$(comm -23 <(printf '%s\n' "${old_add_modules}") <(printf '%s\n' "${new_add_modules}") | sed '/^$/d')
            if [ -n "${missing_modules}" ]; then
                Echo_Yellow "Warning: the running nginx contains modules missing from the new build:"
                printf '%s\n' "${missing_modules}"
                Echo_Yellow "Add them to Nginx_Modules_Options in lnmp.conf if they are still required."
                read -r -p "Continue anyway? [y/N]: " continue_upgrade
                case "${continue_upgrade}" in
                    y|Y|yes|YES) ;;
                    *) Echo_Red "Upgrade cancelled, the running nginx was not changed."; exit 1 ;;
                esac
            fi
        fi
    fi

    if [ "${Enable_Nginx_Lua}" = 'y' ]; then
        if ! cp -p "${nginx_conf}" "${conf_backup}"; then
            Echo_Red "Error: failed to back up ${nginx_conf}."
            exit 1
        fi
        if ! grep -q 'lua_package_path "/usr/local/nginx/lib/lua/?.lua";' "${nginx_conf}"; then
            if ! sed -i "/server_tokens off;/i\        lua_package_path \"/usr/local/nginx/lib/lua/?.lua\";\n" "${nginx_conf}"; then
                Nginx_Restore_Config_Or_Exit "${conf_backup}" "${nginx_conf}" "y"
                Echo_Red "Error: failed to update ${nginx_conf} for Lua."
                exit 1
            fi
            conf_changed="y"
        fi
        if ! grep -q "content_by_lua 'ngx.say(\"hello world\")';" "${nginx_conf}"; then
            if ! sed -i "/location \/nginx_status/i\        location /lua\n        {\n            default_type text/html;\n            content_by_lua 'ngx.say\(\"hello world\"\)';\n        }\n" "${nginx_conf}"; then
                Nginx_Restore_Config_Or_Exit "${conf_backup}" "${nginx_conf}" "y"
                Echo_Red "Error: failed to update ${nginx_conf} for Lua."
                exit 1
            fi
            conf_changed="y"
        fi
    fi

    echo "Test nginx configure file..."
    rm -f "${nginx_new_bin}"
    if ! install -m 755 ./objs/nginx "${nginx_new_bin}"; then
        rm -f "${nginx_new_bin}"
        Nginx_Restore_Config_Or_Exit "${conf_backup}" "${nginx_conf}" "${conf_changed}"
        Echo_Red "Error: failed to stage the new nginx binary, the running nginx was not changed."
        exit 1
    fi
    if ! "${nginx_new_bin}" -t -c "${nginx_conf}"; then
        rm -f "${nginx_new_bin}"
        Nginx_Restore_Config_Or_Exit "${conf_backup}" "${nginx_conf}" "${conf_changed}"
        Echo_Red "Error: nginx -t failed with the new binary, the running nginx was not changed."
        exit 1
    fi

    backup_src="${nginx_bin}"
    if [ "${old_exe_unlinked}" = "y" ]; then
        backup_src="/proc/${old_pid}/exe"
    fi
    if ! install -m 755 "${backup_src}" "${nginx_backup}"; then
        rm -f "${nginx_new_bin}"
        Nginx_Restore_Config_Or_Exit "${conf_backup}" "${nginx_conf}" "${conf_changed}"
        Echo_Red "Error: failed to back up the running nginx binary to ${nginx_backup}."
        exit 1
    fi
    if ! mv -f "${nginx_new_bin}" "${nginx_bin}"; then
        rm -f "${nginx_new_bin}"
        Nginx_Restore_Config_Or_Exit "${conf_backup}" "${nginx_conf}" "${conf_changed}"
        Echo_Red "Error: failed to install the new nginx binary, the old binary is unchanged."
        exit 1
    fi

    echo "Starting nginx graceful binary upgrade..."
    if ! kill -USR2 "${old_pid}" 2>/dev/null; then
        Echo_Red "Error: failed to send USR2 to nginx master ${old_pid}."
        Nginx_Rollback "${old_pid}" "" "${nginx_bin}" "${nginx_conf}" "${nginx_pid_file}" "${nginx_oldbin_file}" "${nginx_backup}" "${conf_backup}" "${conf_changed}" "n"
        exit 1
    fi

    new_pid=""
    if ! new_pid=$(Nginx_Wait_For_New_Master "${old_pid}" "${nginx_bin}" "${nginx_pid_file}" 10); then
        new_pid=$(Nginx_Read_Pid "${nginx_pid_file}")
        if [ "${new_pid}" = "${old_pid}" ]; then
            new_pid=""
        fi
        Echo_Red "Error: the new nginx master did not become healthy within 10 seconds."
        Nginx_Rollback "${old_pid}" "${new_pid}" "${nginx_bin}" "${nginx_conf}" "${nginx_pid_file}" "${nginx_oldbin_file}" "${nginx_backup}" "${conf_backup}" "${conf_changed}" "n"
        exit 1
    fi

    sleep 2
    if [ "$(Nginx_Read_Pid "${nginx_pid_file}")" != "${new_pid}" ] || ! Nginx_Master_Is_Healthy "${new_pid}" "${nginx_bin}"; then
        Echo_Red "Error: the new nginx master exited shortly after starting."
        Nginx_Rollback "${old_pid}" "${new_pid}" "${nginx_bin}" "${nginx_conf}" "${nginx_pid_file}" "${nginx_oldbin_file}" "${nginx_backup}" "${conf_backup}" "${conf_changed}" "n"
        exit 1
    fi

    if [ ! -s "${nginx_oldbin_file}" ]; then
        Echo_Yellow "Warning: ${nginx_oldbin_file} was not found; using the captured old PID ${old_pid}."
    else
        oldbin_pid=$(Nginx_Read_Pid "${nginx_oldbin_file}")
        if [ "${oldbin_pid}" != "${old_pid}" ]; then
            Echo_Red "Error: ${nginx_oldbin_file} contains '${oldbin_pid}', expected ${old_pid}."
            Nginx_Rollback "${old_pid}" "${new_pid}" "${nginx_bin}" "${nginx_conf}" "${nginx_pid_file}" "${nginx_oldbin_file}" "${nginx_backup}" "${conf_backup}" "${conf_changed}" "n"
            exit 1
        fi
    fi

    if kill -0 "${old_pid}" 2>/dev/null; then
        echo "Stopping old nginx master ${old_pid} gracefully..."
        if ! kill -QUIT "${old_pid}" 2>/dev/null; then
            Echo_Red "Error: failed to send QUIT to old nginx master ${old_pid}."
            Nginx_Rollback "${old_pid}" "${new_pid}" "${nginx_bin}" "${nginx_conf}" "${nginx_pid_file}" "${nginx_oldbin_file}" "${nginx_backup}" "${conf_backup}" "${conf_changed}" "n"
            exit 1
        fi
        old_quit_sent="y"
        for ((i = 0; i < 30; i++)); do
            kill -0 "${old_pid}" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "${old_pid}" 2>/dev/null; then
            Echo_Yellow "Warning: old nginx master ${old_pid} is still draining long-lived connections."
            Echo_Yellow "The new master ${new_pid} is serving; ${nginx_oldbin_file} remains until it exits."
        fi
    else
        Echo_Yellow "Warning: old nginx master ${old_pid} exited before QUIT was sent."
    fi

    if ! kill -0 "${old_pid}" 2>/dev/null && [ -s "${nginx_oldbin_file}" ]; then
        rm -f "${nginx_oldbin_file}"
    fi

    new_pid=$(Nginx_Read_Pid "${nginx_pid_file}")
    New_Nginx_Version=$("${nginx_bin}" -v 2>&1 | sed -n 's#^nginx version: nginx/##p' | awk '{print $1}')
    New_Nginx_Version=$(printf '%s' "${New_Nginx_Version}" | tr -d '\r')
    if [ "${new_pid}" = "${old_pid}" ] || ! Nginx_Master_Is_Healthy "${new_pid}" "${nginx_bin}" || [ "${New_Nginx_Version}" != "${Nginx_Version}" ]; then
        Echo_Red "Error: nginx is not running the expected version after the upgrade."
        Nginx_Rollback "${old_pid}" "${new_pid}" "${nginx_bin}" "${nginx_conf}" "${nginx_pid_file}" "${nginx_oldbin_file}" "${nginx_backup}" "${conf_backup}" "${conf_changed}" "${old_quit_sent}"
        exit 1
    fi

    echo "Program will display Nginx Version......"
    "${nginx_bin}" -v
    Echo_Green "======== upgrade nginx completed ======"
    echo "Old binary backup: ${nginx_backup}"

    cd "${cur_dir}" || true
    rm -rf "${cur_dir}/src/nginx-${Nginx_Version}"
}
