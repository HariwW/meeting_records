## 来自牛客的部分三面面经

### 计费组
#### 1. 实习遇到的难题，如何解决？
可以讲ES宽表建设中对于局部有序性的问题。

##### 业务主键保证同一分区
把消息 key 设为业务主键（coupon_id / user_id / entitlement_id 等），并在消息中携带单调递增的版本字段（binlog commit_ts、binlog pos 或业务版本号）。

##### 在 ES 侧使用外部版本控制（简洁、靠 ES 保证幂等）
Elasticsearch 支持 version + version_type=external，消费者把 binlog 的增量 version（例如 commit_ts）作为版本号索引文档，ES 只会在外部版本比现有版本 大 时替换文档。

``` bash
PUT /coupons/_doc/{id}?version=1697623456000&version_type=external
{
  "id": "...",
  "amount": 100,
  "updated_at": "2025-10-17T12:34:16Z",
  ...
}

```

典型做法：消费者在接到消息后，先在轻量外部状态存储（比如 Redis）做原子比较并更新：只有当 incoming_version > stored_version 时才继续写 ES。用 Redis Lua 脚本保证比较+写入版本的原子性。

##### 外部轻量存储+计算
``` lua
-- KEYS[1] = "ver:entitlement:{id}"
-- ARGV[1] = incoming_version
local cur = redis.call("GET", KEYS[1])
if not cur or tonumber(ARGV[1]) > tonumber(cur) then
  redis.call("SET", KEYS[1], ARGV[1])
  return 1
end
return 0
```
消费流程：

1. 收到消息（id, version, payload）

2. 调 Redis Lua（比较并尝试写入版本）

3. 如果返回 1 → 写入 ES（普通 upsert 或 index）

3. 如果返回 0 → 丢弃或记录为过期消息

这个也同时需要做一些补偿
##### 外部轻量存储+服务段计算
redis缓存更新的时间，每次需要更新时，去redis中访问得到最新的快照时间，然后根据业务类型判断是否需要更新。


#### 2. 注册中心会遇到什么难点？
##### 服务注册与发现的延迟问题
- 问题：注册中心需要处理大量服务的注册与注销请求，尤其在大规模的微服务架构中，注册中心的负载会非常高。如果服务数量非常庞大，可能会出现服务注册与发现的延迟，影响服务间的通信和调用。

- 解决方案：采用高效的注册中心，如 Consul、etcd、Zookeeper，这些工具都具备高性能、高可用的特点，并且提供了心跳检测来确保服务健康状态。

##### 服务一致性问题
- 问题：在分布式环境下，注册中心需要确保服务数据的一致性。由于网络分区、节点故障等原因，可能会导致注册中心的数据不同步，甚至出现“服务丢失”的情况。

- 解决方案：可以采用 分布式一致性协议（如 Paxos 或 Raft）来保证注册中心的强一致性。比如 Zookeeper 就通过 ZAB（Zookeeper Atomic Broadcast）协议来保证数据一致性。

##### 注册中心的高可用性
- 问题：注册中心本身作为微服务架构的核心组件之一，如果注册中心宕机或无法访问，所有的服务发现和负载均衡功能都会受到影响，导致系统不可用。

- 解决方案：需要保证注册中心的高可用性，通常会使用 多节点部署、主备切换、故障转移 等方式，确保即使某个注册中心节点宕机，其他节点依然能够提供服务。

##### 口头回答版本
注册中心作为分布式系统中的关键组件，主要负责服务注册与发现。在实际应用中，可能会面临以下几个难点：

服务一致性：由于分布式系统的复杂性，注册中心需要保证服务注册信息的强一致性。在网络分区或节点宕机的情况下，如何确保数据一致性是一个挑战。使用分布式一致性协议，如 Raft 或 Paxos，可以有效保证这一点。

高可用性：注册中心的宕机会导致服务发现功能不可用，因此需要保证注册中心的高可用性。一般通过 多节点部署 和 故障转移 来确保系统的可靠性。

性能瓶颈：随着服务数量的增加，注册中心的负载可能会成为瓶颈，影响服务注册与发现的速度。为了解决这个问题，可以采用 分布式部署 和 数据分片 等策略来提升性能。

健康检查与服务下线：服务的健康状态需要实时监控，确保不可用的服务能够及时下线。通过 心跳机制 或 定期健康检查 来实现这一点，可以有效减少系统的故障传播。

