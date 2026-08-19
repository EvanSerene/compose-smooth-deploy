#!/bin/bash
# 微服务零停机平滑发布脚本
#
# 使用示例：
#   deploy.sh                         不传参数，等价于 deploy.sh 1 your-service1
#   deploy.sh 1 your-service1         构建+平滑发布
#   deploy.sh 0 your-service1         跳过构建直接发布
#   deploy.sh rollback your-service1  自动回滚上一版本
#   deploy.sh rollback your-service1 20260818160000  指定tag回滚
#
# 核心逻辑分支：
# ┌─ 入口模式 ──────────────────────────────────────────────────────────┐
# │ build_flag=1 → do_build_image(打唯一tag+latest) → do_smooth_deploy  │
# │ build_flag=0 → 复用本地已有latest → do_smooth_deploy                 │
# │ rollback     → 取历史最后一条tag(或指定tag) → 重打latest               │
# │              → do_smooth_deploy(复用平滑流程)                        │
# └────────────────────────────────────────────────────────────────────┘
#
# ┌─ do_smooth_deploy 平滑发布流程 ────────────────────────────────────┐
# │ 预检：采集副本数、上版本tag、旧容器ID列表                               │
# │                                                                  │
# │ ├─ old_replica==0（无运行容器）                                     │
# │ │   → 直接 docker compose up -d，不走平滑                           │
# │ │   → 成功写发布记录，失败直接提示（无需回滚）                           │
# │ │                                                                │
# │ └─ old_replica>=1（正常滚动）                                      │
# │     ① 生成override文件指定新tag（不修改原compose文件）               │
# │     ② 开启ERR trap                                               │
# │     ③ 滚动循环（共old_replica轮）：                                 │
# │        create --scale+1 --no-recreate（只创建新容器，旧容器不动）     │
# │        → start → 健康检测                                         │
# │        → 通过：stop+rm 一个旧容器（从预采集的旧ID列表按序取）           │
# │        → 失败：die触发ERR trap → 进入回滚流程                       │
# │     ④ 全部成功：恢复compose文件 → 写发布记录 → 完成                   │
# └─────────────────────────────────────────────────────────────────┘
#
# ┌─ 失败回滚流程（smooth_deploy_fail_recover）────────────────────────┐
# │ ① trap - ERR（防止连环触发）                                       │
# │ ② 清理所有新容器（无论running/Created，健康失败=发布未成功）            │
# │ ③ 恢复compose文件为latest                                         │
# │ ④ 统计剩余新/旧容器数量：                                           │
# │    → 新==0：旧容器全在，直接完成回退（无需替代）                        │
# │    → 新>旧：镜像没问题，保留新容器，列出旧容器ID提示人工清理              │
# │    → 新<=旧且新>0：用旧镜像create替代容器 → 健康检测                   │
# │      → 通过：删掉所有新容器 → 回退完成（零停机）                       │
# │      → 失败：打印诊断 → 提示人工介入                                 │
# │ ⑤ 无prev_tag或旧镜像丢失：恢复compose文件，警告，保留剩余容器           │
# └─────────────────────────────────────────────────────────────────┘

##############################################################################
# 【配置区，新增/修改服务全部在这里】
##############################################################################
# 固定配置：源码根目录
APP_DIR="/opt/srv/app"
# 固定配置：compose配置文件目录
COMPOSE_DIR="/opt/srv/docker-stack/compose"
# 固定配置：发布日志文件目录
RELEASE_HISTORY="${COMPOSE_DIR}/release_history.log"
# 可变配置：健康检测超时时间（秒）
HEALTH_TIMEOUT=120

# 业务配置1：服务列表及源码位置，此配置内的服务才可执行发布脚本指定服务（必须）
declare -A SERVICE_BUILD_DIR=(
    ["your-service1"]="$APP_DIR/your-service1"
    ["your-service2"]="$APP_DIR/your-service2"
    ["your-service3"]="$APP_DIR/your-service3"
)
# 业务配置2：Dockerfile文件名，此配置用于构建，需要执行构建的配置（可选）
declare -A SERVICE_DOCKERFILE=(
    ["your-service1"]="Dockerfile-your-service1"
    ["your-service2"]="Dockerfile-your-service2"
    ["your-service3"]="Dockerfile-your-service3"
)

