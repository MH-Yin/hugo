---
title: "Eos测试网"
date: 2020-08-17T17:34:16+08:00
draft: true
tags: [eos]
---

[参考文档](https://blog.csdn.net/ITleaks/article/details/80888789)

### 下载源码并编译

```shell
    $ git clone https://github.com/eosio/eos --recursive && cd eos
    $ git checkout v1.0.7
    $ git submodule update --init --recursive

    // 将系统币修改为EOS
    $ sed -i.bak '16i set( CORE_SYMBOL_NAME "EOS" )' CMakeLists.txt
    // 编译
    $ ./eosio_build.sh
```



### 搭建 eos 测试网络

1. 下载 eos 源码并构建 
    - 修改启动参数
    - 生成创世账号
    - 下载依赖、编译
2. 启动 eos 节点
    - 启动创世块生产者，eosio admin
    - 系统账号
    - 系统合约
3. 启动 eos 网络（多节点）
    - 加载合约
    - 创建账号
4. 网络中节点出块
5. 启动 eos 客户端/查询区块信息等操作
6. 买卖内存...
7. 转账，部署合约（创建token）、权限绑定、调用合约等操作

### 搭建 ipfs 测试网络

1. 下载 ipfs 源码并构建 
2. 创建 ipfs 节点
3. 启动节点服务器
4. 应用（从不同节点下载数据）