总的来说，注册中心的设计和实现必须兼顾高可用性、一致性和性能，才能保证分布式系统的稳定运行。”

##### 结合CAP理论进行介绍
在理论计算机科学中，CAP 定理（CAP theorem）指出对于一个分布式系统来说，当设计读写操作时，只能同时满足以下三点中的两个：
- 一致性（Consistency） : 所有节点访问同一份最新的数据副本
- 可用性（Availability）: 非故障的节点在合理的时间内返回合理的响应（不是错误或者超时的响应）。
- 分区容错性（Partition Tolerance） : 分布式系统出现网络分区的时候，仍然能够对外提供服务。

##### 进一步发展

BASE 是 Basically Available（基本可用）、Soft-state（软状态） 和 Eventually Consistent（最终一致性） 三个短语的缩写。BASE 理论是对 CAP 中一致性 C 和可用性 A 权衡的结果，其来源于对大规模互联网系统分布式实践的总结，是基于 CAP 定理逐步演化而来的，它大大降低了我们对系统的要求
- Basically Available（基本可用）：基本可用基本可用是指分布式系统在出现不可预知故障的时候，允许损失部分可用性。但是，这绝不等价于系统不可用。什么叫允许损失部分可用性呢？响应时间上的损失: 正常情况下，处理用户请求需要 0.5s 返回结果，但是由于系统出现故障，处理用户请求的时间变为 3 s。系统功能上的损失：正常情况下，用户可以使用系统的全部功能，但是由于系统访问量突然剧增，系统的部分非核心功能无法使用。
- Soft-state（软状态）：软状态指允许系统中的数据存在中间状态（CAP 理论中的数据不一致），并认为该中间状态的存在不会影响系统的整体可用性，即允许系统在不同节点的数据副本之间进行数据同步的过程存在延时。
- 最终一致性：最终一致性强调的是系统中所有的数据副本，在经过一段时间的同步后，最终能够达到一个一致的状态。因此，最终一致性的本质是需要系统保证最终数据能够达到一致，而不需要实时保证系统数据的强一致性。

##### 一致性的不同等级
- 强一致性：系统写入了什么，读出来的就是什么。
- 弱一致性：不一定可以读取到最新写入的值，也不保证多少时间之后读取到的数据是最新的，只是会尽量保证某个时刻达到数据一致的状态。
- 最终一致性：弱一致性的升级版，系统会保证在一定时间内达到数据一致的状态。


#### 3. 服务熔断和降级如何考虑和实现的？
- 服务熔断：服务熔断是指在某个服务调用出现异常时，自动中断对该服务的调用，防止故障蔓延到其他服务，并及时恢复服务。当系统检测到某个服务频繁失败时，通过“熔断”机制来避免继续对该服务的调用，给系统一些时间恢复，避免出现连锁反应。

- 服务降级：服务降级是指当系统某个服务无法正常响应时，系统会返回 默认值 或 备用方案，以保证用户能够继续体验服务。降级机制用于减少对服务的压力，避免因为某个服务不可用导致整个系统的崩溃。

#### 4.如何应对服务假死的问题？
服务“假死”通常指的是服务仍然在运行，但无法正常处理请求，或者响应时间异常长，导致用户体验极差，但系统未完全崩溃，依然对外提供服务。假死现象通常发生在系统资源被过度占用、某个组件死锁、网络问题、服务实例间的依赖出现瓶颈等情况下。

监控与检测：及时发现服务异常，监控系统的关键指标（响应时间、错误率、资源利用等）。

故障隔离与熔断：通过熔断器、限流等机制来隔离故障，避免问题蔓延。

自动恢复：通过重启、重试、容错与降级策略来自动恢复服务。

预防机制：优化资源管理、负载均衡、分布式设计等，从根本上降低服务假死的概率。

#### 5.C语言和Go了解吗？
- C语言 是一个低级语言，适合系统级编程，提供了直接的内存访问，适用于性能要求极高的应用程序，尤其在 操作系统、嵌入式开发 中有着广泛应用。

- Go语言 则是为现代互联网应用而设计的语言，特别是在分布式系统和微服务中，Go的并发编程能力使其在云计算、容器化环境中非常流行。它的简洁语法和自动内存管理，适合快速开发高并发、高性能的网络应用。