# 业务配置3：需要健康检测的服务列表 格式：服务名:actuator健康端口（容器内端口，未配置则跳过探活）（可选）
HEALTH_CHECK_LIST=(
  "your-service1:9527"
  "your-service3:9526"
  "your-service2:9525"
)

# 业务配置4：需要平滑滚动发布的服务列表，此配置内的服务才会执行平滑发布（可选）
ROLLBACK_SERVICE_LIST=(
  "your-service1"
)

##############################################################################
# 【常量 & 全局变量区，业务不要改】
##############################################################################
START_TS=$(date +%s)
START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')

##############################################################################
# 【工具函数层】
##############################################################################

# die：打印错误直接退出（设标志位，防止ERR trap误触发回滚）
function die() {
    echo -e "\033[31mX $*\033[0m"
    _DIE_EXIT=1
    exit 1
}

# 判断服务是否开启平滑发布
function is_smooth_service() {
    local svc="$1"
    local item
    for item in "${ROLLBACK_SERVICE_LIST[@]}"; do
        local srv_name=${item%%:*}
        if [[ "${srv_name}" == "${svc}" ]]; then
            return 0
        fi
    done
    return 1
}

# 获取服务actuator端口（从健康检测列表读取）
function get_actuator_port() {
    local svc_name="$1"
    local item
    for item in "${HEALTH_CHECK_LIST[@]}"; do
        local srv=${item%%:*}
        local port=${item##*:}
        if [[ "${srv}" == "${svc_name}" ]]; then
            echo "${port}"
            return 0
        fi
    done
    echo ""
    return 1
}

# 获取compose中正在运行的副本数量
function get_running_replica_count() {
    local svc="$1"
    pushd "${COMPOSE_DIR}" >/dev/null || die "进入compose目录失败 ${COMPOSE_DIR}"
    local count
    count=$(docker compose ps --filter "status=running" "${svc}" --quiet | wc -l)
    popd >/dev/null
    echo "${count}"
}

# 打印容器诊断信息（状态 + 最近日志）
function dump_container_diag() {
    local container_id="$1"
    echo -e "\033[33m--- 容器诊断: ${container_id} ---\033[0m"
    echo -e "\033[33m[状态]\033[0m"
    docker ps -a --filter "id=${container_id}" --format "table {{.ID}}\t{{.Status}}\t{{.Image}}" 2>/dev/null
    echo -e "\033[33m[最近30行日志]\033[0m"
    docker logs --tail 30 "${container_id}" 2>&1
    echo -e "\033[33m--- 诊断结束 ---\033[0m"
}

# 容器健康检测
function wait_container_health() {
    local container_id="$1"
    local port="$2"

    if [[ -z "${port}" ]]; then
        die "未配置actuator健康端口"
        return 1
    fi

    local start_ts=$(date +%s)
    local min_wait=3
    echo "→ 等待容器 ${container_id} 健康就绪，最小等待${min_wait}s，最大总等待${HEALTH_TIMEOUT}s"
    sleep "${min_wait}"

    while true; do
        local now_ts=$(date +%s)
        local elapsed=$((now_ts - start_ts))
        if [[ ${elapsed} -ge ${HEALTH_TIMEOUT} ]]; then
            echo -e "\033[31m   健康检测超时${HEALTH_TIMEOUT}s，新版本未就绪\033[0m"
            return 1
        fi

        local container_ip
        container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_id}")
        local ret_code
        ret_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${container_ip}:${port}/actuator/health" || true)

        if [[ "${ret_code}" == "200" ]]; then
            echo "√ 新实例健康检测通过，耗时${elapsed}s"
            return 0
        fi
        sleep 2
    done
}

# 写入发布历史记录
function record_release_log() {
    local svc="$1"
    local tag="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ${svc} | ${tag}" >> "${RELEASE_HISTORY}"
}

# 校验服务是否在配置中定义
function validate_service_exists() {
    local svc="$1"
    if [[ -z "${SERVICE_BUILD_DIR[$svc]}" ]]; then
        die "未知服务 [${svc}]，支持服务列表：${!SERVICE_BUILD_DIR[*]}"
        return 1
    fi
    return 0
}

