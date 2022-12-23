// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ySwaps/ITradeFactory.sol";
import "./interfaces/Silo/SiloRouter.sol";
import "./interfaces/Curve/IStableSwap.sol";
import "./interfaces/Convex/Booster.sol";
import "./interfaces/Convex/BaseRewardPool.sol";
import "./interfaces/Convex/PersonalVault.sol";
import "./interfaces/Convex/StakingProxyConvex.sol";
import "forge-std/console2.sol"; // @dev for test logging only - to be removed

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    event Cloned(address indexed clone);

    uint256 public maxSlippage;
    uint256 public collateralRatio;
    address public tradeFactory;
    address public silo;
    IERC20[] public rewardTokens;
    bool public useFraxBooster; // @note toggle during init for Frax Booster or regular Convex gauge

    IERC20 public constant XAI = IERC20(0xd7C9F0e536dC865Ae858b0C0453Fe76D13c3bEAc);
    IERC20 public constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 public constant FXS = IERC20(0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0);

    SiloRouter public constant siloRouter = SiloRouter(0xb2374f84b3cEeFF6492943Df613C9BcF45322a0c);
    IStableSwap public constant curvePool = IStableSwap(0x326290A1B0004eeE78fa6ED4F1d8f4b2523ab669);
    Booster public constant convexBooster = Booster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    BaseRewardPool public constant convexStaker = BaseRewardPool(0x4a866fE20A442Dff55FAA010684A5C1379151458);
    PersonalVault public constant personalVault = PersonalVault(0x569f5B842B5006eC17Be02B8b94510BA8e79FbCa);
    StakingProxyConvex public constant fraxStaker = StakingProxyConvex(0xc517E02FdA1E19F7BAeBa2BeB51b56D3b8a6a94B);

    bool internal isOriginal = true;
    uint256 internal constant MAX_BIPS = 10_000;
    uint256 internal wantDecimals; // @note 6 or 18 decimals depending on the want token

    uint256 private constant max = type(uint256).max;

    constructor(address _vault, uint256 _maxSlippage, uint256 _collateralRatio) BaseStrategy(_vault) {
        _initializeStrategy(_maxSlippage, _useFraxBooster, _collateralRatio);
    }

    function _initializeStrategy(uint256 _maxSlippage, bool _useFraxBooster, uint256 _collateralRatio) internal {
        require(_maxSlippage < 10_000 || _collateralRatio < 10_000);
        maxSlippage = _maxSlippage;
        collateralRatio = _collateralRatio;
        useFraxBooster = _useFraxBooster;
        wantDecimals = IERC20Metadata(address(want)).decimals();
        IERC20(want).safeApprove(address(siloRouter), max); 
        IERC20(XAI).safeApprove(address(curvePool), max); 
        silo = siloRouter.getSilo(address(want));
        rewardTokens.push(CRV);
        rewardTokens.push(CVX);

        if (useFraxBooster) { // @note LP token is stkcvxXAIFRAXBP3CRV-f-frax
            IERC20 stkcvxXAIFRAXBP3CRV = IERC20(0x19f0a60f4635d3E2c48647822Eda5332BA094fd3);
            IERC20(curvePool).safeApprove(address(stkcvxXAIFRAXBP3CRV), max);  
            rewardTokens.push(FXS);
            personalVault.createVault(38); // @note a personal vault needs to be created

        } else { // @note LP token is XAIFRAXBP3CRV-f
            IERC20(curvePool).safeApprove(address(convexBooster), max); 
        }

        // @note set initial parameters for Keepers
        minReportDelay = 7 days;
        maxReportDelay = 21 days;
        creditThreshold = 1e6 * (uint(10)**wantDecimals);
        profitFactor = 100;
        debtThreshold = 0;

        // @note set healhCheck
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012;
    }