对比表格:
| 特性       | C语言             | Go语言               |
| -------- | --------------- | ------------------ |
| **开发效率** | 较低，需要手动管理内存、指针等 | 高，内存管理自动化，语法简洁     |
| **并发支持** | 无内建并发支持，需使用线程等  | 内建并发支持（goroutines） |
| **内存管理** | 手动管理内存，容易出现内存泄漏 | 自动垃圾回收（GC）         |
| **性能**   | 高性能，接近底层操作      | 性能优异，接近C语言         |
| **适用场景** | 系统编程、嵌入式、操作系统开发 | Web服务、分布式系统、云原生开发  |
| **生态系统** | 非常成熟，库多，跨平台开发困难 | 新兴生态，特别适用于云原生、微服务  |


#### 6. 给了一个C语言结构体，计算多少字节
- 常规字节数

char: 1bytes
int: 4 bytes
float: 4 bytes
double: 8 bytes

- 考虑字节对齐

C语言中的每个数据类型通常都有对齐要求（alignment requirements）。为了提高内存访问效率，编译器可能会插入填充字节（padding），确保每个成员按照其对齐要求放置在内存中。

- 禁止使用对齐

方式1：
``` C++
#include <stdio.h>

#pragma pack(push, 1)  // 设置对齐为 1 字节
struct Example {
    char a;   // 1 byte
    int b;    // 4 bytes
    char c;   // 1 byte
};
#pragma pack(pop)  // 恢复默认对齐

int main() {
    printf("Size of struct: %zu bytes\n", sizeof(struct Example));
    return 0;
}

```

方式2：
``` C++
#include <stdio.h>

struct __attribute__((packed)) Example {
    char a;   // 1 byte
    int b;    // 4 bytes
    char c;   // 1 byte
};

int main() {
    printf("Size of struct: %zu bytes\n", sizeof(struct Example));
    return 0;
}

```

#### 7.介绍一下动态规划和回溯？
- 动态规划

动态规划是一种通过将原问题分解为子问题来求解的技术，特别适用于解决 最优化问题。通过记住（通常使用记忆化表格）已经求解过的子问题的结果，避免了重复计算，从而提高了算法效率。

动态规划求解步骤

定义状态：确定需要记录哪些信息（状态转移的变量），这些信息通常表示一个子问题的解。

状态转移方程：确定如何通过已解决的子问题来构建当前问题的解。

边界条件：确定最小子问题的解（即递归的基础情况）。

求解顺序：有时是自顶向下的递归（记忆化），有时是自底向上的迭代。

- 回溯

回溯是一种 递归 的算法思想，它用于寻找所有可能的解，并且通过 剪枝（即提前终止不可能的分支）来提高效率。回溯算法通常用于 组合问题、排列问题、图搜索问题，尤其在解空间非常庞大的问题中表现出色。

1，3，5面值的硬币若干，用上面两种算法分别口述思路。
0-1背包问题