# 从发布历史获取服务上一个版本tag
function get_last_release_tag() {
    local svc="$1"
    if [[ ! -f "${RELEASE_HISTORY}" ]]; then
        echo ""
        return
    fi
    local last_tag
    last_tag=$(grep "| ${svc} |" "${RELEASE_HISTORY}" 2>/dev/null | tail -n 1 | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "${last_tag}"
}

# 获取当前服务上一个有效版本tag（跳过当前版本及其重复记录，用于手动回滚）
function get_prev_release_tag() {
    local svc="$1"
    if [[ ! -f "${RELEASE_HISTORY}" ]]; then
        echo ""
        return
    fi
    local cur_tag
    cur_tag=$(get_last_release_tag "${svc}")
    [[ -z "${cur_tag}" ]] && { echo ""; return; }
    grep "| ${svc} |" "${RELEASE_HISTORY}" 2>/dev/null \
        | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v "^${cur_tag}$" | tail -n 1
}

# 检查本地镜像是否存在
function check_image_exist() {
    local image_full="$1"
    if ! docker inspect --type image "${image_full}" >/dev/null 2>&1 ;then
        die "本地镜像不存在：${image_full}"
        return 1
    fi
    return 0
}

# 解析latest镜像对应的实际tag（按项目时间戳规范过滤，多个时取最新，返回纯tag不带服务名前缀）
function get_latest_real_tag() {
    local svc="$1"
    local full_tag
    full_tag=$(docker image inspect "${svc}:latest" --format '{{range .RepoTags}}{{println .}}{{end}}' 2>/dev/null \
        | grep "^${svc}:[0-9]\{14\}$" \
        | sort | tail -n 1)
    [[ -z "${full_tag}" ]] && return 1
    echo "${full_tag##*:}"
}

# 校验compose文件是否可被docker compose正常解析
function validate_compose_file() {
    local compose_file="${COMPOSE_DIR}/docker-compose.yml"
    local output
    if ! output=$(docker compose -f "${compose_file}" config 2>&1); then
        echo -e "\033[31mX compose文件解析失败，请检查 ${compose_file} 格式\033[0m"
        echo -e "\033[31m   错误信息: $(echo "${output}" | head -3)\033[0m"
        return 1
    fi
    return 0
}

##############################################################################
# 【业务逻辑层】
##############################################################################
# flock并发锁：按服务粒度加锁，防止同一服务并发发布/回滚
# 拿锁失败打印持有者信息并退出，锁随进程退出自动释放（fd关闭即释放，无需手动解锁）
function acquire_deploy_lock() {
    local svc="$1"
    LOCK_FILE="/tmp/deploy-${svc}.lock"
    # 追加模式打开锁文件（不截断，避免清掉持有者写入的占用信息）
    exec 9>>"${LOCK_FILE}"
    if ! flock -n 9; then
        local holder_info holder_pid
        holder_info=$(cat "${LOCK_FILE}" 2>/dev/null)
        echo -e "\033[31mX 服务 [${svc}] 已有发布任务在运行，本次执行终止\033[0m"
        if [[ -n "${holder_info}" ]]; then
            echo -e "\033[33m   占用信息：${holder_info}\033[0m"
            holder_pid=$(echo "${holder_info}" | sed -n 's/^PID=\([0-9]*\).*/\1/p')
            [[ -n "${holder_pid}" ]] && echo -e "\033[33m   如需强制结束：kill -9 ${holder_pid}\033[0m"
        else
            echo -e "\033[33m   锁文件无占用信息（可能为残留空文件），可先确认无发布进程后重试\033[0m"
        fi
        exit 1
    fi
    # 已持有锁，覆盖写入占用信息（此时无并发写者，写入安全）
    echo "PID=$$ | SERVICE=${svc} | START=${START_DATETIME}" > "${LOCK_FILE}"
    echo "→ 已获取 [${svc}] 发布锁，锁文件：${LOCK_FILE}"
    return 0
}

# 平滑回滚：删失败容器 → 恢复compose → 新>旧则保留新容器并提示人工清理 → 否则用旧镜像替代
# 注意：本函数在do_smooth_deploy的pushd compose目录上下文中执行，无需额外pushd/popd
function smooth_deploy_fail_recover {
    local svc="$1"
    local old_replica="$2"
    local prev_img="$3"
    # old_container_ids: 来自调用方do_smooth_deploy的局部变量（bash动态作用域，子函数可直接访问调用链上的局部变量），发布前采集的旧容器ID列表

    trap - ERR

    echo -e "\033[31m\n【平滑发布异常，执行回退】\033[0m"

    # 清理可能残留的临时override文件（发布轮次中start失败时，正常路径的rm不会执行）
    rm -f "${COMPOSE_DIR}/.deploy-override.yml"

    # ① 清理所有新容器（健康检查失败=发布未成功，新容器无论什么状态都要删除）
    local all_current_cids
    all_current_cids=$(docker compose ps "${svc}" --quiet)
    for cid in ${all_current_cids}; do
        local is_old=false
        for oid in "${old_container_ids[@]}"; do
            [[ "${cid}" == "${oid}" ]] && { is_old=true; break; }
        done
        if [[ "${is_old}" == "false" ]]; then
            local cid_status
            cid_status=$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null)
            echo "→ 清理新容器: ${cid}（状态：${cid_status}）"
            dump_container_diag "${cid}"
            docker stop "${cid}" >/dev/null 2>&1
            docker rm "${cid}" >/dev/null 2>&1
        fi
    done

    # ② 统计剩余新/旧容器数量
    local new_count=0
    local remaining_old_ids=()
    local all_cids
    all_cids=$(docker compose ps --filter "status=running" "${svc}" --quiet)
    for cid in ${all_cids}; do
        local is_old=false
        for oid in "${old_container_ids[@]}"; do
            [[ "${cid}" == "${oid}" ]] && { is_old=true; break; }
        done
        if [[ "${is_old}" == "true" ]]; then
            remaining_old_ids+=("${cid}")
        else
            ((new_count++))
        fi
    done
    local old_count=${#remaining_old_ids[@]}

    # ③ 无任何新容器成功 → 旧容器全部还在，无需替代，直接完成回退
    if [[ ${new_count} -eq 0 ]]; then
        echo -e "\033[32m√ 平滑回退完成，全部 ${old_count} 个旧容器仍在运行，服务未中断\033[0m"
        popd >/dev/null
        exit 1
    fi

    # ④ 新容器数量 > 旧容器数量 → 镜像没问题，保留新容器，提示人工清理剩余旧容器
    if [[ ${new_count} -gt ${old_count} ]]; then
        echo -e "\033[33m! 已成功替换 ${new_count}/${old_replica} 个副本，保留新版本容器\033[0m"
        echo -e "\033[33m   以下 ${old_count} 个旧容器仍在使用旧镜像，请人工确认后停止：\033[0m"
        for oid in "${remaining_old_ids[@]}"; do
            echo -e "\033[33m   → 旧容器ID: ${oid}\033[0m"
        done
        echo -e "\033[33m   操作命令: docker stop <容器ID> && docker rm <容器ID>\033[0m"
        popd >/dev/null
        exit 1
    fi

    # ⑤ 新<=旧且新>0 → 部分成功但不够多数，用旧镜像创建替代容器
    if [[ -z "${prev_img}" ]]; then
        echo -e "\033[33m! 无历史发布记录，无法回滚镜像，保留剩余旧容器继续运行\033[0m"
        popd >/dev/null
        exit 1
    fi

    if ! docker inspect --type image "${prev_img}" >/dev/null 2>&1; then
        echo -e "\033[33m! 旧镜像 ${prev_img} 已丢失，无法回滚，请人工介入\033[0m"
        popd >/dev/null
        exit 1
    fi

    echo -e "\033[31m③ 用旧镜像 ${prev_img} 创建替代容器\033[0m"
    docker tag "${prev_img}" "${svc}:latest" || die "docker tag 失败：${prev_img} → ${svc}:latest"
    local scale_up=$((old_replica + 1))
    docker compose create --scale "${svc}=${scale_up}" --no-recreate "${svc}"
    docker compose start "${svc}" 2>&1

    # ④ 健康检测替代容器（内联检测，避免die导致脚本直接退出跳过清理）
    local replace_cid
    replace_cid=$(docker compose ps --filter "status=running" "${svc}" --quiet | tail -n1)
    echo "→ 等待替代容器 ${replace_cid} 健康就绪"
    sleep 3
    local start_ts=$(date +%s)
    local health_ok=false
    while true; do
        local elapsed=$(($(date +%s) - start_ts))
        if [[ ${elapsed} -ge ${HEALTH_TIMEOUT} ]]; then
            echo -e "\033[31m   替代容器健康检测超时${HEALTH_TIMEOUT}s\033[0m"
            dump_container_diag "${replace_cid}"
            break
        fi
        local cip
        cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${replace_cid}")
        local port
        port=$(get_actuator_port "${svc}")
        local ret
        ret=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${cip}:${port}/actuator/health" || true)
        if [[ "${ret}" == "200" ]]; then
            health_ok=true
            echo -e "\033[32m   √ 替代容器健康检测通过，耗时${elapsed}s\033[0m"
            break
        fi
        sleep 2
    done

    if [[ "${health_ok}" == "true" ]]; then
        # ⑤ 替代容器健康，清理所有新版本容器
        echo -e "\033[31m④ 替代容器就绪，清理所有新版本容器\033[0m"
        for cid in ${all_cids}; do
            local is_old=false
            for oid in "${old_container_ids[@]}"; do
                [[ "${cid}" == "${oid}" ]] && { is_old=true; break; }
            done
            if [[ "${is_old}" == "false" ]]; then
                echo "→ 停止新版本容器: ${cid}"
                docker stop "${cid}" >/dev/null 2>&1
                docker rm "${cid}" >/dev/null 2>&1
            fi
        done
        echo -e "\033[32m√ 平滑回退完成，全部容器已恢复旧版本 ${prev_img}\033[0m"
    else
        docker stop "${replace_cid}" >/dev/null 2>&1
        docker rm "${replace_cid}" >/dev/null 2>&1
        echo -e "\033[31mX 替代容器也启动失败，可能配置变更或外部依赖异常\033[0m"
        echo -e "\033[33m! 请人工介入排查，当前剩余容器可能混合新旧版本\033[0m"
    fi

    popd >/dev/null
    exit 1
}

# 平滑滚动发布主逻辑：create --no-recreate 启新 → 健康检测 → 手动删旧
function do_smooth_deploy() {
    set -o errtrace
    local svc="$1"
    local new_tag="$2"

    local actuator_port
    actuator_port=$(get_actuator_port "${svc}")

    # 平滑发布必须配置健康检测端口：无端口时新容器无法探活、失败也无法自动回滚，直接拒绝执行
    if [[ -z "${actuator_port}" ]]; then
        die "平滑发布服务 [${svc}] 未配置健康检测端口，请加入 HEALTH_CHECK_LIST 后再平滑发布"
        return 1
    fi

    pushd "${COMPOSE_DIR}" >/dev/null || { die "进入compose目录失败 ${COMPOSE_DIR}"; return 1; }

    # ========= 预检：compose文件合法性 =========
    if ! validate_compose_file; then
        popd >/dev/null
        return 1
    fi

    # ========= 预检：采集旧信息 =========
    local old_replica
    old_replica=$(get_running_replica_count "${svc}")

    local prev_tag
    prev_tag=$(get_last_release_tag "${svc}")

    # 采集当前所有运行容器ID（用于区分新旧容器、按序删除旧容器）
    local old_container_ids=()
    if [[ "${old_replica}" -gt 0 ]]; then
        while IFS= read -r cid; do
            [[ -n "${cid}" ]] && old_container_ids+=("${cid}")
        done < <(docker compose ps --filter "status=running" "${svc}" --quiet)
    fi

    # ========= 分支：无运行容器 =========
    if [[ "${old_replica}" -lt 1 ]]; then
        echo "! 当前运行副本数0，不走平滑发布，直接启动服务"
        docker compose up -d "${svc}"

        # 健康检测：容器起来后探活（未配置健康端口的服务跳过）
        local cid health_port
        cid=$(docker compose ps "${svc}" --quiet | head -n 1)
        health_port=$(get_actuator_port "${svc}")
        if [[ -z "${cid}" ]]; then
            echo -e "\033[31mX ${svc} 容器未创建成功，请检查镜像与compose配置\033[0m"
            popd >/dev/null
            return 1
        fi
        if [[ -n "${health_port}" ]]; then
            if ! wait_container_health "${cid}" "${health_port}"; then
                dump_container_diag "${cid}"
                popd >/dev/null
                return 1
            fi
        fi

        record_release_log "${svc}" "${new_tag}"
        popd >/dev/null
        trap - ERR
        return 0
    fi

    # ========= 正常滚动发布 =========
    echo "→ 当前运行副本数：${old_replica}"
    [[ -n "${prev_tag}" ]] && echo "→ 上一版本tag(故障回滚备用): ${prev_tag}"
    echo "→ 旧容器ID列表: ${old_container_ids[*]}"

    # 开启ERR trap，失败时自动调用回滚函数（die主动退出时跳过回滚）
    trap '[[ -z "${_DIE_EXIT}" ]] && smooth_deploy_fail_recover '"${svc}"' '"${old_replica}"' '"${svc}:${prev_tag}"'' ERR

    # 记录发布前已存在的新镜像容器ID，后续轮次排除避免误取
    local processed_new_ids=()

    for ((i=0; i < old_replica; i++)); do
        echo ""
        echo "==== 第 $((i+1))/${old_replica} 轮滚动替换 ===="

        # 创建临时override文件，指定新镜像tag（不修改原compose文件，避免触发全量重建）
        local override_file="${COMPOSE_DIR}/.deploy-override.yml"
        cat > "${override_file}" <<EOF
services:
  ${svc}:
    image: ${svc}:${new_tag}
EOF

        # 用新镜像创建新容器（--no-recreate 不重建现有容器，只创建新增的）
        local scale_up=$((old_replica + 1))
        echo "→ create --scale=${scale_up} --no-recreate -f .deploy-override.yml（仅创建新容器，使用新镜像）"
        docker compose -f docker-compose.yml -f .deploy-override.yml create --scale "${svc}=${scale_up}" --no-recreate "${svc}"
        echo "→ start 启动新容器"
        docker compose -f docker-compose.yml -f .deploy-override.yml start "${svc}" 2>&1
        rm -f "${override_file}"

        # 通过容器ID差集识别本轮真正的新容器（不依赖镜像tag，兼容不打包时新旧容器同tag场景）
        local new_container_id=""
        local new_container_status=""
        for cid in $(docker compose ps "${svc}" --quiet); do
            # 跳过发布前的旧容器
            local is_old=false
            for oid in "${old_container_ids[@]}"; do
                [[ "${cid}" == "${oid}" ]] && { is_old=true; break; }
            done
            [[ "${is_old}" == "true" ]] && continue
            # 跳过之前轮次已处理的新容器
            local already_processed=false
            for pid in "${processed_new_ids[@]}"; do
                [[ "${cid}" == "${pid}" ]] && { already_processed=true; break; }
            done
            [[ "${already_processed}" == "true" ]] && continue

            new_container_id="${cid}"
            new_container_status=$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null)
            break
        done
        echo "→ 本轮新增容器ID：${new_container_id}（状态：${new_container_status}）"

        # 未识别到新容器（create失败等），触发回滚
        if [[ -z "${new_container_id}" ]]; then
            echo -e "\033[31m   未识别到本轮新容器，create可能失败\033[0m"
            return 1
        fi

        # 记录本轮新容器ID，后续轮次排除
        processed_new_ids+=("${new_container_id}")

        # 容器未进入running状态，打印诊断并触发回滚
        if [[ "${new_container_status}" != "running" ]]; then
            echo -e "\033[31m   新容器未成功启动（状态：${new_container_status}），打印诊断信息：\033[0m"
            dump_container_diag "${new_container_id}"
            echo -e "\033[31m   新容器启动失败，状态：${new_container_status}\033[0m"
            return 1
        fi

        # 健康检测（失败时return 1触发ERR trap → smooth_deploy_fail_recover）
        wait_container_health "${new_container_id}" "${actuator_port}"

        # 健康通过，停止并销毁一个旧容器
        local old_id="${old_container_ids[$i]}"
        echo "→ 健康通过，停止旧容器: ${old_id}"
        docker stop "${old_id}" >/dev/null 2>&1
        docker rm "${old_id}" >/dev/null 2>&1
        sleep 2
    done

    # √ 全部轮次成功
    trap - ERR
    popd >/dev/null

    record_release_log "${svc}" "${new_tag}"
    echo ""
    echo "√ ${svc} 全部副本平滑发布完成，镜像tag=${new_tag}，副本数保持 ${old_replica}"
}