// ---------------------- CLONING ----------------------
        function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_maxSlippage, _useFraxBooster, _collateralRatio);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        bool _useFraxBooster,
        uint256 _collateralRatio;
    ) external returns (address newStrategy) {
        require(isOriginal, "!clone");
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }
        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _maxSlippage, _useFraxBooster, _collateralRatio);
        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategySilo", IERC20Metadata(address(want)).symbol(), " (XAIFRAXBP3CRV-SSLP)"));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // @todo need to account for staked and unstaked LP tokens
        return want.balanceOf(address(this));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // @todo
        // claim rewards
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // @todo
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        // @todo

        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            unchecked {
                _loss = _amountNeeded - totalAssets;
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: Liquidate all positions and return the amount freed.
        // @todo

        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // @todo
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

 // ---------------------- KEEP3RS ----------------------

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));
        return super.harvestTrigger(callCostInWei) || block.timestamp - params.lastReport > minReportDelay;
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint256 _ethAmount) public view override returns (uint256) {}

    // ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 token = tokens[i];
            token.safeApprove(_tradeFactory, max);
            tf.enable(address(emissionToken), address(want));
        }        
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 token = tokens[i];
            token.safeApprove(tradeFactory, 0);
        } 
        tradeFactory = address(0);
    }

    // ---------------------- MANAGEMENT FUNCTIONS ----------------------

    function manuallyClaimRewards() external onlyVaultManagers {
        _claimRewards();
    }

    function setMaxSlippage(uint256 _maxSlippage)
        external
        onlyVaultManagers
    {
        require(_maxSlippage < 10_000);
        maxSlippage = _maxSlippage;
    }

    // ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfUnstakedLPToken() public view returns (uint256) {
        return curvePool.balanceOf(address(this));
    }

    function _supplyToSilo(uint256 _wantAmount) internal {
        // @note _collateralOnly to True, forfeiting supply interest but ensure the strategy is liquid
        silo.deposit(address(want), _wantAmount, True);
    }

    function _withdrawFromSilo(uint256 _wantAmount) internal {
        silo.withdraw(address(want), _wantAmount, True);
    }

    function _borrowFromSilo(uint256 _xaiAmount) internal {
        silo.borrow(address(XAI), _xaiAmount);
    }

    function _repayToSilo(uint256 _xaiAmount) internal {
        silo.repay(address(XAI), _xaiAmount);
    }

    function _addLiquidityToCurve(uint256 _wantAmount) internal {
        uint256 minMintAmount = (wantAmount * curvePool.get_virtual_price() * (MAX_BIPS - maxSlippage) / MAX_BIPS)/ 1e18; // @todo check decimals
        // @dev check for potential oracle exploit here, using get_virtual_price
        curvePool.add_liquidity(_wantAmount, minMintAmount); // @todo Curve LP oracle
        uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();
        if (useFraxBooster) {
            _stakeToFrax(_balanceOfUnstakedLPToken);
        } else {
            _stakeToConvex(_balanceOfUnstakedLPToken);
        }
    }

    function _removeLiquidityFromCurve() internal {
        // @todo slippage check
        if (useFraxBooster) {
            _unstakeFromFrax(_balanceOfUnstakedLPToken);
        } else {
            _unstakeFromConvex(_balanceOfUnstakedLPToken);
        }
    }

    function _stakeToConvex(uint256 _curveLpAmount) internal {
        convexStaker.stake(_curveLpAmount);
    }

    function _unstakeFromConvex(uint256 _curveLpAmount) internal {
        convexStaker.withdraw(_curveLpAmount, True); // @dev should we claim at the same time?
    }

    function _stakeToFrax(uint256 _curveLpAmount) internal {
        // @note Frax LPs are subject to time-locks; all pools require a minimum of 1 day locked.
        fraxStaker.stakeLockedCurveLp(_curveLpAmount, 1 days);
    }

    function _unstakeFromFrax(uint256 _curveLpAmount) internal {
        fraxStaker.withdrawLocked(_kek_id); // @todo
        // @dev check: https://github.com/yearn/yearn-strategies/issues/401
    }

    function _claimRewards() internal {
        if (useFraxBooster) {
            convexStaker.getReward(); // @note claim CRV & CVX
        } else {
            fraxStaker.getReward(); // @note claim CRV, CVX & FXS
        }
    }      

}