动态规划解法：
``` java
import java.util.Arrays;

public class CoinChange01 {

    public static int minCoins(int[] coins, int target) {
        // 创建一个数组 dp，dp[i] 表示金额 i 的最小硬币数
        int[] dp = new int[target + 1];
        
        // 初始化 dp 数组，设为一个较大的数（表示无法凑成该金额）
        Arrays.fill(dp, Integer.MAX_VALUE);
        
        // 0 元不需要硬币
        dp[0] = 0;
        
        // 遍历硬币
        for (int coin : coins) {
            // 这里是 0-1 背包问题，必须从后往前遍历
            for (int i = target; i >= coin; i--) {
                // 如果当前金额 i >= coin，尝试选择 coin
                if (dp[i - coin] != Integer.MAX_VALUE) {
                    dp[i] = Math.min(dp[i], dp[i - coin] + 1);
                }
            }
        }
        
        // 如果 dp[target] 仍然是 Integer.MAX_VALUE，表示无法凑成该金额
        return dp[target] == Integer.MAX_VALUE ? -1 : dp[target];
    }

    public static void main(String[] args) {
        // 硬币面值
        int[] coins = {1, 3, 5};
        // 目标金额
        int target = 11;
        
        // 求解最少硬币数
        int result = minCoins(coins, target);
        
        if (result == -1) {
            System.out.println("无法凑成目标金额！");
        } else {
            System.out.println("最少需要的硬币数：" + result);
        }
    }
}

```
回溯解法：
``` java
public class CoinChangeBacktrackingOnce {

    private static int minCoins = Integer.MAX_VALUE;

    // 回溯函数
    public static void backtrack(int[] coins, int target, int currentAmount, int coinCount, boolean[] used) {
        // 如果当前金额等于目标金额
        if (currentAmount == target) {
            minCoins = Math.min(minCoins, coinCount);
            return;
        }
        
        // 如果当前金额已经超过目标金额，回溯
        if (currentAmount > target) {
            return;
        }
        // 递归选择每一种硬币
        for (int i = 0; i < coins.length; i++) {
            // 如果硬币已经使用过，跳过
            if (used[i]) continue;
            
            // 标记硬币已使用
            used[i] = true;
            
            // 递归调用，选择当前硬币
            backtrack(coins, target, currentAmount + coins[i], coinCount + 1, used);
            
            // 回溯，恢复硬币的状态
            used[i] = false;
        }
    }
 
    public static int minCoins(int[] coins, int target) {
        minCoins = Integer.MAX_VALUE;  // 重置最小硬币数
        boolean[] used = new boolean[coins.length]; // 用于标记硬币是否已使用
        backtrack(coins, target, 0, 0, used); // 从 0 元开始，0 个硬币
        return minCoins == Integer.MAX_VALUE ? -1 : minCoins;
    }

    public static void main(String[] args) {
        // 硬币面值
        int[] coins = {1, 3, 5};
        // 目标金额
        int target = 11;
        
        // 求解最少硬币数
        int result = minCoins(coins, target);
        
        if (result == -1) {
            System.out.println("无法凑成目标金额！");
        } else {
            System.out.println("最少需要的硬币数：" + result);
        }
    }
}

```
#### 7.回溯能否进一步剪枝？
提前终止递归：当当前金额已经大于目标金额时，直接停止递归。

硬币排序：按硬币面值从大到小排序，这样可以优先尝试大面额的硬币。大面额的硬币可以更快地达到目标金额，减少递归的深度。

最优解的早期发现：在递归时，我们可以根据当前使用的硬币数与已有的最小硬币数 minCoins 进行比较。如果当前的硬币数已经超过 minCoins，可以停止继续探索当前路径，避免不必要的递归调用。

递归深度的控制：如果当前硬币组合已经无法达到最优解，递归就可以提前终止。比如，如果当前硬币数量已经大于当前最优解 minCoins，则可以直接剪枝。


算法题：符串压缩，写完问有没有比O(n)还好的算法。


### unknow1
#### 1. Redis 用于做什么
Redis 的优势：

1. 性能高：Redis 作为内存数据库，具有非常快的读写速度，支持每秒数百万次操作。

2. 丰富的数据结构：Redis 支持字符串、列表、集合、哈希、有序集合等多种数据结构，能够满足不同的应用需求。

3. 支持持久化：尽管是内存数据库，Redis 支持将数据持久化到磁盘，并有两种持久化方式。

4. 高可用性和分布式支持：

5. Redis Sentinel 提供了高可用性和自动故障转移功能。

6. Redis Cluster 提供了数据分片和高可用支持，使 Redis 在大规模分布式环境下表现优越。

适用场景总结：

1. 高并发应用：例如缓存、会话管理、排行榜等。

2. 消息队列：支持生产者-消费者模型、发布-订阅模型。

3. 实时数据处理：如计数器、事件处理、实时统计等。

4. 分布式系统：如分布式锁、分布式缓存、分布式队列等。

#### 2. Redis 集群结构，哨兵选举流程

1. 集群

- Redis 集群将 16384 个哈希槽均匀分配到多个主节点上。

- 每个主节点负责一部分哈希槽，客户端根据键的哈希值来决定数据存储在哪个主节点上。

- 当一个节点的哈希槽出现负载过高时，Redis 集群支持动态的 槽迁移，可以将一些槽转移到其他节点上，保证负载均衡。

2. 哨兵模式

- 哨兵通过持续监控主节点的状态，检测到主节点失效。

- 哨兵进行选举，选出一个从节点成为新的主节点。

- 新的主节点开始接管写请求并同步数据。

- 哨兵通知客户端，告知其连接的主节点已经发生变化。