# 停机直接发布
function do_stop_start_deploy() {
    local svc="$1"
    local tag="$2"

    pushd "${COMPOSE_DIR}" >/dev/null || { die "进入compose目录失败 ${COMPOSE_DIR}"; return 1; }
    echo "→ 停机发布：先down再up"
    docker compose down "${svc}"
    docker compose up -d "${svc}"

    # 健康检测：容器起来后探活（未配置健康端口的服务跳过）
    local cid health_port
    cid=$(docker compose ps "${svc}" --quiet | head -n 1)
    health_port=$(get_actuator_port "${svc}")
    if [[ -z "${cid}" ]]; then
        echo -e "\033[31mX ${svc} 容器未创建成功，请检查镜像与compose配置\033[0m"
        popd >/dev/null
        return 1
    fi
    if [[ -n "${health_port}" ]]; then
        if ! wait_container_health "${cid}" "${health_port}"; then
            dump_container_diag "${cid}"
            popd >/dev/null
            die "${svc} 健康检测失败，请人工介入排查"
        fi
    else
        echo "! ${svc} 未配置健康检测端口，跳过探活"
    fi
    popd >/dev/null

    record_release_log "${svc}" "${tag}"
    echo "√ ${svc} 停机发布完成"
}

# 构建镜像
function do_build_image() {
    local svc="$1"
    local tag="$2"

    local build_dir="${SERVICE_BUILD_DIR[$svc]}"
    local dockerfile_name="${SERVICE_DOCKERFILE[$svc]}"

    [[ ! -d "${build_dir}" ]] && { die "构建目录不存在：${build_dir}"; return 1; }
    [[ ! -f "${build_dir}/${dockerfile_name}" ]] && { die "Dockerfile不存在：${build_dir}/${dockerfile_name}"; return 1; }

    pushd "${build_dir}" >/dev/null || { die "进入构建目录失败 ${build_dir}"; return 1; }
    echo "→ 开始构建镜像 ${svc}:${tag}"
    # 构建时同时打唯一tag和latest，latest用于compose文件引用
    docker build -t "${svc}:${tag}" -t "${svc}:latest" -f "${dockerfile_name}" . || { die "docker build 构建失败"; return 1; }
    popd >/dev/null

    echo "√ 构建完成镜像 ${svc}:${tag}"
}

