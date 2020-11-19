#!/bin/sh

hugo --theme=harbor --buildDrafts --baseUrl="http://yinminghao.top/"

rsync -avz --delete public/ root@121.36.96.107:/usr/local/nginx/ymh.blog