#### 3. Zookeeper 底层是否了解，Zookeeper 选举流程

Zookeeper 是一个开源的分布式协调框架，它提供了分布式锁、配置管理、服务发现、集群管理等功能。它在分布式系统中用于协调不同节点的操作，确保系统的一致性和高可用性。Zookeeper 的核心是基于 ZAB 协议（Zookeeper Atomic Broadcast） 来保证分布式系统中数据的强一致性。

Zookeeper 的底层实现基于 ZAB 协议，通过 Leader 选举 机制确保分布式系统中的一致性和高可用性。选举过程通过事务 ID 和节点 ID 机制保证了 Leader 节点的正确选举，并且能够在 Leader 故障时自动恢复，确保集群在高并发环境下的稳定性和可靠性。

#### 4. 交卷和阅卷功能为什么要用消息队列或线程池，流程设计思想

- 消息队列：

解耦交卷与阅卷的操作。

提高系统吞吐量，减少因并发请求导致的压力。

异步处理，避免系统阻塞。

提供可靠的任务处理机制（如失败重试、优先级处理）。

-  线程池：

管理并发任务，避免创建大量临时线程造成系统资源浪费。

控制任务执行的最大线程数，避免线程过多导致系统崩溃。

提供任务执行监控，确保任务的稳定性。

提高系统的吞吐量和响应能力。

#### 5. 如果线程池或者消息队列挂掉，怎么保证一定阅卷

通过 消息队列 和 线程池 的结合使用，能够提供任务的异步执行、高并发处理和容错机制。在系统出现故障时，可以通过以下手段保证 阅卷任务 的执行：

消息队列：确保任务不会丢失，通过持久化、冗余、重试机制确保任务的可靠传输。

线程池：保证并发任务的高效执行，并通过合理的拒绝策略和监控机制应对线程池故障。

故障恢复机制：系统会及时重启故障的组件，保证系统尽可能快速恢复并继续处理任务。

#### 4. 如果线程池或消息队列挂掉，此时用户又发出大量的查询请求，怎么保证服务不被冲垮掉

##### 1. 限流

限流 是一种防止服务过载的手段，尤其是在高并发情况下。如果线程池或消息队列挂掉，系统需要通过限流控制请求的流入量，防止服务因请求过多而崩溃。

- 基于令牌桶进行限流
- 基于漏桶（Leaky Bucket）算法
- 滑动窗口

##### 2. 熔断
熔断 是一种 容错机制，当某个服务或组件出现故障时，熔断器会阻止进一步的请求进入该服务，避免故障扩散，保护系统的稳定性。

- 当 线程池 或 消息队列 出现问题时，熔断器会开启，所有向该组件发起的请求会被 快速失败（例如返回 500 错误或者定制的“服务不可用”响应），避免请求在故障服务上等待，减少延迟。

- 熔断器通过设定阈值（如失败次数、失败率、持续时间等）来判断是否开启。当熔断器处于打开状态时，可以通过回退机制（如调用缓存数据或提供简化服务）保证系统的基本可用性。


##### 3.降级
降级 是另一种保护措施，当某个服务或组件不可用时，可以采取 降级策略，例如返回缓存数据、简化处理逻辑或返回预定义的默认值。

- 缓存回退：如果消息队列挂掉或线程池繁忙，可以从 缓存系统（如 Redis、Memcached）中查询数据，减少对后端服务的依赖。

- 静态数据返回：在无法获取实时数据时，返回某个固定的默认响应或静态数据，如展示“服务正在维护中”或返回最近的缓存数据。

- 简化处理：当无法执行复杂操作时，提供更简化的查询接口，只执行轻量级的计算。

##### 4. 请求队列和缓冲
请求队列与缓冲：将请求缓存在队列中，待系统恢复后按序处理。

##### 5. 微服务架构

通过服务拆分与微服务架构分散负载，提高系统弹性和扩展性

#### 5. 有没有关注什么开源框架
SupaBase + prisma-AI

### unknown2
#### 1. KV 存储如何容错：
KV 存储系统通过数据复制和冗余来实现容错。常见的做法是将数据分布到多个节点上，并使用副本机制（如复制因子）来保证数据不丢失。例如，基于 Raft 或 Paxos 协议的分布式 KV 存储会在不同节点之间维护数据的一致性，并在节点发生故障时自动恢复数据。

