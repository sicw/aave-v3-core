aave 是去中心化 Defi 协议，用户可以在上面存款、贷款、闪电贷等。主要是依靠算法保障系统运行。官网https://aave.com。  
下面是以 V3 版本进行分析。

# 1、存款

以在银行存款进行举例，我们将现金存入银行账户, 然后会给我们一个存储凭证。同样的我们将自己的资金转到 aave 协议中，aave 会给我们 1:1 mint aToken 做为凭证。

## 1.1、存款流程

存款整体分两步

- 将用户的资产转移到 aave 中
- aave 给用户 mint aToken

```js
    // 1. 将资金从user转给aave的aToken中
    IERC20(params.asset).safeTransferFrom(msg.sender, reserveCache.aTokenAddress, params.amount);

    // 2. 给用户1:1的mint aToken
    bool isFirstSupply = IAToken(reserveCache.aTokenAddress).mint(
      msg.sender,
      params.onBehalfOf,
      params.amount,
      reserveCache.nextLiquidityIndex
    );
```

## 1.2、存款利率

在银行存款都是有利息的，利率是固定的比如: 1 年定期 2%、3 年定期 2.5%等。在 aave 中存款的利率是和资金使用率相关的，也就是与资金池中的钱被借出去多少有关，借出去的越多，贷款利息越高，对应的存储收益越高。所以存款利率是由资金使用率和借款利率决定的。  
下图是借款利率，分两个阶段。以资金最佳使用率 80%做为分界线(80%的存款都借出去了)。最高借款利率达 79%。

### 1.2.1 借款利率计算

资金使用率为 40% 小于 80% 在第一阶段 利率 = 基本利率 + $$\frac{40\%}{80\%}$$ _ 4%  
资金使用率为 90% 大于 80% 在第二阶段 利率 = 基本利率 + 4% + $$\frac{90\% - 80\%}{20\%}$$ _ 75%

