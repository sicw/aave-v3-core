// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.10;

import {IERC20} from '../../../dependencies/openzeppelin/contracts//IERC20.sol';
import {GPv2SafeERC20} from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {PercentageMath} from '../../libraries/math/PercentageMath.sol';
import {WadRayMath} from '../../libraries/math/WadRayMath.sol';
import {Helpers} from '../../libraries/helpers/Helpers.sol';
import {DataTypes} from '../../libraries/types/DataTypes.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {ValidationLogic} from './ValidationLogic.sol';
import {GenericLogic} from './GenericLogic.sol';
import {IsolationModeLogic} from './IsolationModeLogic.sol';
import {EModeLogic} from './EModeLogic.sol';
import {UserConfiguration} from '../../libraries/configuration/UserConfiguration.sol';
import {ReserveConfiguration} from '../../libraries/configuration/ReserveConfiguration.sol';
import {IAToken} from '../../../interfaces/IAToken.sol';
import {IStableDebtToken} from '../../../interfaces/IStableDebtToken.sol';
import {IVariableDebtToken} from '../../../interfaces/IVariableDebtToken.sol';
import {IPriceOracleGetter} from '../../../interfaces/IPriceOracleGetter.sol';

/**
 * @title LiquidationLogic library
 * @author Aave
 * @notice Implements actions involving management of collateral in the protocol, the main one being the liquidations
 */