#### 2. Raft leader 选举：
Raft 是一种一致性算法，用于管理分布式系统中的日志复制。Raft 的 Leader 选举机制是通过多数节点投票来选举出一个 Leader。每个节点都有一个任期（term），Leader 由一个任期内的节点选举产生。当一个节点未收到心跳信号时，它会发起选举，节点会投票给自己或其他候选人，直到一个节点获得超过半数的投票并成为 Leader。

#### 3. Raft 如何高可用：
Raft 通过保证每个日志条目的复制到多数节点来实现高可用性。即使一些节点失效，只要大多数节点正常，系统仍然可以保持一致性并继续工作。在节点故障后，Raft 会通过 Leader 选举确保系统始终有一个 Leader 进行决策。

#### 4. LSM tree 原理：
LSM（Log-Structured Merge Tree）是一种高效的写入优化数据结构，常用于 KV 存储系统（如 LevelDB）。它将写操作先记录到内存中的 MemTable，然后定期将 MemTable 的数据刷新到磁盘。磁盘上存储的数据被组织成多个层级，逐层合并（merge）以减少磁盘空间的使用和查找延迟。

#### 5. 正则表达式 * 和 ？的区别：

*：表示前面的字符可以重复零次或多次。例如，a* 匹配空字符串、a、aa 等。

?：表示前面的字符可以出现零次或一次。例如，a? 匹配空字符串或 a。

#### 6. 正则表达式 * 和 ？的区别：
环形链表是一种特殊的链表结构，其中最后一个节点的指针指向第一个节点，形成一个闭环。它常用于需要循环访问数据的场景，如操作系统中的任务调度、网络协议中的缓冲区管理等。

#### 7. 堆排序原理，和冒泡排序空间效率区别：

堆排序：堆排序是一种基于堆数据结构的排序算法，时间复杂度为 O(n log n)。它通过构建最大堆（或最小堆）来排序，通过不断取出堆顶元素并调整堆的结构实现排序。

冒泡排序：冒泡排序是一种简单的排序算法，通过相邻元素比较并交换的位置来逐步将最大（或最小）元素“冒泡”到序列的末尾。其时间复杂度为 O(n²)。

空间效率区别：堆排序是原地排序，只需要 O(1) 的额外空间；冒泡排序也是原地排序，空间复杂度为 O(1)。

UDP 和 TCP 的应用场景：

UDP：适用于需要快速传输、对实时性要求较高、且可以容忍丢包的场景，如视频流、语音通信、在线游戏等。

