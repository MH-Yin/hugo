#!/bin/sh

hugo && rsync -avz --delete public/ root@47.93.118.219:/usr/local/nginx/ymh.blog