// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

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

    bool internal isOriginal = true;
    uint256 private constant max = type(uint256).max;
    uint256 public maxSlippage;
    address public tradeFactory;
    address public silo;
    uint256 internal constant MAX_BIPS = 10_000;
    uint256 internal wantDecimals; // @dev want could be DAI, USDC, USDT
    bool public useFraxBooster; // @note use Frax Booster or just the Convex gauge
    IERC20[] public rewardTokens;

    // @dev ERC20 tokens
    IERC20 public constant XAI = IERC20(0xd7C9F0e536dC865Ae858b0C0453Fe76D13c3bEAc);
    IERC20 public constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 public constant FXS = IERC20(0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0);

    // @dev Silo
    SiloRouter public constant siloRouter = SiloRouter(0xb2374f84b3cEeFF6492943Df613C9BcF45322a0c);
    
    // @dev Curve
    IStableSwap public constant curvePool = IStableSwap(0x326290A1B0004eeE78fa6ED4F1d8f4b2523ab669);

    // @dev Convex/Frax
    Booster public constant convexBooster = Booster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    BaseRewardPool public constant convexRewards = BaseRewardPool(0x4a866fE20A442Dff55FAA010684A5C1379151458);
    PersonalVault public constant personalVault = PersonalVault(0x569f5B842B5006eC17Be02B8b94510BA8e79FbCa);
    StakingProxyConvex public constant fraxRewards = StakingProxyConvex(0xc517E02FdA1E19F7BAeBa2BeB51b56D3b8a6a94B);

    constructor(address _vault, uint256 _maxSlippage) BaseStrategy(_vault) {
        _initializeStrategy(_maxSlippage);
    }

    function _initializeStrategy(uint256 _maxSlippage, bool _useFraxBooster) internal {

        // @dev check: https://github.com/yearn/yearn-strategies/issues/401
        
        // @dev Gauge options
        // Option 1:    XAIFRAXBP3CRV-f
        // Rewards:     CRV, CVX
        // LP:          0x326290A1B0004eeE78fa6ED4F1d8f4b2523ab669 (XAIFRAXBP3CRV-f)
        //
        // Option 2:    stkcvxXAIFRAXBP3CRV-f-frax
        // Rewards:     CRV, CVX, FXS
        // LP:          0x19f0a60f4635d3E2c48647822Eda5332BA094fd3 (stkcvxXAIFRAXBP3CRV-f-frax)
        //
        // DEPOSIT:     0xF403C135812408BFbE8713b5A23a04b3D48AAE31 (Booster)
        // REWARDS:     0x4a866fE20A442Dff55FAA010684A5C1379151458

        maxSlippage = _maxSlippage;
        wantDecimals = IERC20Metadata(address(want)).decimals();
        useFraxBooster = _useFraxBooster;

        IERC20(want).safeApprove(address(siloRouter), max); 
        IERC20(XAI).safeApprove(address(curvePool), max); 
        
        silo = siloRouter.getSilo(address(want));
        rewardTokens.push(CRV);
        rewardTokens.push(CVX);

        if (useFraxBooster) {
            // @note Frax LPs are subject to time-locks; all pools require a minimum of 1 day locked.
            // @dev approve XAIFRAXBP3CRV-f to stkcvxXAIFRAXBP3CRV-f-frax
            IERC20 stkcvxXAIFRAXBP3CRV = IERC20(0x19f0a60f4635d3E2c48647822Eda5332BA094fd3);
            IERC20(curvePool).safeApprove(address(stkcvxXAIFRAXBP3CRV), max);  
            rewardTokens.push(FXS);
            personalVault.createVault(38); // @dev create personnal vault
        } else {
            // @dev approve XAIFRAXBP3CRV-f to Booster contract
            IERC20(curvePool).safeApprove(address(convexBooster), max); 
        }

        // @todo set keepers parameters
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

// ---------------------- CLONING ----------------------
        function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_maxSlippage, _useFraxBooster);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        bool _useFraxBooster
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
        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _maxSlippage, _useFraxBooster);
        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategySilo", IERC20Metadata(address(want)).symbol(), " (XAIFRAXBP3CRV-SSLP)"));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return want.balanceOf(address(this)); // @todo
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
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

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
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
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
        maxSlippage = _maxSlippage;
    }

    // ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------


    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfUnstakedLPToken() public view returns (uint256) {
        return curvePool.balanceOf(address(this));
    }


    function _supplyWantAndBorrowXAI() internal {
        // @todo check supply and borrow rates, check maximum borrowable
    }

    function _addLiquidityToCurve(uint256 _wantAmount) internal {
        uint256 minMintAmount = (wantToLp(_wantAmount) * (MAX_BIPS - maxSlippage) / MAX_BIPS);
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

    function _stakeToConvex() internal {
        // @todo
    }

    function _unstakeFromConvex() internal {
        // @todo
    }

    function _stakeToFrax() internal {
        // @todo
    }

    function _unstakeFromFrax() internal {
        // @todo
    }

    function _claimRewards() internal {
        if (useFraxBooster) {
            // @todo check if we need to use the other getReward fct with params
            convexRewards.getReward(); // @note will claim CRV & CVX
        } else {
            fraxRewards.getReward(); // @note will claim CRV, CVX & FXS
        }
    }

}
