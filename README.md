# deploy.sh - Docker Compose 零停机平滑发布脚本

纯 bash 实现的单机发布工具：构建镜像、平滑滚动发布、失败自动回滚、手动回滚一体化。不依赖 Swarm / Kubernetes，Docker Compose 环境开箱即用。

## 特性

- 平滑滚动发布：逐副本替换，健康检查通过才停旧容器，全程零停机
- 应用级健康检测：基于 actuator/health 接口探活，未就绪不发流量
- 失败自动回滚：发布任意环节异常，自动清理新容器并恢复旧版本
- 手动回滚：支持回滚到上一有效版本或指定 tag
- 发布历史：每次发布自动记录，作为回滚依据
- 并发锁：flock 按服务粒度加锁，防止同一服务并发发布/回滚
- 双模式发布：白名单服务走平滑滚动，其余服务走停机发布

## 环境要求

- Linux 服务器（脚本为 bash）
- Docker Engine
- docker compose v2.x（docker-compose v1.25+ 理论兼容，已停止维护，不推荐）

## 快速开始

1. 把脚本放到服务器上，修改脚本顶部【配置区】：
   - 固定路径（源码目录、compose 目录、发布日志）
   - 服务列表（`SERVICE_BUILD_DIR`、`SERVICE_DOCKERFILE`）
   - 健康检测端口（`HEALTH_CHECK_LIST`，格式 `服务名:端口`）
   - 平滑发布白名单（`ROLLBACK_SERVICE_LIST`）
2. 构建并平滑发布：
   ```bash
   ./deploy.sh 1 your-service1
   ```
3. 出问题回滚上一版本：
   ```bash
   ./deploy.sh rollback your-service1
   ```

## 使用示例

| 命令 | 说明 |
|---|---|
| `./deploy.sh 1 your-service1` | 构建镜像 + 平滑发布 |
| `./deploy.sh 0 your-service1` | 跳过构建，复用本地 latest 镜像直接发布 |
| `./deploy.sh rollback your-service1` | 自动回滚到上一有效版本 |
| `./deploy.sh rollback your-service1 20260818160000` | 回滚到指定 tag |

不传参数默认执行 `./deploy.sh 1 your-service1`。

## 工作原理

1. 预检：校验 compose 文件合法性，采集当前副本数、上一版本 tag、旧容器 ID 列表
2. 每轮滚动（共副本数轮）：
   - 生成临时 override 文件指向新镜像 tag（不改动原 compose 文件）
   - `docker compose create --scale N+1 --no-recreate` 只创建新容器，旧容器不动
   - 启动后通过容器内网 IP 探测 `/actuator/health`
   - 健康通过 → 停止并删除一个旧容器 → 下一轮
3. 全部轮次完成：写发布历史

任一环节失败自动回滚：清理所有新容器 → 恢复 compose → 按剩余新旧容器数量分支处理（直接回退 / 保留新容器提示人工清理 / 用旧镜像创建替代容器探活后删新容器）。

> 注意：平滑发布的服务必须配置健康检测端口（`HEALTH_CHECK_LIST`），且不能绑定宿主机端口（否则副本扩容时端口冲突），请让前置网关/代理统一收口端口。

## 文件结构

```
deploy.sh   发布脚本本体
DEPLOY.md   完整使用说明（配置、原理、回滚、并发锁、FAQ）
LICENSE     Apache License 2.0
```

## License

[Apache License 2.0](LICENSE)
