---
title: "部署hexo到云服务器"
date: 2020-08-03T19:44:21+08:00
draft: true
tags: [运维部署]
---

> **搜到的一般操作都是部署到github的静态页面上，个人因为先前买了一个阿里云服务器一直闲置，干脆就部署到阿里云上好了**

<!--more-->

**以下部署过程以ubuntu18.04(1核1G)为例**

##  预装环境

- 安装 hexo (过程中出现问题可查阅[附录](#q1))
    ```shell
    # 安装 node 与 npm 
    $ sudo apt install nodejs
    # 安装 hexo
    $ npm install hexo-cli -g
    ```
- 安装 git
    ```shell
    $ sudo apt install git-all
    ```
- 安装 nginx
    ```shell
    $ sudo apt install nginx
    ```

## 推送到远程服务器

- 设置同步方式 : 编辑 blog/_config.yaml,  增加 rSync 同步方式
    ```
    deploy:
        type: rsync
        host: **.**.**.** # 你的服务器ip
        user: root
        root: /usr/local/nginx/***.blog/ # 文件存放位置
        port: 22
    ```
- 配置 git hook : blog/hooks/pre-push.sh, 在 每次git push后触发
    ```shell
        #!/bin/sh
        # 推送到远程服务器
        hexo g -d 
    ```

## 配置nginx
1. 配置 [hexo.conf](#q2)
    ```shell
    $ sudo vi /etc/nginx/conf.d/hexo.conf
    ```
2. 配置全局 [nginx.conf](#q3)
    ```shell
    $ sudo vi /etc/nginx/nginx.conf
    ```
3. 重启 nginx
    ```
    $ service nginx restart
    ```


## 附录

### <span id="q1">预装环境时出现的问题</span>

- node 版本过低
    ```shell
    # 安装 node 版本管理工具
    $ npm i -g n # 失败了可以试下 npm i -g n --force
    # 安装最近的稳定版本
    $ n stable
    ```
- npm 版本过低
    ```shell
    $ npm i npm -g
    ```
- ENOENT: no such file or directory, open '/Users/xxx/package.json'
    ```
    $ npm init
    ```

### nginx 配置

- <span id="q2">hexo.conf</span>
    ```
    server {
        listen 80;
        listen [::]:80;
        server_name yinminghao.top; # 自己的域名
        root /usr/local/nginx/ymh.blog;
        access_log access.log;
        error_log error.log;

        location / {
            # First attempt to serve request as file, then
            # as directory, then fall back to displaying a 404.
            try_files $uri $uri/ =404;
        }
    }
    ```
- <span id="q3">nginx.conf</span>
    ```
        user root;
        worker_processes  1;

        error_log  /var/log/nginx/error.log warn;
        pid        /var/run/nginx.pid;


        events {
            worker_connections  1024;
        }


        http {
            include       /etc/nginx/mime.types;
            default_type  application/octet-stream;

            log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                            '$status $body_bytes_sent "$http_referer" '
                            '"$http_user_agent" "$http_x_forwarded_for"';

            access_log  /var/log/nginx/access.log  main;

            sendfile        on;
            #tcp_nopush     on;

            keepalive_timeout  65;

            gzip  on;

            include /etc/nginx/conf.d/*.conf;
        }
    ```