![image.png](https://img.learnblockchain.cn/attachments/2023/11/Y4DVqEkE6565c39cc9551.png)
图 1

### 1.2.2 存款利率计算

存款利率 = 流动性利率 = 资金使用率 _ 借款利率 = $$\frac{借出去的钱}{总存储的钱}$$ _ $$\frac{借出去的钱产生的利息}{借出去的钱}$$ = $$\frac{借出去的钱产生的利息}{总存储的钱}$$  
它的含义就是每存入一份钱，可产生的收益。

aavev3 计算存款收益率代码如下:

```
    vars.currentLiquidityRate = _getOverallBorrowRate(  // 借款利率
      params.totalStableDebt,
      params.totalVariableDebt,
      vars.currentVariableBorrowRate,
      params.averageStableBorrowRate
    ).rayMul(vars.supplyUsageRatio).percentMul(         // 资金使用率
        // 预留金, 应对客户提款和其他风险, 比如最多90%的资金使用率
        PercentageMath.PERCENTAGE_FACTOR - params.reserveFactor
      );
```

## 1.3、计算用户余额

用户余额 = 用户存入的钱 + 产生的利息

![image.png](https://img.learnblockchain.cn/attachments/2023/11/saReDbcY65673df9569c4.png)
下面举一个例子看下  
比如要获取 t2 时刻的用户余额

### 1.3.1 v1 版本

b2 = m + $$\frac{m*r}{1 year seconds}$$_(t2 - t1) = m_[1 +$$\frac{r}{1 year seconds}$$* (t2 - t1) ]  
可以看出在 t2 时刻的余额等于 m 乘以一个系数，这个系数只与 t1 时刻的利率和时间间隔有关。  
为了方便计算，aave 使用'累计流动性指数'字段来保存这个系数的乘积，在每次更新合约状态时都会累计。  
在 t1 时刻，累计流动性指数 = q  
在 t3 时刻，累计流动性指数 = p  
那么$$\frac{p}{q}$$ 等于上面 m 乘以的系数  
在 t3 时刻，用户余额 b3 = m \* $$\frac{p}{q}$$  
这种方式需要合约记录用户在 t1 时刻的'累计流动性指数'所以需要一个 map<address, int256>结构，这也是 aaveV1 版本的计算存储方式
aaveV1 AToken 代码如下

```
// 用户存款时的累计指数
mapping (address => uint256) private userIndexes;

function calculateCumulatedBalanceInternal(
    address _user,
    uint256 _balance
) internal view returns (uint256) {
    return _balance  // 上次操作后的余额
        .wadToRay()
        .rayMul(core.getReserveNormalizedIncome(underlyingAssetAddress)) // 计算自从上次操作到现在的利息
        .rayDiv(userIndexes[_user])  // 除以之前累计的流动性指数
        .rayToWad();
}
```

### 1.3.2 v2v3 版本

观察上面的 b3 = m _ $$\frac{p}{q}$$,可以在简化下,用户在 t1 时刻存入 m 资金,这时 q 是已知的。那直接存储$$\frac{m}{q}$$的值。在 t3 时刻计算用户余额时直接乘以 p 就可以了。  
b3 = $$\frac{m}{q}$$ _ p  
这个$$\frac{m}{q}$$也叫流动性缩放余额，这也是在 aaveV2、V3 中使用的计算方式，这样做有个好处时可以去掉 userIndexes 的存储降低 gas 费。  
aaveV3 代码如下

```
  // 存储时用缩放余额
  function _mintScaled(
    address caller,
    address onBehalfOf,
    uint256 amount,
    uint256 index
  ) internal returns (bool) {
    // 存储的amount数量除以流动性指数
    uint256 amountScaled = amount.rayDiv(index);
    require(amountScaled != 0, Errors.INVALID_MINT_AMOUNT);
  }

  function balanceOf(
    address user
  ) public view virtual override(IncentivizedERC20, IERC20) returns (uint256) {
    // 计算用户余额时直接乘以当前指数即可
    return super.balanceOf(user).rayMul(POOL.getReserveNormalizedIncome(_underlyingAsset));
  }
```

# 2、取款

我们到银行取款拿着凭证输入密码取出现金。同样的在 aave 中取款时，使用 aToken 做为凭证取回我们存入的资产。  
取回资产后资金池的总量发生了变化，导致资金使用率发生变化，贷款利率发生变换，存储利率发生变化。所以需要重新计算贷款利率、存款利率。  
贷款利率(根据上图 1 计算)，代码如下:

```
    // 如果资金使用率大于80%
    if (vars.borrowUsageRatio > OPTIMAL_USAGE_RATIO) {
      uint256 excessBorrowUsageRatio = (vars.borrowUsageRatio - OPTIMAL_USAGE_RATIO).rayDiv(
        MAX_EXCESS_USAGE_RATIO
      );
      // 稳定利率
      vars.currentStableBorrowRate +=
        _stableRateSlope1 +
        _stableRateSlope2.rayMul(excessBorrowUsageRatio);
      // 可变利率
      vars.currentVariableBorrowRate +=
        _variableRateSlope1 +
        _variableRateSlope2.rayMul(excessBorrowUsageRatio);
    } else {
      // 资金使用率小于等于80%
      vars.currentStableBorrowRate += _stableRateSlope1.rayMul(vars.borrowUsageRatio).rayDiv(
        OPTIMAL_USAGE_RATIO
      );
      vars.currentVariableBorrowRate += _variableRateSlope1.rayMul(vars.borrowUsageRatio).rayDiv(
        OPTIMAL_USAGE_RATIO
      );
    }
```

# 3、借款

在 aave 协议中贷款利率分两种，稳定利率和可变利率。  
稳定利率: 在借入资产后到归还借款的这段时间都是按照借入时的利率计算，不论中间有多少次存款、借款操作导致资金使用率变化。(如果贷款利率比存款利率还低会被官方强制 rebalance)。  
可变利率: 其他用户的存款、借款会导致资金的使用率变化，这就会导致借款利率发生变化，可变利率就是当其他用户改变资金利率用时，以当时的借款利率计算利息累计和。
借款条件：在银行借款需要有一定的条件，比如要有稳定的工作，稳定的居住所，民事偿还能力，这样就可以无需抵押借款。但是在去中心化里它本身就是匿名，隐藏个人信息，所以无法提供信用贷。  
在 aave 中只需要你存储的资产价值>你要贷款的资产价值即可，也就是超额抵押。比如你存储了价值 1000eth 的资产，但是你只能贷款 800eth 的另一种资产。  
这里存在一个问题，既然是超额抵押那就说明了我有超过 800eth 的资产，那我为啥还有贷款呢，直接兑换成想要的货币不就行了。
有几个使用情况:  
1、比如我有 1000eth，存入 aave 可以赚利息，同时我再借出 800eth 做其他投资赚取额外收益。
2、我有好多币种，存储在 aave 中赚取利息并且很看好它们的未来趋势不想售卖，但是又急需另一种币度应对短暂的问题。

## 3.1、利息的计算方式

存款和可变利率借款的存储计算方式一样，都是通过累计指数与缩放余额计算。
但它俩利息的计算方式不同，借款是复利计算, 存款是单利计算。  
比如在 t1-t2 时间段内，本金 m，利率是 r，最终余额是不一样的。

### 3.1.1 单利计算

b = m + $$\frac{m*r}{1 year seconds}$$ \* (t2 - t1)

### 3.1.1 复利计算

可以做个简单推导

```
利率 R = 5%
本金 b0 = 10000元
复利周期:天
求: 存3天后的的余额
```

R = 5%
b0 = 10000 元

b1= $ \frac{\left(b0\cdot\ R\right)}{365} _ 1 + b0$ => b0 _ $(\frac{R}{365}+1)$

b2= $ \frac{\left(b1\cdot\ R\right)}{365} _ 1 + b1$ => b1 _ $(\frac{R}{365}+1)$

b3= $ \frac{\left(b2\cdot\ R\right)}{365} _ 1 + b2$ => b2 _ $(\frac{R}{365}+1)$

b3 = b0 \* R<sub>3</sub>

b3 = b0 \* $(\frac{R}{365}+1)^{3}$

所以在 t1-t2 时间段内的余额如下
b = m \* $(\frac{r}{1 year seconds}+1)^{t2-t1}$
aaveV3 合约代码:

```
    function calculateCompoundedInterest(uint256 _rate, uint40 _lastUpdateTimestamp) internal view returns (uint256)
    {
        // 距离上次操作的时间间隔
        uint256 timeDifference = block.timestamp.sub(uint256(_lastUpdateTimestamp));
        // 年化利率转化成秒级利率
        uint256 ratePerSecond = _rate.div(SECONDS_PER_YEAR);
        // 本金增加的倍数, 再乘以本金就是余额
        return ratePerSecond.add(WadRayMath.ray()).rayPow(timeDifference);
    }
```

## 3.2、稳定利率

稳定利率计算余额时需要用户初始借款时的利率，无论后面怎么变都以当时的利率计算利息，代码如下：

```
  function balanceOf(address account) public view virtual override returns (uint256) {
    // 计算上次操作后的本金
    uint256 accountBalance = super.balanceOf(account);
    // 上次操作后的稳定利率
    uint256 stableRate = _userState[account].additionalData;
    if (accountBalance == 0) {
      return 0;
    }
    // 输入参数: 稳定利率, 上次时间戳
    // 输出: 该时间段内利息增长指数
    uint256 cumulatedInterest = MathUtils.calculateCompoundedInterest(
      stableRate,
      _timestamps[account]
    );
    // 再乘以本金 = 当前余额
    return accountBalance.rayMul(cumulatedInterest);
  }
```

## 3.2 超额抵押

aave 协议中借款使用的是超额抵押，比如你想借价值 800eth 的资产，需要存储价值 1000eth 的资产到协议中。在贷款时会遍历所有资金池看用户是否有足够的抵押。代码如下

```
function calculateUserAccountData(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    mapping(uint8 => DataTypes.EModeCategory) storage eModeCategories,
    DataTypes.CalculateUserAccountDataParams memory params
  ) internal view returns (uint256, uint256, uint256, uint256, uint256, bool) {
    // 遍历所有资产，累计抵押资产
    // ...中间略
    // 健康度计算
    vars.healthFactor = (vars.totalDebtInBaseCurrency == 0)
      ? type(uint256).max
      : (vars.totalCollateralInBaseCurrency.percentMul(vars.avgLiquidationThreshold)).wadDiv(
        vars.totalDebtInBaseCurrency
      );
    return (
      vars.totalCollateralInBaseCurrency,
      vars.totalDebtInBaseCurrency,
      vars.avgLtv,
      vars.avgLiquidationThreshold,
      vars.healthFactor,
      vars.hasZeroLtvCollateral
    );
```

# 4、还款

在还贷款时, 是要先还利息, 可以先还部分资金。还款之后资金使用率发生变化, 需要重新计算借贷利率。

# 5 隔离资产

官方设置的一些资金池不允许无限借款, 与公共参数和模式隔离开。
对于用户: 存入资产有贷款上线, 资金池不会被借空。当我想用资金时可快速赎回 而不是等到有人还款在取回。

对于资金池: 资金池有带框上限, 可以很好的保护存储用户。

被隔离的资产风险系数比较高, 或者出问题影响比较大。隔离的资产都有个借款上限(使用该资产做为抵押品最多能借多少美元) 使用隔离的资产做抵押品时 只能借入稳定币。

用户想要用该资产进行抵押，做借款时。会有一些要求。
有几个关键点:

1. 隔离资产有借入贷款上限(使用该资产最多能借入多少$)
2. 使用隔离资产 只能借入由官方指定的稳定币
3. 隔离资产是官方投票得出来的

# 6 EMode 模式

不同资产的利率，清算阈值，价格不一样。相当于在贷款时有高 中 低多种风险可用。
高效模式中, ltv 从 73% -> 90% 贷款能力提升 风险系数也变高了。
当抵押品和借入的资产有相关性时, 比如 usdt dai usdc 都和美元锚定, 如果美元跌了 usdt dai usdc 都会跌。这种情况下在计算健康度时也不会下降太多$$\frac{接入资产价值}{抵押资产价值*LTV}$$ 所以这种情况下 LTV 可以提升一些, 清算阈值、手续费都有优化 这样可以提升贷款能力。
目前有两种类型
*稳定币
*ETH 相关

# 7、清算

清算一种资金
先偿还借款，然后将抵押金转给清算人。
清算人最多归还一个借入资产的 50%, 并且获得一个抵押资产的清算奖金。
存入 10eth, 借入价值 5eth 的 dai. 在清算时 只能清算 50%的 dai 奖金是清算价值的 5% 也就是 2.5eth \* 5% = 0.125eth 所以清算人一共获得 2.5eth + 0.125eth

存入 5 eth 和 价值 5 eth 的 fyi, 借入 5eth 价值的 dai。在清算时 归还 50%的 dai, fyi 的清算奖金是 15% eth 清算奖金是 5%, 所以选用 fyi 的奖金(只能选一种) 2.5eth \* 0.15 = 0.375eth 所以 清算人一共会得到价值 2.5eth + 0.375eth 价值的 fyi 资产

# 8、闪电贷

在一个交易中, 完成借款和还款。同时提供一些交易手续费。
用户实现自定义合约, 然后用户发送交易到 aave 合约, 将控制权交给 aave 闪电贷合约, 在闪电贷合约中将资金转移给用户，然后再调用户自定义的合约, 调用完成后检查状态，将用户贷款转附带利息转给 aave。如果这中间发生异常则终止交易。

# 9、跨链桥

在 arib 链中的资金转移到 eth 网络上。

swap token 兑换
使用 uniswap 进行兑换

Q&A
1、可不可以在利率高的时候使用稳定利率存款啊
2、如果想要取回大量资金, 资金池不够怎么办
3、在没有贷款时，存款是否有利率
4、预留 10%的准备金, 是可以在借款时最多接 90%么, 如果资金全部被借出去, 好像也没问题 在借款时没有限制保留 10%啊?
5、如果用户存款后, 资金池被届空了, 用户着急用资金该如何取回?

银行存款 aave 存款

![image.png](https://img.learnblockchain.cn/attachments/2023/11/URCFMsKV6565bb3bec7e2.png)

贷款

![image.png](https://img.learnblockchain.cn/attachments/2023/11/NeBRKL6W6565bddf72a99.png)

# 图示概览

## 存款、取款、贷款、还款资金流

用户存储资产到池子中, 其他用户从池子中贷款资产, 并使用另一种货币做超额抵押。贷款期间会产生一定的利息。当用户取回资产时会赚取一定的利息费用。

![image.png](https://img.learnblockchain.cn/attachments/2023/10/mSlPMm8k6523f2da1d22a.png)

## 清算流程

当抵押的资产不足贷款时(ETH 降价), 会产生清算。将抵押资产卖出, 归还贷款。

![image.png](https://img.learnblockchain.cn/attachments/2023/10/XEjDmsC56523f320e712e.png)

### aaveV1 计算方式

![image.png](https://img.learnblockchain.cn/attachments/2023/11/TyyTTvq56565a0b67f890.png)

### aaveV2 计算方式

![image.png](https://img.learnblockchain.cn/attachments/2023/11/CPsrfTVr6565a077099be.png)