# 回滚业务逻辑
function do_rollback_workflow() {
    local svc="$1"
    local target_tag="$2"

    validate_service_exists "${svc}" || exit 1

    # 没有传入tag，则自动取上一个有效版本（跳过当前版本及重复记录）
    if [[ -z "${target_tag}" ]]; then
        target_tag=$(get_prev_release_tag "${svc}")
        [[ -z "${target_tag}" ]] && die "无法获取上一个版本tag，请手动指定tag回滚" && exit 1
    fi

    echo "===== 执行回滚 ${svc} 目标tag: ${target_tag} ====="
    if is_smooth_service "${svc}"; then
        echo "  回滚模式: 平滑滚动回滚"
    else
        echo "  回滚模式: 停机直接回滚（停新启旧）"
    fi

    # 前置校验：目标镜像必须存在，否则终止回滚，保持当前容器不变
    local image_name="${svc}:${target_tag}"
    check_image_exist "${image_name}" || exit 1

    pushd "${COMPOSE_DIR}" >/dev/null || { die "进入compose目录失败 ${COMPOSE_DIR}"; exit 1; }
    docker tag "${image_name}" "${svc}:latest" || { die "docker tag 失败：${image_name} → ${svc}:latest"; exit 1; }
    popd >/dev/null

    # 按服务发布模式执行回滚
    if is_smooth_service "${svc}"; then
        do_smooth_deploy "${svc}" "${target_tag}"
    else
        do_stop_start_deploy "${svc}" "${target_tag}"
    fi
    exit 0
}