TCP：适用于要求可靠传输、数据完整性和顺序保证的场景，如文件传输、网页浏览、电子邮件等。
### unknown3
#### 1.用位运算判断奇偶数
``` java
public class OddEven {
    public static boolean isOdd(int n) {
        return (n & 1) != 0;  // 奇数返回 true，偶数返回 false
    }
    
    public static void main(String[] args) {
        System.out.println(isOdd(5));  // true
        System.out.println(isOdd(6));  // false
    }
}

```
2.一个整数对1024取模
``` java
public class Mod1024 {
    public static int mod1024(int n) {
        return n & 1023;  // 等价于 n % 1024
    }

    public static void main(String[] args) {
        System.out.println(mod1024(2048));  // 1024
    }
}

```
#### 2.任意的m对n取模，不能用除法和取模运算符
``` java
public class ModWithoutOperators {
    public static int modWithoutDivision(int m, int n) {
        while (m >= n) {
            m -= n;
        }
        return m;
    }

    public static void main(String[] args) {
        System.out.println(modWithoutDivision(2048, 1024));  // 0
        System.out.println(modWithoutDivision(1234, 100));   // 34
    }
}
```
#### 3.求m除n，保留k位小数，返回字符串形式
``` java
public class DivisionWithPrecision {
    public static String divideAndFormat(double m, double n, int k) {
        String format = "%." + k + "f";
        return String.format(format, m / n);
    }

    public static void main(String[] args) {
        System.out.println(divideAndFormat(5.0, 3.0, 2));  // 1.67
        System.out.println(divideAndFormat(10.0, 3.0, 3)); // 3.333
    }
}

```
#### 4.z字形矩阵生成
``` java
import java.util.*;

public class ZMatrix {
    public static int[][] generateZMatrix(int n, int m) {
        int[][] matrix = new int[n][m];
        int num = 1;

        for (int diag = 0; diag < n + m - 1; diag++) {
            if (diag % 2 == 0) {
                int x = Math.min(diag, n - 1);
                int y = diag - x;
                while (x >= 0 && y < m) {
                    matrix[x][y] = num++;
                    x--;
                    y++;
                }
            } else {
                int y = Math.min(diag, m - 1);
                int x = diag - y;
                while (y >= 0 && x < n) {
                    matrix[x][y] = num++;
                    x++;
                    y--;
                }
            }
        }

        return matrix;
    }

    public static void printMatrix(int[][] matrix) {
        for (int[] row : matrix) {
            for (int num : row) {
                System.out.print(num + " ");
            }
            System.out.println();
        }
    }

    public static void main(String[] args) {
        int[][] result = generateZMatrix(4, 5);
        printMatrix(result);
    }
}

```
#### 5.海量数据当中如何对敏感词过滤
``` java
import java.util.*;

class TrieNode {
    Map<Character, TrieNode> children = new HashMap<>();
    boolean isEndOfWord = false;
}

class Trie {
    TrieNode root = new TrieNode();

    public void insert(String word) {
        TrieNode node = root;
        for (char c : word.toCharArray()) {
            node.children.putIfAbsent(c, new TrieNode());
            node = node.children.get(c);
        }
        node.isEndOfWord = true;
    }

    public boolean search(String word) {
        TrieNode node = root;
        for (char c : word.toCharArray()) {
            node = node.children.get(c);
            if (node == null) {
                return false;
            }
        }
        return node.isEndOfWord;
    }
}

public class SensitiveWordFilter {
    public static String filterSensitiveWords(String text, List<String> sensitiveWords) {
        Trie trie = new Trie();
        for (String word : sensitiveWords) {
            trie.insert(word);
        }

        StringBuilder result = new StringBuilder();
        StringBuilder temp = new StringBuilder();

        for (char c : text.toCharArray()) {
            temp.append(c);
            if (trie.search(temp.toString())) {
                result.append("*".repeat(temp.length()));  // 用星号替代敏感词
                temp.setLength(0);  // 重置 temp
            } else {
                result.append(c);
            }
        }

        return result.toString();
    }

    public static void main(String[] args) {
        List<String> sensitiveWords = Arrays.asList("bad", "sensitive");
        String text = "This is a bad example with sensitive data.";

        System.out.println(filterSensitiveWords(text, sensitiveWords));
    }
}

```


### unknow4

#### 1.一个涉及加密解密的项目，深挖，加密怎么做的，密钥怎么存的，前后端都问了，如何保证密钥的安全，如何生成的密钥，前端如何做的，如何检测证书等等问题

加密如何实现：常见的加密方法包括对称加密（如 AES）、非对称加密（如 RSA）和哈希加密（如 SHA-256）。对称加密使用相同的密钥进行加密和解密，非对称加密使用公钥加密，私钥解密。

密钥存储：密钥可以存储在硬件安全模块（HSM）中、环境变量、配置文件中，或者使用密钥管理服务（KMS）进行管理。为了确保密钥安全，可以使用加密存储和密钥生命周期管理。

前端加密：前端加密常用的方法包括加密敏感信息（如用户密码）在发送到后端之前。前端可以使用 RSA 或 AES 加密库（例如，CryptoJS）。敏感数据可以通过 HTTPS（SSL/TLS）协议传输。

证书检测：可以通过公钥基础设施（PKI）来验证证书的有效性。前端和后端可以通过验证证书的签名链、证书吊销列表（CRL）等手段来确认证书的安全性。

#### 2.现在有一台服务器，一个DB实例，两张表，A表扣100块钱，B表加100块钱，如何实现事务
``` sql 
BEGIN TRANSACTION;

-- 先检查B表余额
IF (SELECT balance FROM B WHERE account_id = 2) >= 100 THEN
    -- 扣除A表100元
    UPDATE A SET balance = balance - 100 WHERE account_id = 1;
    
    -- 加入B表100元
    UPDATE B SET balance = balance + 100 WHERE account_id = 2;
    
    COMMIT;
ELSE
    ROLLBACK;
END IF;

```

