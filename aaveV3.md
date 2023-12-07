介绍: aave 是去中心化 Defi 协议，用户可以在上面存款、贷款、闪电贷等。主要是依靠算法保障系统运行。官网: https://aave.com  
下面是以 aave V3 版本进行分析。

#1、存款
以在银行存款进行举例，我们将现金存入银行账户, 然后会给我们一个存储凭证。同样的我们将自己的资金转到 aave 协议中，aave 会给我们 1:1 mint aToken 做为凭证。  
##1.1、存款流程  
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

##1.2、存款利率
在银行存款都是有利息的，利率是固定的比如: 1 年定期 2%、3 年定期 2.5%等。在 aave 中存款的利率是和资金使用率相关的，也就是与资金池中的钱被借出去多少有关，借出去的越多，贷款利息越高，对应的存储收益越高。所以存款利率是由资金使用率和借款利率决定的。  
下图是借款利率，分两个阶段。以资金最佳使用率 80%做为分界线(80%的存款都借出去了)。最高借款利率达 79%。  
###1.2.1 借款利率计算  
资金使用率为 40% 小于 80% 在第一阶段 利率 = 基本利率 + $$\frac{40\%}{80\%}$$ _ 4%  
资金使用率为 90% 大于 80% 在第二阶段 利率 = 基本利率 + 4% + $$\frac{90\% - 80\%}{20\%}$$ _ 75%

