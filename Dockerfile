# syntax=docker/dockerfile:1

# ============================================================
# Stage 1: 编译前端（独立 node 环境，自带 npm）
# ============================================================
FROM arm64v8/node:20 AS frontend-builder

WORKDIR /src

# 复制前端依赖清单，先安装依赖（利用缓存）
COPY web/package*.json ./web/
RUN cd web && npm install --registry=https://registry.npmmirror.com

# 复制前端源码并构建
COPY web/ ./web/
RUN cd web && npm run build:prod

# ============================================================
# Stage 2: 编译后端（maven 环境，注入前端产物）
# ============================================================
FROM arm64v8/maven:3.9-eclipse-temurin-21 AS wvp-builder

WORKDIR /src
COPY . /src

# 把前端产物复制到后端静态资源目录
# 默认假设前端输出目录为 web/dist/，如果实际不是，需要改
COPY --from=frontend-builder /src/web/dist/ /src/src/main/resources/static/

RUN mvn clean package -Dmaven.test.skip=true -Dmaven.javadoc.skip=true

# ============================================================
# Stage 3: 一体化运行镜像
# 基于官方 ZLMediaKit ARM64 镜像（已确认支持 linux/arm64）
# ============================================================
FROM zlmediakit/zlmediakit:master

USER root

# 安装运行时依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jre-headless \
    supervisor \
    mysql-server \
    redis-server \
    nginx \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 创建必要目录
RUN mkdir -p /opt/wvp /opt/polaris/redis \
    /etc/nginx/templates /var/lib/mysql /var/lib/redis \
    /var/log/supervisor /var/log/nginx \
    /docker-entrypoint-initdb.d

# 从构建阶段复制 WVP JAR
COPY --from=wvp-builder /src/target/*.jar /opt/wvp/wvp.jar

# 复制配置文件（路径按你仓库实际结构调整）
COPY docker/redis/conf/redis.conf  /opt/polaris/redis/redis.conf
COPY docker/nginx/templates/       /etc/nginx/templates/
COPY 数据库/2.7.4/初始化-mysql-2.7.4.sql /docker-entrypoint-initdb.d/init.sql

# 复制 Supervisor 配置
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 18978 8116/tcp 8116/udp \
       10935/tcp 10935/udp 5540/tcp 5540/udp \
       10000/tcp 10000/udp 8080

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]