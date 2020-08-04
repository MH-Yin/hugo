---
title: "Fabric交易源码分析"
date: 2020-08-03T19:45:02+08:00
draft: true
tags: [fabric]
---

**本系列为对 fabric [release-2.1](https://github.com/hyperledger/fabric/tree/release-2.1) 版本代码阅读的记录，如有不当之处，烦请指正**

> 本文对在一个正常运行fabric网络下交易的追踪，了解 fabric 的内部处理方式，文章主要针对交易流程中关键的步骤进行说明，具体的实现方式和代码细节不在本文讨论范围，感兴趣的读者可以自行阅读相关代码。为了避免出现冗长的代码段，一些判断、错误处理的代码将被省略。

<!--more-->

## 背景知识

本文假定读者对 fabric 机制有一定了解，如果和笔者一样是之前没有接触过 fabric, 可以从[官方文档](https://stone-fabric.readthedocs.io/en/latest/whatis.html)入手，也可以查看笔者的另一篇对 fabric 介绍的文章。 

对交易流程的介绍可以查阅[文档Transaction Flow](https://stone-fabric.readthedocs.io/en/latest/txflow.html)。在运行之前，我们假定：    </br> 1. 网络中存在正常运行的 chan (利用通道可以同时参与多个、彼此独立的区块链网络)。
2. 网络中的节点、用户均使用组织CA完成注册、登记并获得确认身份的加密证明。
3. chaincode(链码,定义交易的执行逻辑：定价规则，背书策略等)已经在 Peer 节点上安装并在通道上完成了实例化。

除正常的交易之外，本文也包含私有数据的处理逻辑，关于私有数据介绍可查阅[附录](#pdc), 当在链码中引用私有数据集合时，为了保护私有数据在提案、背书和提交交易过程中的机密性，私有数据的交易流程略有不同。
<span id="bg"></span>

## 交易流程

我们从源码中的  [chaincodeInvoke 函数(internal/peer/chaincode/invoke.go#L46)](https://github.com/hyperledger/fabric/blob/c2e8534b4cc37c17b05eb8d0c57a9fed14db5037/internal/peer/chaincode/invoke.go#L46) 这一客户端调用开始，分析 fabric 网络中三种角色(**客户端、背书节点、排序节点**)在交易(提案)生命周期中的行为与处理逻辑。

### 一、 客户端
客户端构造**交易提案**并将其发送到 Endorser (背书)节点，交易提案中包含本次交易要调用的合约标识、合约方法和参数信息以及客户端签名等。获取到 Endorser (背书)节点背书后组装成新的消息 **Envelope** 发送到 order (排序)节点

当客户端提案调用一个链码函数来读取或写入**私有数据**时，会将私有数据(或用于在链码中生成私有数据的数据)放在提案的 transient 字段中发送给被授权的背书节点。

```go
func chaincodeInvoke(...) {
    // 构造 ChaincodeCmdFactory, 包含背书节点 client API, 
    // 签名器、客户端的 TLS 证书，代理节点等
    cf, err = InitCmdFactory(cmd.Name(), true, true, cryptoProvider)
     
    // chaincodeInvokeOrQuery 调用 chaincode 并获取返回值
    return chaincodeInvokeOrQuery(cmd, true, cf)
} 

func ChaincodeInvokeOrQuery(...) (*pb.ProposalResponse, error) {
    // 构建提案(Proposal:可以描述交易), 输入参数包括调用的合约标识、合约方法和参数信息等
    // tMap: 私有数据，或用于在链码中生成私有数据的数据。
    prop, txid, err := protoutil.CreateChaincodeProposalWithTxIDAndTransient(..., tMap)
    
    // 签名提案/交易
    signedProp, err := protoutil.GetSignedProposal(prop, signer)

    // 发送签名后的提案到背书节点并获取返回各个背书节点对该提案的响应
    responses, err := processProposals(endorserClients, signedProp)
    
    // 获取背书后组装成 Envelope message, 包括合法性校验
    env, err := protoutil.CreateSignedTx(prop, signer, responses...)
    
    // 发送 Envelope message 到排序节点
    bc.Send(env)
}
```
</br>

**关键数据结构**
```go
// 发送到背书节点的 Proposal
type Proposal struct {
    Header:
        ChannelHeader: // 包括txid、时间戳, chanId等信息
        SignatureHeader: // 签名
    Payload: // 执行 chaincode 的输入
}

// 发送到排序节点的 Envelope message
type Envelope struct {
    SignatureHeader: // 签名
    Header: Proposal.Header
    Data: []*TransactionAction
}

type Transaction struct {
    Header: Proposal.Header
    Payload:
        ChaincodeProposalPayload: // 执行 chaincode 的输入: 请求智能合约的函数名、参数等
        Action: 
            ProposalResponsePayload: // 链码模拟执行结果,对KV类型状态数据库的读写集
            Endorsements: // 提案的背书，基本上是背书节点在payload的签名
}
```

</br>

### 二、 背书节点

背书节点收到客户端交易提案后，会模拟执行交易，然后将原始交易提案和执行结果打包到一起，进行签名并发回给客户端，其中在模拟执行交易期间产生的数据修改不会写到账本上。

背书节点处理**私有数据**时，会将其存储在 transient data store （节点的本地临时存储库）中。然后根据组织集合的策略将私有数据通过 gossip 分发给授权的节点。背书节点将提案响应(背书的读写集)发送给客户端，包含了公共数据，还包含任何私有数据键和值的哈希。**私有数据不会被发送回客户端**。

```go
// ProcessProposal process the Proposal
func (e *Endorser) ProcessProposal(signedProp *pb.SignedProposal) (*pb.ProposalResponse) {
    // 返回没有零字段的 UnpackedProposal
    up := UnpackProposal(signedProp)

    // 第一步: 检查 proposal headers 合法性等
    // checks the tx proposal headers, uniqueness and ACL
    e.preProcess(up, channel)

    // 预执行 Proposal
    pResp := e.ProcessProposalSuccessfullyOrError(up)
    return pResp
}

func (e *Endorser) ProcessProposalSuccessfullyOrError(up *UnpackedProposal) (*pb.ProposalResponse) {
    // 第二部: 根据 chaincode 模拟 proposal 执行结果,
    res, simulationResult, ccevent := e.SimulateProposal(txParams, up.ChaincodeName, up.Input)
    
    // 封装事物执行的结果
    simResult, err := txParams.TXSimulator.GetTxSimulationResults()
}

func (e *Endorser) SimulateProposal(...) (*pb.Response, []byte, *pb.ChaincodeEvent, error) {
    ...
    // ---执行提案并获取结果 调用链最后调用 handleTransaction函数
    // => e.Support.Execute(txParams, chaincodeName, input) => handleTransaction(...)
    res, ccevent, err := e.callChaincode(txParams, chaincodeInput, chaincodeName)

    // 封装事物执行的结果
    simResult, err := txParams.TXSimulator.GetTxSimulationResults()
    
    // 添加与私有读写集相关的可用集合配置信息
    pvtDataWithConfig, err := AssemblePvtRWSet(txParams.ChannelID, simResult.PvtSimulationResults, txParams.TXSimulator, e.Support.GetDeployedCCInfoProvider())
	
    // 根据组织集合的策略将私有数据通过 gossip 分发给授权的节点。
    e.PrivateDataDistributor.DistributePrivateData(txParams.ChannelID, txParams.TxID, pvtDataWithConfig, endorsedAt)
    
    // 返回公共读写集， 不返回私有数据
    pubSimResBytes, err := simResult.GetPubSimulationBytes()
    return res, pubSimResBytes, ccevent, nil
}

// 调用 chaincode
// vendor/github.com/hyperledger/fabric-chaincode-go/shim/handler.go#L195
func (h *Handler) handleTransaction(msg *pb.ChaincodeMessage) (*pb.ChaincodeMessage, error) {
    // Invoke is called to update or query the ledger in a proposal transaction.
    // Updated state variables are not committed to the ledger until the
    // transaction is committed.
    // 根据 proposal 更新、查询账本，但在交易 transaction 被提交前数据更改不会体现在账本上
    // 返回执行结果, 具体的执行逻辑由 chaincode 定义。
    res := h.cc.Invoke(stub)
}

```
</br>

对私有消息的处理(DistributePrivateData): 节点分发私有数据到被授权节点，这些节点暂存收到的私有数据
```go
// 初始化 gossip 节点时为消息接受配置规则
func NewGossipStateProvider(...) {
    ...
    // commChan 远程peer的请求或响应信息
    // 实现方式 : 在 ChannelDeMultiplexer 注册消息订阅, 满足过滤规则 remoteStateMsgFilter 消息会塞到 commChan 中
    // remoteStateMsgFilter 包括权限、chan等检测
    _, commChan := services.Accept(remoteStateMsgFilter, true)
    ...
    // 消息监听处理
    go s.receiveAndDispatchDirectMessages(commChan)
}

// 处理收到的数据
func (s *GossipStateProviderImpl) receiveAndDispatchDirectMessages(ch <-chan protoext.ReceivedMessage) {
	for msg := range ch {
		go func(msg protoext.ReceivedMessage) {
                    ...
		    if gm.GetPrivateData() != nil {
                        // 处理收到的私有数据(暂存), 调用链最后到 Persist()
                        // => Persist()
                        s.privateDataMessage(msg)
                    }
		}(msg)
	}
}

// 其他授权节点收到私有数据将其暂存在 transient store
// https://github.com/hyperledger/fabric/blob/07c468def167e83ea85d46d795113a98cb6081a1/core/transientstore/store.go#L103s
// 根据 txid 和 block 高度存储
func (s *Store) Persist(...) error {}
```
</br>

### 三、 排序节点 

Orderer(排序节点)对接收到的 Envelope message 进行排序，然后按照区块生成策略，将一批交易打包到一起，生成新的区块。在网络中共识(solo,raft,kafka，本文以raft为例)，完成所有节点账本的更新。带有私有数据哈希的区块被分发给所有节点。这样节点可以在不知道真实私有数据的情况下，来验证带有私有数据哈希值的交易。

```go
// ProcessMessage validates and enqueues a single message
func (bh *Handler) ProcessMessage(msg *cb.Envelope, addr string) (resp *ab.BroadcastResponse) {
    // 合法性验证
    ...
    // 调用 chan 的共识进行排序(solo, raft, kafka)
    processor.Order(msg, configSeq)
}
```
</br>

共识算法：[Raft 介绍](https://www.jianshu.com/p/8e4bbe7e276c), 有时间可以再写一下 etcd raft 的实现
```go
// 
func (c *Chain) Submit(req *orderer.SubmitRequest, sender uint64) error {
    select {
	case c.submitC <- &submit{req, leadC}:
        lead := <-leadC
        // 没有leader，返回错误 
        if lead == raft.None {
            return errors.Errorf("no Raft leader")
        }

        if lead != c.raftID {
            // 该节点不是 leader, 发送请求到 leader 节点
            if err := c.rpc.SendSubmit(lead, req); err != nil {
                return err
            }
        }
    }    
}

func (c *Chain) run() {
    ...
    select {
        // leader 对 Envelope message 的处理
        case s := <-submitC:
            // batches 请求裁剪成[]Env、pending 判断是否有待排序的Env
            batches, pending, err := c.ordered(s.req)
            
            // => createNextBlock
            block := c.propose(propC, bc, batches...)
            
            // leader 提议添加新的日志
            // raft 共识，收集足够的票完成 commit
            c.Node.Propose(ctx, block)
        
        // 达成共识后，更新账本    
        case app := <-c.applyC: 
            // => c.support.WriteBlock(block, m) 提交 block 到账本
            c.apply(app.entries)
    }
    ...
} 
```

</br>

**节点存储区块**
在区块提交的时候，节点会根据集合策略来决定它们是否有权访问私有数据。如果有访问权，则先检查本地 transient data store ，以确定它们是否在链码背书的时候已经接收到了私有数据。如果没有收到私有数据，就会尝试向其他已授权节点请求私有数据，然后对照公共区块上的哈希值来验证私有数据并提交交易和区块。
当验证或提交结束后，私有数据会被移动到这些节点私有数据库和私有读写存储的副本中。随后 transient data store 中存储的这些私有数据会被删除。

```go
// 处理 order 节点发来的消息
func (s *GossipStateProviderImpl) deliverPayloads() {
    // 提交区块
    // => StoreBlock()
    s.commitBlock(rawBlock, p)
}

// 存储 block 和 私有数据
func (c *coordinator) StoreBlock(block *common.Block, privateDataSets util.PvtDataCollections) error {
	// ... 合法性检测
	blockAndPvtData := &ledger.BlockAndPvtData{
		Block:          block,
		PvtData:        make(ledger.TxPvtDataMap),
		MissingPvtData: make(ledger.TxMissingPvtDataMap),
	}

    // 查询是否能从本地账本获取到私有数据
    exist := c.DoesPvtDataInfoExistInLedger(block.Header.Number)
    if exist {
        // 从账本获取私有数据
        commitOpts := &ledger.CommitOptions{FetchPvtDataFromLedger: true}
        // 私有数据已存在，提交 block 和私有数据
    	return c.CommitLegacy(blockAndPvtData, commitOpts)
    }
    ...
    //  解析区块，获取私有数据列表
    pvtdataToRetrieve, err := c.getTxPvtdataInfoFromBlock(block)

    // 获取私有数据
    // 这一步会检查节点的资格，然后从缓存，临时存储 TRANSIENT STORE 或其他节点检索
    retrievedPvtdata, err := pdp.RetrievePvtdata(pvtdataToRetrieve)
    blockAndPvtData.PvtData = retrievedPvtdata.blockPvtdata.PvtData
    blockAndPvtData.MissingPvtData = retrievedPvtdata.blockPvtdata.MissingPvtData

    // 提交 block 和私有数据
    c.CommitLegacy(blockAndPvtData, &ledger.CommitOptions{})

    // 清除工作
    retrievedPvtdata.Purge()
}

```

</br>

## 附录
### <span id="pdc">[私有数据](https://stone-fabric.readthedocs.io/en/latest/private-data/private-data.html)</span>

在某个通道上的一组组织需要对该通道上的其他组织保持数据私密的情况下，它们可以选择创建一个新通道，其中只包含需要访问数据的组织。但是，在每一种情况下创建单独的通道会产生额外的管理开销（维护链码版本、策略、MSP 等），并且不允许在保持部分数据私有的同时，让所有通道参与者都看到交易。

> **在通道内什么时候使用私有数据集，什么时候使用单独通道**
> - 当通道成员的一群组织必须对所有交易（和账本）保密时，使用通道。
> - 当交易（和账本）必须在一群组织间共享，并且这些组织中只有一部分组织可以访问交易中一些（或全部）私有数据时，使用集合。此外，由于私有数据是点对点传播的，而不是通过区块传播，所以当交易数据必须对排序服务节点保密时，应该使用私有数据集合。
> [返回正文](#bg)