# 普通发布工作流（构建 + 发布）
function do_normal_workflow() {
    local build_flag="$1"
    local svc="$2"
    local new_tag="$3"

    validate_service_exists "${svc}" || exit 1

    # build_flag=0（不打包）时，解析latest实际tag，保证后续打印/发布/记录使用真实存在的tag
    if [[ "${build_flag}" != "1" ]]; then
        local real_tag
        real_tag=$(get_latest_real_tag "${svc}")
        if [[ -z "${real_tag}" ]]; then
            die "无法解析 ${svc}:latest 对应的实际tag（latest不存在或未按时间戳规范打tag）"
            return 1
        fi
        new_tag="${real_tag}"
    fi

    echo "========================================="
    echo "  发布开始时间: ${START_DATETIME}"
    echo "  服务: ${svc}"
    echo "  新版本镜像tag: ${new_tag}"
    echo "  打包: $([ "${build_flag}" = "1" ] && echo '是' || echo '否')"
    if is_smooth_service "${svc}"; then
        echo "  发布模式: 平滑滚动发布"
    else
        echo "  发布模式: 停机直接发布"
    fi
    echo "========================================="

    # 是否执行构建
    if [[ "${build_flag}" == "1" ]]; then
        do_build_image "${svc}" "${new_tag}" || exit 1
    else
        echo "→ 跳过构建，复用已有镜像 ${svc}:latest（实际tag=${new_tag}）"
    fi

    echo ""
    echo "→ 开始执行发布流程 ${svc}"

    if is_smooth_service "${svc}"; then
        do_smooth_deploy "${svc}" "${new_tag}"
    else
        do_stop_start_deploy "${svc}" "${new_tag}"
    fi

    # 统计总耗时
    local end_ts end_datetime cost_sec
    end_ts=$(date +%s)
    end_datetime=$(date '+%Y-%m-%d %H:%M:%S')
    cost_sec=$((end_ts - START_TS))

    echo ""
    echo "========================================="
    echo "  发布开始: ${START_DATETIME}"
    echo "  发布结束: ${end_datetime}"
    echo "  总耗时: ${cost_sec} 秒"
    echo "========================================="
    echo ""
    echo "查看日志命令：cd ${COMPOSE_DIR} && docker compose logs -f ${svc}"
}