#### 3.两张表在不同的DB实例，涉及分布式事务，用的什么语言，业务层怎么实现线程同步的，除了信号量还有什么，锁，那就实现一下吧，写一下简单的代码
在分布式事务中，涉及到两张表在不同的数据库实例中进行操作。可以使用一种分布式事务协调机制，如 2PC（两阶段提交） 或 TCC（Try-Confirm-Cancel）。

- 语言实现：可以使用 Java（Spring 支持分布式事务）、Python（使用分布式数据库事务库）等语言。

- 线程同步：除了信号量，线程同步的方式还有 锁（如 ReentrantLock）、条件变量、CountDownLatch 等。
ReentrantLock
``` java
public class DistributedTransaction {
    private final ReentrantLock lock = new ReentrantLock();

    public void executeTransaction() {
        lock.lock();
        try {
            // 执行分布式事务的操作
            // 例如更新两个数据库的记录
        } finally {
            lock.unlock();
        }
    }
}

```
CountDownLatch
``` java
import java.util.concurrent.CountDownLatch;

public class CountDownLatchExample {
    public static void main(String[] args) throws InterruptedException {
        int threadCount = 3;
        CountDownLatch latch = new CountDownLatch(threadCount);

        for (int i = 0; i < threadCount; i++) {
            new Thread(new Task(latch)).start();
        }

        latch.await();  // 等待所有线程完成
        System.out.println("All tasks are completed!");
    }
}

class Task implements Runnable {
    private final CountDownLatch latch;

    public Task(CountDownLatch latch) {
        this.latch = latch;
    }

    @Override
    public void run() {
        try {
            System.out.println(Thread.currentThread().getName() + " is working.");
            Thread.sleep(1000);
            latch.countDown();  // 每个线程执行完毕，减少 countDownLatch 的计数
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}

```
Semaphore
``` java
import java.util.concurrent.Semaphore;

public class SemaphoreExample {
    public static void main(String[] args) throws InterruptedException {
        Semaphore semaphore = new Semaphore(2);  // 最多允许 2 个线程同时访问

        for (int i = 0; i < 5; i++) {
            new Thread(new Task(semaphore)).start();
        }
    }
}

class Task implements Runnable {
    private final Semaphore semaphore;

    public Task(Semaphore semaphore) {
        this.semaphore = semaphore;
    }

    @Override
    public void run() {
        try {
            semaphore.acquire();  // 获取许可
            System.out.println(Thread.currentThread().getName() + " is working.");
            Thread.sleep(1000);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            semaphore.release();  // 释放许可
            System.out.println(Thread.currentThread().getName() + " is done.");
        }
    }
}

```

5.了解docker和k8s吗，用过，不太熟悉。
- Docker：容器化技术，能够将应用及其依赖打包到一个容器中，确保在任何环境中都能一致运行。Docker 提供了轻量级虚拟化的方式，能够快速构建和部署应用。

- Kubernetes：Kubernetes 是一个开源的容器编排平台，用于自动化部署、扩展和管理容器化应用。K8s 通过 Pod、Service、Deployment 等资源管理容器集群。

6.docker如何处理资源隔离的
Docker 通过以下方式实现资源隔离：

- 命名空间（Namespaces）：通过 Linux 命名空间隔离网络、进程、文件系统等。

- 控制组（Cgroups）：限制和隔离容器的 CPU、内存、磁盘和网络带宽等资源。

7.k8s pod是什么

在 Kubernetes 中，Pod 是部署和管理容器的最小单元。一个 Pod 可以包含一个或多个容器，它们共享网络和存储资源。Pod 里的容器通常紧密配合工作。

8.k8s pod和docker的容器什么关系

Pod 是 Kubernetes 的基本部署单元，它可以包含一个或多个 Docker 容器。每个 Pod 都运行在同一个节点上，容器共享相同的网络和存储。Docker 容器是 Pod 内部运行的容器。

9.linux用过吗，如何创建子进程，如何监听进程，命名管道和无名管道的区别

创建子进程：在 Linux 中，可以使用 fork() 系统调用创建子进程，exec() 可以用来执行新程序。

监听进程：可以使用 wait() 或 waitpid() 等函数来监听子进程的状态。

命名管道和无名管道：

- 命名管道（Named Pipe）：在文件系统中有路径，进程间可以通过该路径进行通信。

- 无名管道（Unnamed Pipe）：没有文件路径，通常用于父子进程或兄弟进程之间通信