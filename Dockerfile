# syntax=docker/dockerfile:1

# ============================================================
# WVP-GB28181-pro 一体化镜像
# 包含：前端静态资源 + WVP(本体) + ZLMediaKit + MySQL + Redis + Nginx
# 运行层基于 ZLMediaKit 官方镜像，确保 MediaServer 的所有依赖库
# （含 libpython）都可用，避免缺 so 导致 zlm 退出
# ============================================================

# ------------------------------------------------------------
# Stage 1: 编译前端
# web/vue.config.js 里 outputDir = ../src/main/resources/static
# ------------------------------------------------------------
FROM node:20 AS frontend-builder

WORKDIR /src

# 先装依赖，利用构建缓存
COPY web/package*.json ./web/
RUN cd web && npm install --registry=https://registry.npmmirror.com --legacy-peer-deps

# 复制源码并构建（webpack4 在 node17+ 需要 legacy provider）
COPY web/ ./web/
RUN cd web && NODE_OPTIONS="--max-old-space-size=4096 --openssl-legacy-provider" npm run build:prod

# ------------------------------------------------------------
# Stage 2: 编译后端，并把前端产物注入静态资源目录
# ------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-21 AS wvp-builder

WORKDIR /src
COPY . /src

# 前端产物覆盖到后端静态目录
COPY --from=frontend-builder /src/src/main/resources/static/ /src/src/main/resources/static/

RUN mvn clean package -Dmaven.test.skip=true -Dmaven.javadoc.skip=true

# ------------------------------------------------------------
# Stage 3: JDK（与基础发行版解耦，任何层都能用）
# ------------------------------------------------------------
FROM eclipse-temurin:21-jre AS jre

# ------------------------------------------------------------
# Stage 4: 一体化运行镜像（基于 ZLMediaKit 官方镜像）
# ------------------------------------------------------------
FROM zlmediakit/zlmediakit:master

USER root

ENV TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    Stream_IP=10.20.41.236 \
    SDP_IP=10.20.41.236 \
    SIP_ShowIP=10.20.41.236

# 阻止 apt 安装阶段自动启动服务
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# 官方 zlm 镜像里的 apt 源是第三方源，CI 上不一定可用，这里重置为官方源
RUN set -eux; \
    . /etc/os-release; \
    ARCH="$(dpkg --print-architecture)"; \
    if [ "$ARCH" = "arm64" ]; then MIRROR="http://ports.ubuntu.com/ubuntu-ports"; else MIRROR="http://archive.ubuntu.com/ubuntu"; fi; \
    rm -f /etc/apt/sources.list.d/*; \
    printf "deb %s %s main restricted universe multiverse\n" "$MIRROR" "$VERSION_CODENAME" > /etc/apt/sources.list; \
    printf "deb %s %s-updates main restricted universe multiverse\n" "$MIRROR" "$VERSION_CODENAME" >> /etc/apt/sources.list; \
    printf "deb %s %s-security main restricted universe multiverse\n" "$MIRROR" "$VERSION_CODENAME" >> /etc/apt/sources.list; \
    apt-get update

RUN apt-get install -y --no-install-recommends \
        supervisor \
        mysql-server \
        redis-server \
        nginx \
        ffmpeg \
        gettext-base \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone

# JDK
COPY --from=jre /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/java/openjdk/bin:$PATH

# 覆盖 ZLM 配置：hook 指向本机 WVP，端口与 WVP 配置保持一致
COPY docker/all-in-one/media/config.ini /opt/media/conf/config.ini

# 必要的运行目录
RUN mkdir -p /opt/wvp/config /opt/dist /opt/polaris/redis \
        /etc/nginx/templates /var/lib/mysql /var/run/mysqld /var/log/mysql \
        /var/log/supervisor /var/log/nginx /docker-entrypoint-initdb.d \
    && chown -R mysql:mysql /var/lib/mysql /var/run/mysqld /var/log/mysql

# WVP 本体
COPY --from=wvp-builder /src/target/*.jar /opt/wvp/wvp.jar
# WVP 运行配置（profile=docker，全部通过环境变量注入）
COPY docker/wvp/wvp/application.yml        /opt/wvp/config/application.yml
COPY docker/wvp/wvp/application-docker.yml /opt/wvp/config/application-docker.yml

# 前端静态资源交给 nginx 托管
COPY --from=frontend-builder /src/src/main/resources/static/ /opt/dist/

# Redis 配置
COPY docker/redis/conf/redis.conf /opt/polaris/redis/redis.conf
# Nginx 站点模板（entrypoint 用 envsubst 渲染）
COPY docker/all-in-one/nginx.conf.template /etc/nginx/templates/all-in-one.conf.template
# MySQL 初始化 SQL
COPY 数据库/2.7.4/初始化-mysql-2.7.4.sql /docker-entrypoint-initdb.d/init.sql
# Supervisor 与入口脚本
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/all-in-one/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && rm -f /etc/nginx/sites-enabled/default

# 数据持久化目录
VOLUME ["/var/lib/mysql", "/opt/media/bin/www/record"]

# web(nginx) / wvp / sip / rtmp / rtsp / rtp / rtc / srt
EXPOSE 8080 18978 8116/tcp 8116/udp \
       10935/tcp 10935/udp 5540/tcp 5540/udp \
       10000/tcp 10000/udp 8000/tcp 8000/udp 9000/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]