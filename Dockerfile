# syntax=docker/dockerfile:1

# ============================================================
# Stage 1: 编译前端（独立 node 环境，自带 npm）
# ============================================================
FROM arm64v8/node:20 AS frontend-builder

WORKDIR /src

# 先复制 package.json，利用缓存
COPY web/package*.json ./web/
RUN cd web && npm install --registry=https://registry.npmmirror.com

# 复制前端源码并构建
COPY web/ ./web/
RUN cd web && npm run build:prod

# ============================================================
# Stage 2: 编译后端（maven 环境）
# ============================================================
FROM arm64v8/maven:3.9-eclipse-temurin-21 AS wvp-builder

WORKDIR /src
COPY . /src

# 把前端产物塞进后端静态资源目录
# 注意：如果你的前端输出目录不是 dist/，把下面的 dist 改成实际目录
COPY --from=frontend-builder /src/web/dist/ /src/src/main/resources/static/

RUN mvn clean package -Dmaven.test.skip=true -Dmaven.javadoc.skip=true

# ============================================================
# Stage 3: 编译 ZLMediaKit
# ============================================================
FROM arm64v8/ubuntu:22.04 AS zlm-builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake build-essential libssl-dev libsrtp2-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth=1 https://github.com/ZLMediaKit/ZLMediaKit.git

WORKDIR /src/ZLMediaKit
RUN git submodule update --init --recursive --depth=1

RUN mkdir build && cd build \
    && cmake -DCMAKE_BUILD_TYPE=Release .. \
    && make -j$(nproc)

# ============================================================
# Stage 4: 一体化运行镜像
# ============================================================
FROM arm64v8/ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jre-headless \
    supervisor \
    mysql-server \
    redis-server \
    nginx \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/wvp /opt/media /opt/polaris/redis \
    /etc/nginx/templates /var/lib/mysql /var/lib/redis \
    /var/log/supervisor /var/log/nginx \
    /opt/media/log /opt/media/bin/www/record \
    /docker-entrypoint-initdb.d

COPY --from=wvp-builder /src/target/*.jar /opt/wvp/wvp.jar
COPY --from=zlm-builder /src/ZLMediaKit/release/linux/Release/ /opt/media/

COPY docker/media/config.ini       /opt/media/config.ini
COPY docker/redis/conf/redis.conf  /opt/polaris/redis/redis.conf
COPY docker/nginx/templates/       /etc/nginx/templates/
COPY 数据库/2.7.4/初始化-mysql-2.7.4.sql /docker-entrypoint-initdb.d/init.sql

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 18978 8116/tcp 8116/udp \
       10935/tcp 10935/udp 5540/tcp 5540/udp \
       10000/tcp 10000/udp 8080

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]