# syntax=docker/dockerfile:1

# ============================================================
# Stage 1: 编译 WVP（用官方 docker/wvp/Dockerfile 的逻辑）
# ============================================================
FROM arm64v8/maven:3.9-eclipse-temurin-21 AS wvp-builder

WORKDIR /src
# 构建上下文是仓库根目录，直接 COPY 全部源码
COPY . /src

# 前端编译（目录名请按实际项目改，一般是 web 或 web_src）
RUN cd web && npm install --registry=https://registry.npmmirror.com && npm run build:prod && cd ..

# 后端编译
RUN mvn clean package -Dmaven.test.skip=true -Dmaven.javadoc.skip=true

# ============================================================
# Stage 2: 编译 ZLMediaKit（官方镜像 zlmediakit/zlmediakit 没有 arm64）
# ============================================================
FROM arm64v8/ubuntu:22.04 AS zlm-builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake build-essential libssl-dev libsrtp2-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth=1 https://gitee.com/xia-chu/ZLMediaKit.git \
    && cd ZLMediaKit \
    && git submodule update --init --recursive \
    && mkdir build && cd build \
    && cmake -DCMAKE_BUILD_TYPE=Release .. \
    && make -j$(nproc)

# ============================================================
# Stage 3: 一体化运行镜像
# ============================================================
FROM arm64v8/ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 运行时依赖：JRE + MySQL + Redis + Nginx + Supervisor + FFmpeg
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jre-headless \
    supervisor \
    mysql-server \
    redis-server \
    nginx \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 目录准备
RUN mkdir -p /opt/wvp /opt/media /opt/polaris/redis \
    /etc/nginx/templates /var/lib/mysql /var/lib/redis \
    /var/log/supervisor /var/log/nginx \
    /opt/media/log /opt/media/bin/www/record \
    /docker-entrypoint-initdb.d

# WVP JAR
COPY --from=wvp-builder /src/target/*.jar /opt/wvp/wvp.jar

# ZLMediaKit 编译产物
COPY --from=zlm-builder /src/ZLMediaKit/release/linux/Release/ /opt/media/

# 配置文件（全部来自 docker/ 目录，和 compose 中挂载路径一致）
COPY docker/media/config.ini       /opt/media/config.ini
COPY docker/redis/conf/redis.conf  /opt/polaris/redis/redis.conf
COPY docker/nginx/templates/       /etc/nginx/templates/

# 数据库初始化脚本（compose 中挂载自 ../数据库/2.7.4/）
COPY 数据库/2.7.4/初始化-mysql-2.7.4.sql /docker-entrypoint-initdb.d/init.sql

# Supervisor 配置
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# 端口：WVP HTTP 18978、SIP 8116、ZLM 各端口、Nginx 8080
EXPOSE 18978 8116/tcp 8116/udp \
       10935/tcp 10935/udp 5540/tcp 5540/udp \
       10000/tcp 10000/udp 8080

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]