![image.png](https://img.learnblockchain.cn/attachments/2023/11/Y4DVqEkE6565c39cc9551.png)
图 1
###1.2.2 存款利率计算  
存款利率 = 流动性利率 = 资金使用率 _ 借款利率 = $$\frac{借出去的钱}{总存储的钱}$$ _ $$\frac{借出去的钱产生的利息}{借出去的钱}$$ = $$\frac{借出去的钱产生的利息}{总存储的钱}$$  
它的含义就是每存入一份钱，可产生的收益。

aave v3 计算存款收益率代码如下:

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

##1.3、计算用户余额
用户余额 = 用户存入的钱 + 产生的利息

![image.png](https://img.learnblockchain.cn/attachments/2023/11/saReDbcY65673df9569c4.png)
下面举一个例子看下  
比如要获取 t2 时刻的用户余额

### 1.3.1 aave V1 版本

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

### 1.3.2 aave V2 V3 版本

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

#2、取款
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

#3、借款
在 aave 协议中贷款利率分两种，稳定利率和可变利率。  
稳定利率: 在借入资产后到归还借款的这段时间都是按照借入时的利率计算，不论中间有多少次存款、借款操作导致资金使用率变化。(如果贷款利率比存款利率还低会被官方强制 rebalance)。  
可变利率: 其他用户的存款、借款会导致资金池的使用率变化，就会导致借款利率发生变换，可变利率的借款利息是每个阶段的利率累计算出来的。
借款条件：在银行贷款需要有一定的条件 稳定的工作，居住地址，民事偿还能力。在 aave 协议中没有这多条件, 只需要你存储的资产价值 > 你要贷款的资产价值即可, 也就是超额抵押。比如你存储了价值 1000eth 的资产, 但是你只能贷款 800eth 的资产。这里存在一个问题，既然是超额抵押 那就说明了我有超过 800eth 的资产，那我为啥还有贷款呢，直接兑换成想要的货币不就行了。

1. 比如我有 1000eth, 存入 aave 可以赚利息, 在贷款出 800eth 做其他投资专赚取收益.
2. 我有好多币种, 存储在 aave 中赚取利息 并且很看好它们的未来趋势不想售卖, 但是又急需另一种币, 这时可以短期借入其他资产来应对困难。

在 aave 中借款利息计算是复利方式
在上面存款中, 计算存款余额时 b = 本金 + 利息, 借款利息也是一样的。
可变利率计算方式与存款计算方式一样, 只不过借款利率是复利计算方式, 存款利率是线性计算方式。
在 t1 - t2 时间段内, 本金 m, 利率是 r 利息是不一样的
线性计算：
本金 + 利息 = m + $$\frac{m*r}{1 year seconds}$$ \* (t2 - t1)

复合计算：
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

所以在 t1~t2 时间段内的余额如下
本金 + 利息 = m \* $(\frac{r}{1 year seconds}+1)^{t2-t1}$
合约代码:

```
    function calculateCompoundedInterest(uint256 _rate, uint40 _lastUpdateTimestamp) internal view returns (uint256)
    {
        // 距离上次操作的时间间隔
        uint256 timeDifference = block.timestamp.sub(uint256(_lastUpdateTimestamp));
        // 年化利率转化成秒级利率
        uint256 ratePerSecond = _rate.div(SECONDS_PER_YEAR);
        // 本金增加的倍数, 再乘以m就是本金+利息
        return ratePerSecond.add(WadRayMath.ray()).rayPow(timeDifference);
    }
```

说完计算方式, 我们再看下稳定利率和可变利率的不同。
可变利率借款与存款利率计算逻辑相同, 每次操作都会 '累计贷款利息指数'。在借入贷款时同样使用缩放余额存储。

稳定利率有些特殊, 稳定利率需要保存用户初始借款时的利率, 无论后面怎么变都以当时的利率计算利息

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
    // 乘以本金 = 当前余额
    return accountBalance.rayMul(cumulatedInterest);
  }
```

aave 协议中贷款使用的是超额抵押贷款, 比如你想借价值 800eth 的资产, 你需要存储价值 1000eth 的资产到协议中。在贷款时会遍历所有资金池看用户是否有足够的抵押。
计算用户数据

```
function calculateUserAccountData(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    mapping(uint8 => DataTypes.EModeCategory) storage eModeCategories,
    DataTypes.CalculateUserAccountDataParams memory params
  ) internal view returns (uint256, uint256, uint256, uint256, uint256, bool) {
    if (params.userConfig.isEmpty()) {
      return (0, 0, 0, 0, type(uint256).max, false);
    }
    CalculateUserAccountDataVars memory vars;
    // 开启了EMode模式, 有自定义的LTV, 清算阈值, 货币价格
    if (params.userEModeCategory != 0) {
      (vars.eModeLtv, vars.eModeLiqThreshold, vars.eModeAssetPrice) = EModeLogic
        .getEModeConfiguration(
          eModeCategories[params.userEModeCategory],
          IPriceOracleGetter(params.oracle)
        );
    }

    // 遍历所有资金池
    while (vars.i < params.reservesCount) {
      // 用户是否允许用该资产作为抵押
      if (!params.userConfig.isUsingAsCollateralOrBorrowing(vars.i)) {
        unchecked {
          ++vars.i;
        }
        continue;
      }
      vars.currentReserveAddress = reservesList[vars.i];
      if (vars.currentReserveAddress == address(0)) {
        unchecked {
          ++vars.i;
        }
        continue;
      }
      DataTypes.ReserveData storage currentReserve = reservesData[vars.currentReserveAddress];
      (
        vars.ltv, // 贷款抵押比
        vars.liquidationThreshold, // 清算阈值
        ,
        vars.decimals, // 资产精度
        ,
        vars.eModeAssetCategory // eMode类型
      ) = currentReserve.configuration.getParams();
      unchecked {
        vars.assetUnit = 10 ** vars.decimals;
      }
      // 获取当前货币价格
      vars.assetPrice = vars.eModeAssetPrice != 0 &&
        params.userEModeCategory == vars.eModeAssetCategory
        ? vars.eModeAssetPrice // 从eMode获取价格
        : IPriceOracleGetter(params.oracle).getAssetPrice(vars.currentReserveAddress);

      if (vars.liquidationThreshold != 0 && params.userConfig.isUsingAsCollateral(vars.i)) {
        vars.userBalanceInBaseCurrency = _getUserBalanceInBaseCurrency(
          params.user,
          currentReserve,
          vars.assetPrice,
          vars.assetUnit
        );

        // 累计抵押的资产价值
        vars.totalCollateralInBaseCurrency += vars.userBalanceInBaseCurrency;
        vars.isInEModeCategory = EModeLogic.isInEModeCategory(
          params.userEModeCategory,
          vars.eModeAssetCategory
        );

        if (vars.ltv != 0) {
          vars.avgLtv +=
            vars.userBalanceInBaseCurrency *
            (vars.isInEModeCategory ? vars.eModeLtv : vars.ltv);
        } else {
          vars.hasZeroLtvCollateral = true;
        }
        vars.avgLiquidationThreshold +=
          vars.userBalanceInBaseCurrency *
          (vars.isInEModeCategory ? vars.eModeLiqThreshold : vars.liquidationThreshold);
      }

      // 该资产允许做为借款
      if (params.userConfig.isBorrowing(vars.i)) {
        // 累计用户贷款该资产的价值, 累计到一起就是该用户在aaveV3中的所有贷款的价值
        vars.totalDebtInBaseCurrency += _getUserDebtInBaseCurrency(
          params.user,
          currentReserve,
          vars.assetPrice,
          vars.assetUnit
        );
      }

      unchecked {
        ++vars.i;
      }
    }

    unchecked {
      vars.avgLtv = vars.totalCollateralInBaseCurrency != 0
        ? vars.avgLtv / vars.totalCollateralInBaseCurrency
        : 0;

      vars.avgLiquidationThreshold = vars.totalCollateralInBaseCurrency != 0
        ? vars.avgLiquidationThreshold / vars.totalCollateralInBaseCurrency
        : 0;
    }

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

隔离资产
官方设置的一些资金池不允许无限借款, 与公共参数和模式隔离开。
对于用户: 存入资产有贷款上线, 资金池不会被借空。当我想用资金时可快速赎回 而不是等到有人还款在取回。

对于资金池: 资金池有带框上限, 可以很好的保护存储用户。

这个存入两种资产界面
![image.png](https://img.learnblockchain.cn/attachments/2023/12/3OkOwuXZ656c82141b69d.png)

只存入一种隔离资产
![image.png](https://img.learnblockchain.cn/attachments/2023/12/W7LLXY5o656c8299ce572.png)

开启隔离模式
![image.png](https://img.learnblockchain.cn/attachments/2023/12/w7zj0Gkm656c87bc79cc6.png)

已开启隔离模式
![image.png](https://img.learnblockchain.cn/attachments/2023/12/rdnen6ra656c883cd7430.png)

处于隔离模式后再存入 DAI 币, 默认不可作为抵押
![image.png](https://img.learnblockchain.cn/attachments/2023/12/aWFsOwZS656c8993eb1f6.png)

关闭隔离模式
![image.png](https://img.learnblockchain.cn/attachments/2023/12/ffQQh0o2656c8ac8cb955.png)

开启 DAI 资产做为抵押品
![image.png](https://img.learnblockchain.cn/attachments/2023/12/HI8HmtTP656c8b10154af.png)

当处于隔离模式时, 存入的普通资产不能作为抵押品, 页面也不能点选。
当普通资产做为抵押品时, 同样不能将隔离资产做为抵押品，页面不能点选。

存入抵押 DAI 借出 USDC
![image.png](https://img.learnblockchain.cn/attachments/2023/12/RSR9llZb656c8d1beb315.png)

借出后又可以抵押 USDC 了
![image.png](https://img.learnblockchain.cn/attachments/2023/12/JKrBdUW7656c8d75e694a.png)

归还 USDC, 但是这里我借入 1usdc, 归还时还是 1usdc 没有利息么？
应该是资产的精度是 6 位, 产生的利息还没有达到最小精度
![image.png](https://img.learnblockchain.cn/attachments/2023/12/0xpLgpOj656c8dc2891c1.png)

被隔离的资产风险系数比较高, 或者出问题影响比较大。隔离的资产都有个借款上限(使用该资产做为抵押品最多能借多少美元) 使用隔离的资产做抵押品时 只能借入稳定币。

用户想要用该资产进行抵押，做借款时。会有一些要求。
有几个关键点:

1. 隔离资产有借入贷款上限(使用该资产最多能借入多少$)
2. 使用隔离资产 只能借入由官方指定的稳定币
3. 隔离资产是官方投票得出来的

EMode 模式
不同资产的利率，清算阈值，价格不一样。相当于在贷款时有高 中 低多种风险可用。
高效模式中, ltv 从 73% -> 90% 贷款能力提升 风险系数也变高了。
当抵押品和借入的资产有相关性时, 比如 usdt dai usdc 都和美元锚定, 如果美元跌了 usdt dai usdc 都会跌。这种情况下在计算健康度时也不会下降太多$$\frac{接入资产价值}{抵押资产价值*LTV}$$ 所以这种情况下 LTV 可以提升一些, 清算阈值、手续费都有优化 这样可以提升贷款能力。
目前有两种类型
*稳定币
*ETH 相关

#4、还款
在还贷款时, 是要先还利息, 可以先还部分资金。还款之后资金使用率发生变化, 需要重新计算借贷利率。

#5、清算
清算一种资金
先偿还借款，然后将抵押金转给清算人。
清算人最多归还一个借入资产的 50%, 并且获得一个抵押资产的清算奖金。
存入 10eth, 借入价值 5eth 的 dai. 在清算时 只能清算 50%的 dai 奖金是清算价值的 5% 也就是 2.5eth \* 5% = 0.125eth 所以清算人一共获得 2.5eth + 0.125eth

存入 5 eth 和 价值 5 eth 的 fyi, 借入 5eth 价值的 dai。在清算时 归还 50%的 dai, fyi 的清算奖金是 15% eth 清算奖金是 5%, 所以选用 fyi 的奖金(只能选一种) 2.5eth \* 0.15 = 0.375eth 所以 清算人一共会得到价值 2.5eth + 0.375eth 价值的 fyi 资产

#6、闪电贷
在一个交易中, 完成借款和还款。同时提供一些交易手续费。
用户实现自定义合约, 然后用户发送交易到 aave 合约, 将控制权交给 aave 闪电贷合约, 在闪电贷合约中将资金转移给用户，然后再调用户自定义的合约, 调用完成后检查状态，将用户贷款转附带利息转给 aave。如果这中间发生异常则终止交易。

#7、跨链桥
在 arib 链中的资金转移到 eth 网络上。

swap token 兑换
使用 uniswap 进行兑换

Q&A
1、可不可以在利率高的时候使用稳定利率存款啊
2、如果想要取回大量资金, 资金池不够怎么办
3、在没有贷款时，存款是否有利率
4、预留 10%的准备金, 是可以在借款时最多接 90%么, 如果资金全部被借出去, 好像也没问题 在借款时没有限制保留 10%啊?
5、如果用户存款后, 资金池被届空了, 用户着急用资金该如何取回?

出个 prd

存款方式:
无定期
都是活期存款,

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

## 基本利率计算

利率与池子中的资金使用率有关, 使用率越高(借出去的越多)利率越高。具体采用分段计算。
当使用率小于等于最优使用率时 2.5% + 4.5% _ 使用率百分比
当使用率大于最优使用率时 2.5% + 4.5% + 6.5% _ 使用率百分比

![image.png](https://img.learnblockchain.cn/attachments/2023/10/bZrfJ3dU6523f34be8c9b.png)

# 利息计算逻辑

## 例子

### 线性利率(存款利率)

按照时间和利率等比计算

```
背景1: 存款10000元到银行, 年化利率5%.
求: 存50天后的的余额
```

![image.png](https://img.learnblockchain.cn/attachments/2023/10/Gx7k9r1Z65276f5519550.png)

b0 = 10000 元

b1 = $ \frac{\left(5\%\ \cdot\ b0\right)}{365} \* 50\ +\ b0$

b1 = b0 \* [$ \frac{\left(5\%\ \cdot\ 50\right)}{365} \ +\ 1$]

b1= b0 \* R1

R<sub>1</sub> = $ \frac{\left(5\%\ \cdot\ 50\right)}{365}\ +\ 1$

```
背景2: 取出b1, 然后本息再次存储, 年化为4%
求: 30天后的余额
```

b2 = $ \frac{\left(4\%\ \cdot\ b1\right)}{365} \* 30\ +\ b1$

b2= b1 \* [$ \frac{\left(4\%\ \cdot\ 30\right)}{365} \ +\ 1$]

b2= b1 \* R2

R<sub>2</sub>= $ \frac{\left(4\%\ \cdot\ 30\right)}{365}\ +\ 1$

b2=b0 _ R1 _ R2

b2=b0 \* Rt

R<sub>t</sub> = R<sub>2</sub> \* R<sub>1</sub>

R<sub>t</sub> = ($ \frac{\left(4\%\ \cdot\ 30\right)}{365}\ +\ 1$) \* R<sub>t-1</sub>

R<sub>t</sub> = $(\frac{R \cdot △T}{365}+1)$ \* R<sub>t-1</sub>

R<sub>t</sub>含义: △T 时间段内收益率

线性计算代码

```
    function calculateLinearInterest(uint256 _rate, uint40 _lastUpdateTimestamp) internal view returns (uint256)
    {
        //solium-disable-next-line
        uint256 timeDifference = block.timestamp.sub(uint256(_lastUpdateTimestamp));

        uint256 timeDelta = timeDifference.wadToRay().rayDiv(SECONDS_PER_YEAR.wadToRay());

        return _rate.rayMul(timeDelta).add(WadRayMath.ray());
    }

function getNormalizedIncome(CoreLibrary.ReserveData storage _reserve) internal view returns (uint256)
    {
        uint256 cumulated = calculateLinearInterest(_reserve.currentLiquidityRate, _reserve.lastUpdateTimestamp
        ).rayMul(_reserve.lastLiquidityCumulativeIndex);
        return cumulated;
    }

```

### 复合利率(贷款利率)

按照时间和利率等比计算, 每天本金都要加上前一天的利息

```
背景1: 存款10000元到银行, 年化利率5%
求: 存3天后的的余额
```

R = 5%
b0 = 10000 元

b1= $ \frac{\left(b0\cdot\ R\right)}{365} _ 1 + b0$ => b0 _ $(\frac{R}{365}+1)$

b2= $ \frac{\left(b1\cdot\ R\right)}{365} _ 1 + b1$ => b1 _ $(\frac{R}{365}+1)$

b3= $ \frac{\left(b2\cdot\ R\right)}{365} _ 1 + b2$ => b2 _ $(\frac{R}{365}+1)$

b3 = b0 \* R<sub>3</sub>

b3 = b0 \* $(\frac{R}{365}+1)^{3}$

```
背景2: 取出b3, 然后本息再次存储, 年化为4%
求: 2天后的余额
```

R = 4%

b4= $ \frac{\left(b3\cdot\ R\right)}{365} _ 1 + b3$ => b3 _ $(\frac{R}{365}+1)$

b5= $ \frac{\left(b4\cdot\ R\right)}{365} _ 1 + b4$ => b4 _ $(\frac{R}{365}+1)$

b5 = b3 \* $(\frac{R}{365}+1)^{2}$

b5 = b0 _ $(\frac{R}{365}+1)^{3}$ _ $(\frac{R}{365}+1)^{2}$

b5 = b0 \* R<sub>t</sub>

R<sub>t</sub> = $(\frac{R}{365}+1)^{△T}$ \* R<sub>t-1</sub>

复合计算代码

```
    function calculateCompoundedInterest(uint256 _rate, uint40 _lastUpdateTimestamp) internal view returns (uint256)
    {
        //solium-disable-next-line
        uint256 timeDifference = block.timestamp.sub(uint256(_lastUpdateTimestamp));

        uint256 ratePerSecond = _rate.div(SECONDS_PER_YEAR);

        return ratePerSecond.add(WadRayMath.ray()).rayPow(timeDifference);
    }


    function updateCumulativeIndexes(ReserveData storage _self) internal {
        uint256 totalBorrows = getTotalBorrows(_self);

        if (totalBorrows > 0) {
            // 计算累计线性利率
            //only cumulating if there is any income being produced
            uint256 cumulatedLiquidityInterest = calculateLinearInterest(
                _self.currentLiquidityRate,
                _self.lastUpdateTimestamp
            );
            _self.lastLiquidityCumulativeIndex = cumulatedLiquidityInterest.rayMul(
                _self.lastLiquidityCumulativeIndex
            );

            // 计算累计复合利率
            uint256 cumulatedVariableBorrowInterest = calculateCompoundedInterest(
                _self.currentVariableBorrowRate,
                _self.lastUpdateTimestamp
            );
            _self.lastVariableBorrowCumulativeIndex = cumulatedVariableBorrowInterest.rayMul(
                _self.lastVariableBorrowCumulativeIndex
            );
        }
    }
```

### 流动性利率

U = $\frac{借出去的钱}{总存储入的钱}$ (借款使用率)

R<sub>o</sub> = $\frac{借出去的钱产生的利息}{借出去的钱}$ (总借贷利率)

R<sub>l</sub> = U \* R<sub>o</sub>

R<sub>l</sub> = $\frac{借出去的钱}{总存储入的钱}$ \* $\frac{借出去的钱产生的利息}{借出去的钱}$

R<sub>l</sub> = $\frac{借出去的钱产生的利息}{总存储入的钱}$

含义: 存入这么多钱可产生这么多利息

### 存款流程

### 取款流程

### 借款流程

### 还款流程

### 清算流程

### 闪电贷流程

### token 兑换

### aaveV1 计算方式

![image.png](https://img.learnblockchain.cn/attachments/2023/11/TyyTTvq56565a0b67f890.png)

### aaveV2 计算方式

![image.png](https://img.learnblockchain.cn/attachments/2023/11/CPsrfTVr6565a077099be.png)

# 例子分析

## 1. 以 blocknumber 9241423 为例, 分析下 dai 币资产数据。

已知

```
totalLiquidity:2619274103475205556991 (wad)
availableLiquidity:1619274103475205556991 (wad)
totalBorrowsStable:0
totalBorrowsVariable:1000000000000000000000 (wad)
variableBorrowRate:33861572913303013691138106(ray)

liquidityRate:12927846256478499344798900
```

求证 liquidityRate
R<sub>l</sub> = $\frac{1000000000000000000000 * 33861572913303013691138106}{2619274103475205556991}$

R<sub>l</sub> = 12927846256478499344798899

相关代码

```
    function calculateInterestRates(
        address _reserve,
        uint256 _availableLiquidity,
        uint256 _totalBorrowsStable,
        uint256 _totalBorrowsVariable,
        uint256 _averageStableBorrowRate
    )
        external
        view
        returns (
            uint256 currentLiquidityRate,
            uint256 currentStableBorrowRate,
            uint256 currentVariableBorrowRate
        )
    {
        // 总借款 = 稳定利率借款 + 可变利率借款
        uint256 totalBorrows = _totalBorrowsStable.add(_totalBorrowsVariable);

        // 借款使用率
        uint256 utilizationRate = (totalBorrows == 0 && _availableLiquidity == 0)
            ? 0
            : totalBorrows.rayDiv(_availableLiquidity.add(totalBorrows));

        // 稳定利率
        currentStableBorrowRate = ILendingRateOracle(addressesProvider.getLendingRateOracle())
            .getMarketBorrowRate(_reserve);


        // 大于最优使用率
        if (utilizationRate > OPTIMAL_UTILIZATION_RATE) {
            uint256 excessUtilizationRateRatio = utilizationRate
                .sub(OPTIMAL_UTILIZATION_RATE)
                .rayDiv(EXCESS_UTILIZATION_RATE);

            currentStableBorrowRate = currentStableBorrowRate.add(stableRateSlope1).add(
                stableRateSlope2.rayMul(excessUtilizationRateRatio)
            );
            currentVariableBorrowRate = baseVariableBorrowRate.add(variableRateSlope1).add(
                variableRateSlope2.rayMul(excessUtilizationRateRatio)
            );
        } else { // 小于等于最优使用率
            currentStableBorrowRate = currentStableBorrowRate.add(
                stableRateSlope1.rayMul(
                    utilizationRate.rayDiv(
                        OPTIMAL_UTILIZATION_RATE
                    )
                )
            );
            currentVariableBorrowRate = baseVariableBorrowRate.add(
                utilizationRate.rayDiv(OPTIMAL_UTILIZATION_RATE).rayMul(variableRateSlope1)
            );
        }

        //  计算平均借款利率
        currentLiquidityRate = getOverallBorrowRateInternal(
            _totalBorrowsStable,
            _totalBorrowsVariable,
            currentVariableBorrowRate,
            _averageStableBorrowRate
        )
        // 乘以资产使用率
            .rayMul(utilizationRate);

        // 最终得出流动性利率
    }

```

# 以我当前账户为例, 看看各项数据是如何计算出来的。

![image.png](https://img.learnblockchain.cn/attachments/2023/11/vxZkKunM6565a21bd1826.png)

在每次对资产操作前要更新相关指数, 后面用来计算利率使用。

1. 在某个时间段内累计收益率(**线性**)
   C<sub>I</sub> = (R<sub>l</sub> _ △T<sub>year</sub> + 1) _ C<sub>I</sub><sup>t-1</sup>

2. 可变利率借贷累计指数(**复合**)
   B<sup>t</sup><sub>vc</sub> = $(\frac{R}{T}+1)^{△T}$ \* B<sup>t-1</sup><sub>vc</sub>

## 2. 求某个用户在存储一天内产生的利息

用户: 0x5d3183cB8967e3C9b605dc35081E5778EE462328
余额: 2500000035869690114215
C<sub>I</sub><sup>t-1</sup> = 1 ray
一天后
余额: 2500088578662464619259
求证:
(0.12927846256478499344798900 _ $\frac{60 _ 60 _ 24}{365 Day senconds}$ + 1) _ 1 ray _ 2500000035869690114215 = 2.5008855 _ 10<sup>21</sup>
