---
title: "Fabric网络源码分析"
date: 2020-08-03T19:39:21+08:00
draft: true
tags: [fabric]
---

**本系列为对 fabric [release-2.1](https://github.com/hyperledger/fabric/tree/release-2.1) 版本代码阅读的记录，如有不当之处，烦请指正**

> 本文对 fabric 的网络层代码进行分析，介绍其基本思想与代码实现，包括组网、身份验证与广播实现等，

<!--more-->

## fabric 网络介绍

在之前的对 fabric 的介绍中，可以了解到 fabric 将交易(事务)执行、排序、验证进行分离，在这种设计下，我们可以对这些模块单独进行缩放。

与其他两个阶段点对点传播消息不同，排序阶段会对收到的交易(事务)进行共识排序，并将其分发到网络中的各个阶段，因此对网络层有更高的要求。

> 大多数共识算法(例如CFT、BFT)都受带宽限制(笔者之前从事基于algorand共识的公链开发时也遇到了网络瓶颈, 在网络流量、延迟等方面做了大量工作)，fabric 的排序共识(raft)也同样共识受到其节点网络容量的限制。无法通过添加更多共识节点来提高吞吐量，相反节点的增多会影响共识的性能。


**fabric 采用 gossip 实现消息的广播。**

### gossip 组件

区块通过 gossip 组件将排序服务签名后的区块广播到网络中其他节点，其他节点收到区块后验完整性组装成区块链。 

fabric 的通信层基于gRPC，并利用具有相互身份验证的TLS来保证消息的权限，gossip 组件维护系统中在线节点的成员认证关系并随时对其进行更新。

### gossip 作用与实现方式

1. gossip 采用 pull-push 协议在节点见之间可靠地分发消息。
2. 为了减轻从排序节点向网络发送数据块的负担，fabric 会选择一个领导节点，该节点代表它们从排序服务中获取数据块并使用 gossip 进行分发。
3. 在新节点加入或节点长时间断开连接时，gossip 负责这些节点的状态更新，也就是通常理解的**同步**作用


## 代码实现

fabric 的网络层基本在 gossip 包里实现

```
- gossip
    - api
    - comm
    - common
    - discovery
    - election
    - filter
    - gossip
    - identity
    - metrics 
    - privdata
    - protoext
    - service
    - state
    - util
```

### 组网

一个节点要加入网络，必须要知道一个已知的 Fabric 节点作为启动节点。 可以通过配置文件(配置文件)设置想要连接的节点

```
<core.yaml>
# Gossip related configuration
gossip:
    # Bootstrap set to initialize gossip with
    bootstrap: 127.0.0.1:7051
```        

节点启动创建用于广播的服务 ```initGossipService()```,  除了一些常见的监听端口操作外， 会调用```connect2BootstrapPeers``` 与配置文件定义的节点相连

```golang
// 保留主要逻辑
func (g *Node) connect2BootstrapPeers() {
	for _, endpoint := range g.conf.BootstrapPeers {
        // 用于标记节点，声明 pk
		identifier := func() (*discovery.PeerIdentification, error) {
			...
		}
		g.disc.Connect(discovery.NetworkMember{
			InternalEndpoint: endpoint,
			Endpoint:         endpoint,
		}, identifier)
	}
}

func (d *gossipDiscoveryImpl) Connect(member NetworkMember, id identifier) {
	go func() {
		for i := 0; i < d.maxConnectionAttempts && !d.toDie(); i++ {
            ...
			peer := &NetworkMember{
				InternalEndpoint: member.InternalEndpoint,
				Endpoint:         member.Endpoint,
				PKIid:            id.ID,
            }
            // 创建 MembershipRequest, 用与向连接节点请求已知的节点，按道理来说需要发送自己的节点避免重复，但是这里fabric为了安全暂时没有实现，
            // See FAB-2570 for tracking this issue.
			m, err := d.createMembershipRequest(id.SelfOrg)
			...
            // nil 签名
            ...

            // 发送 MembershipRequest
			go d.sendUntilAcked(peer, req)
			return
		}
	}()
}

// <------------------- server peer handle logic start ------------------->
// 每个节点在初始化 DiscoveryService(节点发现服务) 的时候会开启一个 handleMessages 的 goroutine, 对连接层消息进行处理, 这里也有周期性测活、周期性断线重连逻辑， 也会周期性的发送心跳包（alive message更新 alive 时间）
// 对于 MembershipRequest 的接收方，会对收到的消息进行响应

func (d *gossipDiscoveryImpl) handleMsgFromComm(msg protoext.ReceivedMessage) {
    ...
    // 判断是否为 MembershipRequest 消息
	if memReq := m.GetMemReq(); memReq != nil {
		selfInfoGossipMsg, err := protoext.EnvelopeToGossipMessage(memReq.SelfInformation)
        ...
        // 合法性校验等
        ...
        
        // 将自身感知到的网络节点发送给请求方, 包括 alive 节点与 dead 节点
		go d.sendMemResponse(selfInfoGossipMsg.GetAliveMsg().Membership, internalEndpoint, m.Nonce)
		return
    }
}   
// <------------------- server peer handle logic end ------------------->


// 同样在 handleMessages 逻辑里，也有对 MembershipResponse 消息的处理逻辑
func (d *gossipDiscoveryImpl) handleMsgFromComm(msg protoext.ReceivedMessage) {
    ...
    // 判断是否为 MembershipResponse 消息
	if memResp := m.GetMemRes(); memResp != nil {
		for _, env := range memResp.Alive {
			am, err := protoext.EnvelopeToGossipMessage(env)
			
			if d.msgStore.CheckValid(am) && d.crypt.ValidateAliveMsg(am) {
                // 处理 alive peer, 根据 am 时间戳更新 id2Member(map, 可以理解为通讯录)
                //  1. 若之前不存在，更新
                //       - learnNewMembers， 记录该节点信息到 aliveLastTS、deadLastTS、id2Member等
                //  2. 若之前存在，根据是否失活与本地连接时间戳对比进行决定是否更新
				d.handleAliveMessage(am)
			}
		}

		for _, env := range memResp.Dead {
			dm, err := protoext.EnvelopeToGossipMessage(env)
			// Newer alive message exists or the message isn't authentic
			if !d.msgStore.CheckValid(dm) || !d.crypt.ValidateAliveMsg(dm) {
				continue
			}
			newDeadMembers := []*protoext.SignedGossipMessage{}
			d.lock.RLock()
			if _, known := d.id2Member[string(dm.GetAliveMsg().Membership.PkiId)]; !known {
				newDeadMembers = append(newDeadMembers, dm)
			}
			d.lock.RUnlock()
			d.learnNewMembers([]*protoext.SignedGossipMessage{}, newDeadMembers)
		}
	}
}
```
此外，节点也会根据与 AnchorPeers 交换 membership 信息： 当节点加入channel时，会连接 anchor peer， 处理逻辑同connect （本质是transaction，系统合约调用/invoke） 。

### 节点件消息传播 (Gossip)

> 消息发送方式：
> - 点对点发送（end to end）
> - gossip方式——发送消息时会根据消息类型对节点进行过滤筛选（另外还会去除掉发送节点）后再随机（具体实现上是随机就近原则）选择k个节点发送消息。这里采用的是push和pull方式。

1. push
节点有了新消息后，随机选择 k 个节点（例如，3），向它们发送新消息。k个节点收到后，继续随机选择k个节点发送新信息，直到所有节点都知道该新信息。

```golang
// Gossip sends a message to other peers to the network
func (g *Node) Gossip(msg *pg.GossipMessage) {
    ...
    // 判断是否只在 channel 内转发
	if protoext.IsChannelRestricted(msg) {
		gc := g.chanState.getGossipChannelByChainID(msg.Channel)
		if gc == nil {
			g.logger.Warning("Failed obtaining gossipChannel of", msg.Channel, "aborting")
			return
		}
		if protoext.IsDataMsg(msg) {
			gc.AddToMsgStore(sMsg)
		}
	}
    ...
    // 将消息添加到batchingEmitter中，并定期(默认10ms)将它们分批转发 T 次，然后丢弃。 
    // 如果batchingEmitter的已存储消息计数达到/一定容量(默认是1)，则也会触发消息分发 => emit()
	g.emitter.Add(&emittedGossipMessage{
		SignedGossipMessage: sMsg,
		filter: func(_ common.PKIidType) bool {
			return true
		},
	})
}

func (p *batchingEmitterImpl) emit() {
    ...
	msgs2beEmitted := make([]interface{}, len(p.buff))
	for i, v := range p.buff {
		msgs2beEmitted[i] = v.data
	}

    // cb => gossipBatch
	p.cb(msgs2beEmitted)
	p.decrementCounters()
}

// 根据消息的不同路由策略，将消息发送到同一 peer 组，提高效率.
func (g *Node) gossipBatch(msgs []*emittedGossipMessage) {
    ...
	var blocks []*emittedGossipMessage
	var stateInfoMsgs []*emittedGossipMessage
	var orgMsgs []*emittedGossipMessage
	var leadershipMsgs []*emittedGossipMessage

    // 区分不同类型的消息
	isABlock := func(o interface{}) bool {
		return protoext.IsDataMsg(o.(*emittedGossipMessage).GossipMessage)
	}
	isAStateInfoMsg := func(o interface{}) bool {
		return protoext.IsStateInfoMsg(o.(*emittedGossipMessage).GossipMessage)
	}
	aliveMsgsWithNoEndpointAndInOurOrg := func(o interface{}) bool {
		msg := o.(*emittedGossipMessage)
		if !protoext.IsAliveMsg(msg.GossipMessage) {
			return false
		}
		member := msg.GetAliveMsg().Membership
		return member.Endpoint == "" && g.IsInMyOrg(discovery.NetworkMember{PKIid: member.PkiId})
	}
	isOrgRestricted := func(o interface{}) bool {
		return aliveMsgsWithNoEndpointAndInOurOrg(o) || protoext.IsOrgRestricted(o.(*emittedGossipMessage).GossipMessage)
	}
	isLeadershipMsg := func(o interface{}) bool {
		return protoext.IsLeadershipMsg(o.(*emittedGossipMessage).GossipMessage)
	}

	// Gossip blocks
    blocks, msgs = partitionMessages(isABlock, msgs)
    
    // gossipInChan 目的就是获取消息所属的channel， 然后获取该channel的路由并发送出去。
    //  1. 获取节点的 Membership
    //  2. 根据消息类型选择发送到指定的节点
    //      2.1 IsLeadershipMsg => 发送给所有已知节点
    //      2.2 Other => 随机选 k 个节点发(默认是三个/rand.Perm)
    // 3. 过滤节点并发送 => g.comm.Send (grpc.stream.Send)
	g.gossipInChan(blocks, func(gc channel.GossipChannel) filter.RoutingFilter {
		return filter.CombineRoutingFilters(gc.EligibleForChannel, gc.IsMemberInChan, g.IsInMyOrg)
	})

	// Gossip Leadership messages
	leadershipMsgs, msgs = partitionMessages(isLeadershipMsg, msgs)
	g.gossipInChan(leadershipMsgs, func(gc channel.GossipChannel) filter.RoutingFilter {
		return filter.CombineRoutingFilters(gc.EligibleForChannel, gc.IsMemberInChan, g.IsInMyOrg)
	})

	// Gossip StateInfo messages
	stateInfoMsgs, msgs = partitionMessages(isAStateInfoMsg, msgs)
	for _, stateInfMsg := range stateInfoMsgs {
		peerSelector := g.IsInMyOrg
		gc := g.chanState.lookupChannelForGossipMsg(stateInfMsg.GossipMessage)
		if gc != nil && g.hasExternalEndpoint(stateInfMsg.GossipMessage.GetStateInfo().PkiId) {
			peerSelector = gc.IsMemberInChan
		}

		peerSelector = filter.CombineRoutingFilters(peerSelector, func(member discovery.NetworkMember) bool {
			return stateInfMsg.filter(member.PKIid)
		})

		peers2Send := filter.SelectPeers(g.conf.PropagatePeerNum, g.disc.GetMembership(), peerSelector)
		g.comm.Send(stateInfMsg.SignedGossipMessage, peers2Send...)
	}

	// Gossip messages restricted to our org
	orgMsgs, msgs = partitionMessages(isOrgRestricted, msgs)
	peers2Send := filter.SelectPeers(g.conf.PropagatePeerNum, g.disc.GetMembership(), g.IsInMyOrg)
	for _, msg := range orgMsgs {
		g.comm.Send(msg.SignedGossipMessage, g.removeSelfLoop(msg, peers2Send)...)
	}

	// Finally, gossip the remaining messages
	for _, msg := range msgs {
		if !protoext.IsAliveMsg(msg.GossipMessage) {
			g.logger.Error("Unknown message type", msg)
			continue
		}
		selectByOriginOrg := g.peersByOriginOrgPolicy(discovery.NetworkMember{PKIid: msg.GetAliveMsg().Membership.PkiId})
		selector := filter.CombineRoutingFilters(selectByOriginOrg, func(member discovery.NetworkMember) bool {
			return msg.filter(member.PKIid)
		})
		peers2Send := filter.SelectPeers(g.conf.PropagatePeerNum, g.disc.GetMembership(), selector)
		g.sendAndFilterSecrets(msg.SignedGossipMessage, peers2Send...)
	}
}

// 转发Forward
// 节点在 GossipServer 启动的时候会调用 acceptMessages 用于消息的处理(向消息pub 注册一个包含过滤规则的sub, 从网络中获取各个节点发来的消息), 最终调用 channel.handleMessage
func (g *Node) handleMessage(m protoext.ReceivedMessage) {
    ...
	msg := m.GetGossipMessage()
	if !g.validateMsg(m) {
		g.logger.Warning("Message", msg, "isn't valid")
		return
	}

	if protoext.IsChannelRestricted(msg.GossipMessage) {
        // 判断 channel 是否匹配
		} else {
			if protoext.IsLeadershipMsg(m.GetGossipMessage().GossipMessage) {
				// LeadershipMsg 合法性校验
				}
            }
            // 处理 channel message
			gc.HandleMessage(m)
		}
		return
	}

	if selectOnlyDiscoveryMessages(m) {
        // 连接相关的消息，合法性判断后转交给 discoverServer 处理，处理逻辑见上文
		g.forwardDiscoveryMsg(m)
	}

    // 处理 pull 消息，稍后分析
	if protoext.IsPullMsg(msg.GossipMessage) && protoext.GetPullMsgType(msg.GossipMessage) == pg.PullMsgType_IDENTITY_MSG {
		g.certStore.handleMessage(m)
	}
}

// HandleMessage processes a message sent by a remote peer, 也会存储收到供之后使用
func (gc *gossipChannel) HandleMessage(msg protoext.ReceivedMessage) {
    ...
    // 各种检验，org id， channel id， org in channel
    ...
    // 处理 Pull 逻辑，稍后分析 
    ...
	if protoext.IsDataMsg(m.GossipMessage) || protoext.IsStateInfoMsg(m.GossipMessage) {
		added := false
		if protoext.IsDataMsg(m.GossipMessage) {
			...
            // 合法性验证
            ...
			gc.Lock()
			added = gc.blockMsgStore.Add(msg.GetGossipMessage())
			if added {
				gc.logger.Debugf("Adding %v to the block puller", msg.GetGossipMessage())
				gc.blocksPuller.Add(msg.GetGossipMessage())
			}
			gc.Unlock()
		} else { // StateInfoMsg verification should be handled in a layer above
			//  since we don't have access to the id mapper here
			added = gc.stateInfoMsgStore.Add(msg.GetGossipMessage())
		}

		if added {
			// 转发消息
			gc.Forward(msg)
			// DeMultiplex to local subscribers
			gc.DeMultiplex(m)
		}
		return
	}

    ... 
    // 处理拉取到的 block
    ...
    
	if protoext.IsLeadershipMsg(m.GossipMessage) {
		// Handling leadership message
		added := gc.leaderMsgStore.Add(m)
		if added {
			gc.DeMultiplex(m)
		}
	}
}

```

2. pull 所有节点周期性(默认4s)的随机选取 k 个（默认配置=3）个节点，向它们获取数据。Fabric中gossip协议pull操作如下：

``` 
    Other peer				   			                    Initiator
	 O	    <-------- Hello <NONCE> -------------------------       O
	/|\	    --------- Digest <[3,5,8, 10...], NONCE> -------->     /|\
	 |	    <-------- Request <[3,8], NONCE> -----------------      |
    / \	    --------- Response <[item3, item8], NONCE>------->     / \
```    

###  orderer 广播区块到全网

排序节点只需要将区块分发给每个组织中的 leader 节点，由组织的 leader 负责分发到其他节点

```golang
# 节点在 initGossipService() 时会 初始化 deliveryFactor，当节点加入channel时会通过 deliveryFactor 创建 deliver client
func (g *GossipService) InitializeChannel(channelID string, ordererSource *orderers.ConnectionSource, store *transientstore.Store, support Support) {
	...
	// 没有 deliveryService， 创建与 ordererSource 相连的 deliver client
	if g.deliveryService[channelID] == nil {
		g.deliveryService[channelID] = g.deliveryFactory.Service(g, ordererSource, g.mcs, g.serviceConfig.OrgLeader)
	}

	// Delivery service might be nil only if it was not able to get connected to the ordering service
	if g.deliveryService[channelID] != nil {
		// 不能同时为 true
		// 默认 true ,动态选取leader算法
		leaderElection := g.serviceConfig.UseLeaderElection
		// 默认 false
		isStaticOrgLeader := g.serviceConfig.OrgLeader

		if leaderElection {
			g.leaderElection[channelID] = g.newLeaderElectionComponent(channelID, g.onStatusChangeFactory(channelID,
				support.Committer), g.metrics.ElectionMetrics)
		} else if isStaticOrgLeader {
			g.deliveryService[channelID].StartDeliverForChannel(channelID, support.Committer, func() {})
		} 
		...
}

// 开启 Deliver For Channel
func (d *deliverServiceImpl) StartDeliverForChannel(chainID string, ledgerInfo blocksprovider.LedgerInfo, finalizer func()) error {
	...
	dc := &blocksprovider.Deliverer{...}
	...
	d.blockProviders[chainID] = dc
	go func() {
		// 查询本地账本，获取seekInfo，与orderer 创建 deliverClient 发送seekInfo， 获取resp, 一顿操作后提交到本地正本，然后将其分发(gossip)到其他peer
		dc.DeliverBlocks()
		// Yield, 切换leader逻辑
		finalizer()
	}()
	return nil
}
```