##############################################################################
# 【程序入口】
##############################################################################
function main() {
    local ACTION="$1"
    local SERVICE="$2"
    local ROLLBACK_TAG="$3"

    # 不传任何参数时，默认：构建 + 发布 your-service1
    if [[ -z "${ACTION}" ]]; then
        ACTION="1"
        SERVICE="your-service1"
        echo "! 未传入参数，使用默认行为：deploy.sh 1 your-service1"
        echo
    fi

    # 参数校验：ACTION 仅支持 0 / 1 / rollback，服务名必填
    case "${ACTION}" in
        0|1|rollback) ;;
        *)
            die "非法参数 [${ACTION}]，用法：deploy.sh [0|1|rollback] <服务名> [tag]"
            ;;
    esac
    if [[ -z "${SERVICE}" ]]; then
        die "缺少服务名参数，用法：deploy.sh [0|1|rollback] <服务名> [tag]"
    fi

    # 按服务加并发锁（覆盖构建+发布+回滚全流程，防止同一服务并发操作）
    acquire_deploy_lock "${SERVICE}"

    # 回滚分支
    if [[ "${ACTION}" == "rollback" ]]; then
        do_rollback_workflow "${SERVICE}" "${ROLLBACK_TAG}"
    fi

    local BUILD_FLAG="${ACTION}"
    local NEW_TAG=$(date +%Y%m%d%H%M%S)
    do_normal_workflow "${BUILD_FLAG}" "${SERVICE}" "${NEW_TAG}"
}

# 启动入口
main "$@"