library LiquidationLogic {
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using ReserveLogic for DataTypes.ReserveCache;
  using ReserveLogic for DataTypes.ReserveData;
  using UserConfiguration for DataTypes.UserConfigurationMap;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using GPv2SafeERC20 for IERC20;

  // See `IPool` for descriptions
  event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user);
  event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user);
  event LiquidationCall(
    address indexed collateralAsset,
    address indexed debtAsset,
    address indexed user,
    uint256 debtToCover,
    uint256 liquidatedCollateralAmount,
    address liquidator,
    bool receiveAToken
  );

  /**
   * 在清算时要归还借款人贷款的百分比50%
   * @dev Default percentage of borrower's debt to be repaid in a liquidation.
   * @dev Percentage applied when the users health factor is above `CLOSE_FACTOR_HF_THRESHOLD`
   * Expressed in bps, a value of 0.5e4 results in 50.00%
   */
  uint256 internal constant DEFAULT_LIQUIDATION_CLOSE_FACTOR = 0.5e4;

  /**
   * 在清算时要归还借款人贷款的百分比100%
   * @dev Maximum percentage of borrower's debt to be repaid in a liquidation
   * @dev Percentage applied when the users health factor is below `CLOSE_FACTOR_HF_THRESHOLD`
   * Expressed in bps, a value of 1e4 results in 100.00%
   */
  uint256 public constant MAX_LIQUIDATION_CLOSE_FACTOR = 1e4;

  /**
   * @dev This constant represents below which health factor value it is possible to liquidate
   * an amount of debt corresponding to `MAX_LIQUIDATION_CLOSE_FACTOR`.
   * A value of 0.95e18 results in 0.95
   */
  uint256 public constant CLOSE_FACTOR_HF_THRESHOLD = 0.95e18;

  struct LiquidationCallLocalVars {
    uint256 userCollateralBalance;
    uint256 userVariableDebt;
    uint256 userTotalDebt;
    uint256 actualDebtToLiquidate;
    uint256 actualCollateralToLiquidate;
    uint256 liquidationBonus;
    uint256 healthFactor;
    uint256 liquidationProtocolFeeAmount;
    address collateralPriceSource;
    address debtPriceSource;
    IAToken collateralAToken;
    DataTypes.ReserveCache debtReserveCache;
  }

  /**
   * 1. 计算被清算人截止到现在所有贷款价值(ETH)
   * 2. 计算被清算人截止到现在所有抵押价值(ETH)
   * 3. 计算被清算人安全度, 是否可以被清算
   * 4. 清算人归还贷款
   * 5. 被清算人抵押资产转给清算人
   *
   * @notice Function to liquidate a position if its Health Factor drops below 1. The caller (liquidator)
   * covers `debtToCover` amount of debt of the user getting liquidated, and receives
   * a proportional amount of the `collateralAsset` plus a bonus to cover market risk
   * @dev Emits the `LiquidationCall()` event
   * @param reservesData The state of all the reserves
   * @param reservesList The addresses of all the active reserves
   * @param usersConfig The users configuration mapping that track the supplied/borrowed assets
   * @param eModeCategories The configuration of all the efficiency mode categories
   * @param params The additional parameters needed to execute the liquidation function
   */
  function executeLiquidationCall(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    mapping(address => DataTypes.UserConfigurationMap) storage usersConfig,
    mapping(uint8 => DataTypes.EModeCategory) storage eModeCategories,
    DataTypes.ExecuteLiquidationCallParams memory params
  ) external {
    LiquidationCallLocalVars memory vars;

    // 抵押资产地址是清算人传进来的, 一次清算只能操作被清算人的一种抵押资产
    DataTypes.ReserveData storage collateralReserve = reservesData[params.collateralAsset]; // 被清算人其中一个抵押资产数据
    DataTypes.ReserveData storage debtReserve = reservesData[params.debtAsset]; // 被清算人贷款数据
    DataTypes.UserConfigurationMap storage userConfig = usersConfig[params.user];

    vars.debtReserveCache = debtReserve.cache();

    // 更新贷款资金池流动性指数
    debtReserve.updateState(vars.debtReserveCache);

    // 计算被清算人账户数据(健康度)
    (, , , , vars.healthFactor, ) = GenericLogic.calculateUserAccountData(
      reservesData,
      reservesList,
      eModeCategories,
      DataTypes.CalculateUserAccountDataParams({
        userConfig: userConfig,
        reservesCount: params.reservesCount,
        user: params.user,
        oracle: params.priceOracle,
        userEModeCategory: params.userEModeCategory
      })
    );

    // 计算被清算人的稳定利率、可变利率贷款
    (vars.userVariableDebt, vars.userTotalDebt, vars.actualDebtToLiquidate) = _calculateDebt(
      vars.debtReserveCache,
      params,
      vars.healthFactor
    );

    // 校验是否可清算
    ValidationLogic.validateLiquidationCall(
      userConfig,
      collateralReserve,
      DataTypes.ValidateLiquidationCallParams({
        debtReserveCache: vars.debtReserveCache,
        totalDebt: vars.userTotalDebt,
        healthFactor: vars.healthFactor,
        priceOracleSentinel: params.priceOracleSentinel
      })
    );

    // 获取资产配置数据
    (
      vars.collateralAToken,
      vars.collateralPriceSource,
      vars.debtPriceSource,
      vars.liquidationBonus
    ) = _getConfigurationData(eModeCategories, collateralReserve, params);

    vars.userCollateralBalance = vars.collateralAToken.balanceOf(params.user);

    // 计算真实的抵押、贷款数量
    (
      vars.actualCollateralToLiquidate,
      vars.actualDebtToLiquidate,
      vars.liquidationProtocolFeeAmount
    ) = _calculateAvailableCollateralToLiquidate(
      collateralReserve,
      vars.debtReserveCache,
      vars.collateralPriceSource,
      vars.debtPriceSource,
      vars.actualDebtToLiquidate,
      vars.userCollateralBalance,
      vars.liquidationBonus,
      IPriceOracleGetter(params.priceOracle)
    );

    if (vars.userTotalDebt == vars.actualDebtToLiquidate) {
      // 说明都给偿还了
      userConfig.setBorrowing(debtReserve.id, false);
    }

    // If the collateral being liquidated is equal to the user balance,
    // we set the currency as not being used as collateral anymore
    if (
      vars.actualCollateralToLiquidate + vars.liquidationProtocolFeeAmount ==
      vars.userCollateralBalance
    ) {
      userConfig.setUsingAsCollateral(collateralReserve.id, false);
      emit ReserveUsedAsCollateralDisabled(params.collateralAsset, params.user);
    }

    // 燃烧被清算人的贷款token
    _burnDebtTokens(params, vars);

    // 更新贷款利率、流动性利率(归还贷款后资金使用率变化了)
    debtReserve.updateInterestRates(
      vars.debtReserveCache,
      params.debtAsset,
      vars.actualDebtToLiquidate,
      0
    );

    // 更新隔离贷款数据
    IsolationModeLogic.updateIsolatedDebtIfIsolated(
      reservesData,
      reservesList,
      userConfig,
      vars.debtReserveCache,
      vars.actualDebtToLiquidate
    );

    if (params.receiveAToken) {
      // 给清算人发送aToken
      _liquidateATokens(reservesData, reservesList, usersConfig, collateralReserve, params, vars);
    } else {
      // 发送标的资产
      _burnCollateralATokens(collateralReserve, params, vars);
    }

    // Transfer fee to treasury if it is non-zero
    if (vars.liquidationProtocolFeeAmount != 0) {
      uint256 liquidityIndex = collateralReserve.getNormalizedIncome();
      uint256 scaledDownLiquidationProtocolFee = vars.liquidationProtocolFeeAmount.rayDiv(
        liquidityIndex
      );
      uint256 scaledDownUserBalance = vars.collateralAToken.scaledBalanceOf(params.user);
      // To avoid trying to send more aTokens than available on balance, due to 1 wei imprecision
      if (scaledDownLiquidationProtocolFee > scaledDownUserBalance) {
        vars.liquidationProtocolFeeAmount = scaledDownUserBalance.rayMul(liquidityIndex);
      }
      vars.collateralAToken.transferOnLiquidation(
        params.user,
        vars.collateralAToken.RESERVE_TREASURY_ADDRESS(),
        vars.liquidationProtocolFeeAmount
      );
    }

    // 清算人归还贷款
    // Transfers the debt asset being repaid to the aToken, where the liquidity is kept
    IERC20(params.debtAsset).safeTransferFrom(
      msg.sender,
      vars.debtReserveCache.aTokenAddress,
      vars.actualDebtToLiquidate
    );

    IAToken(vars.debtReserveCache.aTokenAddress).handleRepayment(
      msg.sender,
      params.user,
      vars.actualDebtToLiquidate
    );

    emit LiquidationCall(
      params.collateralAsset,
      params.debtAsset,
      params.user,
      vars.actualDebtToLiquidate,
      vars.actualCollateralToLiquidate,
      msg.sender,
      params.receiveAToken
    );
  }

  /**
   * @notice Burns the collateral aTokens and transfers the underlying to the liquidator.
   * @dev   The function also updates the state and the interest rate of the collateral reserve.
   * @param collateralReserve The data of the collateral reserve
   * @param params The additional parameters needed to execute the liquidation function
   * @param vars The executeLiquidationCall() function local vars
   */
  function _burnCollateralATokens(
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ExecuteLiquidationCallParams memory params,
    LiquidationCallLocalVars memory vars
  ) internal {
    DataTypes.ReserveCache memory collateralReserveCache = collateralReserve.cache();
    collateralReserve.updateState(collateralReserveCache);
    collateralReserve.updateInterestRates(
      collateralReserveCache,
      params.collateralAsset,
      0,
      vars.actualCollateralToLiquidate
    );

    // Burn the equivalent amount of aToken, sending the underlying to the liquidator
    vars.collateralAToken.burn(
      params.user,
      msg.sender,
      vars.actualCollateralToLiquidate,
      collateralReserveCache.nextLiquidityIndex
    );
  }

  /**
   * @notice Liquidates the user aTokens by transferring them to the liquidator.
   * @dev   The function also checks the state of the liquidator and activates the aToken as collateral
   *        as in standard transfers if the isolation mode constraints are respected.
   * @param reservesData The state of all the reserves
   * @param reservesList The addresses of all the active reserves
   * @param usersConfig The users configuration mapping that track the supplied/borrowed assets
   * @param collateralReserve The data of the collateral reserve
   * @param params The additional parameters needed to execute the liquidation function
   * @param vars The executeLiquidationCall() function local vars
   */
  function _liquidateATokens(
    mapping(address => DataTypes.ReserveData) storage reservesData,
    mapping(uint256 => address) storage reservesList,
    mapping(address => DataTypes.UserConfigurationMap) storage usersConfig,
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ExecuteLiquidationCallParams memory params,
    LiquidationCallLocalVars memory vars
  ) internal {
    uint256 liquidatorPreviousATokenBalance = IERC20(vars.collateralAToken).balanceOf(msg.sender);
    // 给清算人发送aToken
    vars.collateralAToken.transferOnLiquidation(
      params.user,
      msg.sender,
      vars.actualCollateralToLiquidate
    );

    if (liquidatorPreviousATokenBalance == 0) {
      DataTypes.UserConfigurationMap storage liquidatorConfig = usersConfig[msg.sender];
      if (
        ValidationLogic.validateUseAsCollateral(
          reservesData,
          reservesList,
          liquidatorConfig,
          collateralReserve.configuration
        )
      ) {
        liquidatorConfig.setUsingAsCollateral(collateralReserve.id, true);
        emit ReserveUsedAsCollateralEnabled(params.collateralAsset, msg.sender);
      }
    }
  }

  /**
   * @notice Burns the debt tokens of the user up to the amount being repaid by the liquidator.
   * @dev The function alters the `debtReserveCache` state in `vars` to update the debt related data.
   * @param params The additional parameters needed to execute the liquidation function
   * @param vars the executeLiquidationCall() function local vars
   */
  function _burnDebtTokens(
    DataTypes.ExecuteLiquidationCallParams memory params,
    LiquidationCallLocalVars memory vars
  ) internal {
    if (vars.userVariableDebt >= vars.actualDebtToLiquidate) {
      vars.debtReserveCache.nextScaledVariableDebt = IVariableDebtToken(
        vars.debtReserveCache.variableDebtTokenAddress
      ).burn(
          params.user,
          vars.actualDebtToLiquidate,
          vars.debtReserveCache.nextVariableBorrowIndex
        );
    } else {
      // If the user doesn't have variable debt, no need to try to burn variable debt tokens
      if (vars.userVariableDebt != 0) {
        vars.debtReserveCache.nextScaledVariableDebt = IVariableDebtToken(
          vars.debtReserveCache.variableDebtTokenAddress
        ).burn(params.user, vars.userVariableDebt, vars.debtReserveCache.nextVariableBorrowIndex);
      }
      (
        vars.debtReserveCache.nextTotalStableDebt,
        vars.debtReserveCache.nextAvgStableBorrowRate
      ) = IStableDebtToken(vars.debtReserveCache.stableDebtTokenAddress).burn(
        params.user,
        vars.actualDebtToLiquidate - vars.userVariableDebt
      );
    }
  }

  /**
   * @notice Calculates the total debt of the user and the actual amount to liquidate depending on the health factor
   * and corresponding close factor.
   * @dev If the Health Factor is below CLOSE_FACTOR_HF_THRESHOLD, the close factor is increased to MAX_LIQUIDATION_CLOSE_FACTOR
   * @param debtReserveCache The reserve cache data object of the debt reserve
   * @param params The additional parameters needed to execute the liquidation function
   * @param healthFactor The health factor of the position
   * @return The variable debt of the user
   * @return The total debt of the user
   * @return The actual debt to liquidate as a function of the closeFactor
   */
  function _calculateDebt(
    DataTypes.ReserveCache memory debtReserveCache,
    DataTypes.ExecuteLiquidationCallParams memory params,
    uint256 healthFactor
  ) internal view returns (uint256, uint256, uint256) {
    (uint256 userStableDebt, uint256 userVariableDebt) = Helpers.getUserCurrentDebt(
      params.user,
      debtReserveCache
    );

    uint256 userTotalDebt = userStableDebt + userVariableDebt;

    // 要清算借款人贷款的百分比
    uint256 closeFactor = healthFactor > CLOSE_FACTOR_HF_THRESHOLD
      ? DEFAULT_LIQUIDATION_CLOSE_FACTOR
      : MAX_LIQUIDATION_CLOSE_FACTOR;

    // 最大清算数额
    uint256 maxLiquidatableDebt = userTotalDebt.percentMul(closeFactor);

    // 清算人传进来的要清算的数额 > 最大清算数额
    uint256 actualDebtToLiquidate = params.debtToCover > maxLiquidatableDebt
      ? maxLiquidatableDebt
      : params.debtToCover;

    return (userVariableDebt, userTotalDebt, actualDebtToLiquidate);
  }

  /**
   * @notice Returns the configuration data for the debt and the collateral reserves.
   * @param eModeCategories The configuration of all the efficiency mode categories
   * @param collateralReserve The data of the collateral reserve
   * @param params The additional parameters needed to execute the liquidation function
   * @return The collateral aToken
   * @return The address to use as price source for the collateral
   * @return The address to use as price source for the debt
   * @return The liquidation bonus to apply to the collateral
   */
  function _getConfigurationData(
    mapping(uint8 => DataTypes.EModeCategory) storage eModeCategories,
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ExecuteLiquidationCallParams memory params
  ) internal view returns (IAToken, address, address, uint256) {
    IAToken collateralAToken = IAToken(collateralReserve.aTokenAddress);
    uint256 liquidationBonus = collateralReserve.configuration.getLiquidationBonus();

    address collateralPriceSource = params.collateralAsset;
    address debtPriceSource = params.debtAsset;

    if (params.userEModeCategory != 0) {
      address eModePriceSource = eModeCategories[params.userEModeCategory].priceSource;

      if (
        EModeLogic.isInEModeCategory(
          params.userEModeCategory,
          collateralReserve.configuration.getEModeCategory()
        )
      ) {
        liquidationBonus = eModeCategories[params.userEModeCategory].liquidationBonus;

        if (eModePriceSource != address(0)) {
          collateralPriceSource = eModePriceSource;
        }
      }

      // when in eMode, debt will always be in the same eMode category, can skip matching category check
      if (eModePriceSource != address(0)) {
        debtPriceSource = eModePriceSource;
      }
    }

    return (collateralAToken, collateralPriceSource, debtPriceSource, liquidationBonus);
  }

  struct AvailableCollateralToLiquidateLocalVars {
    uint256 collateralPrice;
    uint256 debtAssetPrice;
    uint256 maxCollateralToLiquidate;
    uint256 baseCollateral;
    uint256 bonusCollateral;
    uint256 debtAssetDecimals;
    uint256 collateralDecimals;
    uint256 collateralAssetUnit;
    uint256 debtAssetUnit;
    uint256 collateralAmount;
    uint256 debtAmountNeeded;
    uint256 liquidationProtocolFeePercentage;
    uint256 liquidationProtocolFee;
  }

  /**
   * @notice Calculates how much of a specific collateral can be liquidated, given
   * a certain amount of debt asset.
   * @dev This function needs to be called after all the checks to validate the liquidation have been performed,
   *   otherwise it might fail.
   * @param collateralReserve The data of the collateral reserve
   * @param debtReserveCache The cached data of the debt reserve
   * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
   * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
   * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
   * @param userCollateralBalance The collateral balance for the specific `collateralAsset` of the user being liquidated
   * @param liquidationBonus The collateral bonus percentage to receive as result of the liquidation
   * @return The maximum amount that is possible to liquidate given all the liquidation constraints (user balance, close factor)
   * @return The amount to repay with the liquidation
   * @return The fee taken from the liquidation bonus amount to be paid to the protocol
   */
  function _calculateAvailableCollateralToLiquidate(
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ReserveCache memory debtReserveCache,
    address collateralAsset,
    address debtAsset,
    uint256 debtToCover,
    uint256 userCollateralBalance,
    uint256 liquidationBonus,
    IPriceOracleGetter oracle
  ) internal view returns (uint256, uint256, uint256) {
    AvailableCollateralToLiquidateLocalVars memory vars;

    vars.collateralPrice = oracle.getAssetPrice(collateralAsset);
    vars.debtAssetPrice = oracle.getAssetPrice(debtAsset);

    vars.collateralDecimals = collateralReserve.configuration.getDecimals();
    vars.debtAssetDecimals = debtReserveCache.reserveConfiguration.getDecimals();

    unchecked {
      vars.collateralAssetUnit = 10 ** vars.collateralDecimals;
      vars.debtAssetUnit = 10 ** vars.debtAssetDecimals;
    }

    vars.liquidationProtocolFeePercentage = collateralReserve
      .configuration
      .getLiquidationProtocolFee();

    // This is the base collateral to liquidate based on the given debt to cover
    vars.baseCollateral =
      ((vars.debtAssetPrice * debtToCover * vars.collateralAssetUnit)) /
      (vars.collateralPrice * vars.debtAssetUnit);

    vars.maxCollateralToLiquidate = vars.baseCollateral.percentMul(liquidationBonus);

    if (vars.maxCollateralToLiquidate > userCollateralBalance) {
      vars.collateralAmount = userCollateralBalance;
      vars.debtAmountNeeded = ((vars.collateralPrice * vars.collateralAmount * vars.debtAssetUnit) /
        (vars.debtAssetPrice * vars.collateralAssetUnit)).percentDiv(liquidationBonus);
    } else {
      vars.collateralAmount = vars.maxCollateralToLiquidate;
      vars.debtAmountNeeded = debtToCover;
    }

    if (vars.liquidationProtocolFeePercentage != 0) {
      vars.bonusCollateral =
        vars.collateralAmount -
        vars.collateralAmount.percentDiv(liquidationBonus);

      vars.liquidationProtocolFee = vars.bonusCollateral.percentMul(
        vars.liquidationProtocolFeePercentage
      );

      return (
        vars.collateralAmount - vars.liquidationProtocolFee,
        vars.debtAmountNeeded,
        vars.liquidationProtocolFee
      );
    } else {
      return (vars.collateralAmount, vars.debtAmountNeeded, 0);
    }
  }
}
