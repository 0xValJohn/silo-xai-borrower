// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.15;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // @dev check if used
import "./interfaces/Silo/SiloRouter.sol";
import "./interfaces/IYearnVault.sol"; //  IVault
import "./interfaces/IOracle.sol";
// interface for siloLens

/********************
 *   Strategy to supply want, borrow XAI and invest in a yvXAI vault
 *   borrow/lend logic inspired from CompoundV3-Lender-Borrower by @Schlagonia
 *   
 *
 ********************* */

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    event Cloned(address indexed clone);

    uint256 public collateralRatio;
    address public silo;
    address public collateralOnlyDeposits;
    address public debtToken;

    IERC20 public constant XAI = IERC20(0xd7C9F0e536dC865Ae858b0C0453Fe76D13c3bEAc);

    SiloRouter public constant siloRouter = SiloRouter(0xd998C35B7900b344bbBe6555cc11576942Cf309d);
    SiloLens public constant siloLens = SiloLens(0xf12C3758c1eC393704f0Db8537ef7F57368D92Ea);
    IOracle public constant yearnOracle = IOracle(0x83d95e0D5f402511dB06817Aff3f9eA88224B030); // @note yearn lens oracle
    IYearnVault public constant yvXaiVault = IYearnVault(0x000000000000000000000000000000000000); // @todo should it be a constant?

    bool internal isOriginal = true;
    uint256 internal constant MAX_BIPS = 10_000;
    uint256 internal wantDecimals; // @note want is either 6 or 18 decimals

    uint256 private constant max = type(uint256).max;

    constructor(address _vault, uint256 _collateralRatio) BaseStrategy(_vault) {
        _initializeStrategy(_collateralRatio);
    }

    function _initializeStrategy(uint256 _collateralRatio) internal {
        require(_collateralRatio < 10_000);
        collateralRatio = _collateralRatio;
        wantDecimals = IERC20Metadata(address(want)).decimals();
        IERC20(want).safeApprove(address(siloRouter), max); 
        silo = siloRouter.getSilo(address(want));
        
        // @note Silo supply/debt tokens
        collateralOnlyDeposits = silo.assetStorage(address(want)).collateralOnlyDeposits;
        debtToken = silo.assetStorage(address(want)).debtToken;

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
        _initializeStrategy(_collateralRatio);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _collateralRatio
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
        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _collateralRatio);
        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategySiloXAIBorrower-", IERC20Metadata(address(want)).symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // @note Assets (loose want, want deposited and yvXAI shares) - Liabilities (balance of XAI borrowed from Silo)
        // @param getPriceUsdcRecommended used to estimate borrowed position (incl. interests), returns 6 decimals 
        uint256 _yvSharesValueToWant = ((yvXaiVault.balanceOf(address(this)) * yvXaiVault.sharePrice())/ (10 ** (36 - wantDecimals)));
        uint256 _baseTokenOwedInWant = (_balanceOfBorrow() * 1e6) / yearnOracle.getPriceUsdcRecommended(address(this));
        return want.balanceOf(address(this)) + balanceOfCollateral() + _yvSharesValueToWant - _baseTokenOwedInWant;
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
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        uint256 _estimatedTotalAssets = estimatedTotalAssets();

        if (totalDebt > _estimatedTotalAssets) {
            // @note we have losses
            _loss = totalDebt - _estimatedTotalAssets;
        } else {
            // @note we have profit
            _profit = _estimatedTotalAssets - totalDebt;
        }

        (uint256 _amountFreed, ) = liquidatePosition(_debtOutstanding + _profit);

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);
        // @note adjust profit in case we had any losses from liquidatePosition
        _profit = _amountFreed - _debtPayment;   
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // @note Supply all loose want to Silo
        uint256 _toInvest = balanceOfWant();
        if (_toInvest > 0) {
            _depositToSilo(_toInvest);
        }
    }




// check current rates for supply and borrow
// * Get the current supply APR in Compound III */
    function getSupplyApr(uint256 newAmount) internal view returns (uint) {
        unchecked {   
            return comet.getSupplyRate(
                    (comet.totalBorrow() + newAmount) * 1e18 / (comet.totalSupply() + newAmount) 
                        ) * SECONDS_PER_YEAR;
        }
    }

        uint256 needed = _amountNeeded - balance;


        // @note: withdraw from yvXAI (could result in loss), repay XAI, withdraw want while maintaining healthy ltv

        // calc amount of yvXAI to withdraw to met the required amount AND ensure a healthy ltv
        
        



        // @note we first repay whatever we need to repay to keep healthy ratios
        _withdrawFromDepositer(_calculateAmountToRepay(needed)); // withdraw from vault
        
        
        
        
        
        
        // we repay the BaseToken debt with the amount withdrawn from the vault
        _repayTokenDebt();
        //Withdraw as much as we can up to the amount needed while maintaning a health ltv
        _withdraw(address(want), Math.min(needed, _maxWithdrawal()));
        // it will return the free amount of want
        balance = balanceOfWant();
        // we check if we withdrew less than expected AND should harvest or buy BaseToken with want (realising losses)
        if (
            _amountNeeded > balance &&
            balanceOfDebt() > 0 && // still some debt remaining
            balanceOfBaseToken() + balanceOfDepositer() == 0 && // but no capital to repay
            !leaveDebtBehind // if set to true, the strategy will not try to repay debt by selling want
        ) {
            // using this part of code may result in losses but it is necessary to unlock full collateral in case of wind down
            //This should only occur when depleting the strategy so we want to swap the full amount of our debt
            //we buy BaseToken first with available rewards then with Want
            _buyBaseToken();

            // we repay debt to actually unlock collateral
            // after this, balanceOfDebt should be 0
            _repayTokenDebt();

            // then we try withdraw once more
            _withdraw(address(want), _maxWithdrawal());
            // re-update the balance
            balance = balanceOfWant();
        }

        if (_amountNeeded > balance) {
            _liquidatedAmount = balance;
            _loss = _amountNeeded - balance;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }









    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        _withdrawFromXaiVault(_amountNeeded); // @dev depending on Curve pool composition, removal could result in a loss
        _repayToSilo(balanceOfXai()); // @todo do we want to repay all the balance?
        _withdrawFromSilo(); // @todo what is safe to withdraw to maintain our health factor?
        // @todo health factor overwrite?
               
        
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






















    function prepareMigration(address _newStrategy) internal override {
        // @todo probably better to repay all debt

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

    // ---------------------- MANAGEMENT FUNCTIONS ----------------------

    // @todo set _collateralRatio;









    // ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfCollateral() public view returns (uint256) {

    }

    function balanceOfXai() public view returns (uint256) {
        return XAI.balanceOf(address(this));
    }

    function balanceOfDebt() public view returns (uint256) {
    }

    function balanceOfVaultShares() public view returns (uint256) {
    }



    // ---------------------- Silo helper functions ----------------------

    function _depositToSilo(uint256 _wantAmount. bool _collateralOnly) internal {
        // @note: if _collateralOnly is True, we forfeit supply interest but strategy can withdraw at any time
        silo.deposit(address(want), _wantAmount, _collateralOnly);
    }

    function _withdrawFromSilo(uint256 _wantAmount) internal {
        silo.withdraw(address(want), _wantAmount, True);
    }

    function _borrowFromSilo(uint256 _xaiAmount) internal {
        silo.borrow(address(XAI), _xaiAmount);
    }

    function _repayTokenDebt(uint256 _xaiAmount) internal {
        silo.repay(address(XAI), _xaiAmount);
    }

    function _repayMaxTokenDebt() internal {
        // @note: We cannot pay more than loose balance or more than we owe
        _repayDebtToSilo(math.min(balanceOfXai(), balanceOfDebt()));
    }




    function getSupplyApr(uint256 _newAmount) internal view returns (uint25) {
    }

    function getBorrowApr(uint256 _newAmount) internal view returns (uint256) {
    }






    function getCurrentLTV() external view returns(uint256) {
        siloLens.getUserLTV 
    }

    function _getTargetLTV()
    }

    function _getWarningLTV()
    }

    // ---------------------- Oracles and price conversions ----------------------



    // @note Returns the _amount of _token in terms of USD, i.e 1e8
    function _toUsd(uint256 _amount, address _token) internal view returns(uint256) {
        if(_amount == 0) return _amount;
        //usd price is returned as 1e8
        unchecked {
            return _amount * getCompoundPrice(_token) / (10 ** IERC20Extended(_token).decimals());
        }
    }

    // @note Returns the _amount of usd (1e8) in terms of want
    function _fromUsd(uint256 _amount, address _token) internal view returns(uint256) {
        if(_amount == 0) return _amount;
        unchecked {
            return _amount * (10 ** IERC20Extended(_token).decimals()) / getCompoundPrice(_token);


            yearnOracle.getPriceUsdcRecommended(address(this))


        }
    }

    // ---------------------- IVault functions ----------------------

    function _depositToVault(uint256 _xaiAmount) internal {
        yvxai.desposit(_xaiAmount);
    }

    function _withdrawFromVault(uint256 _amount) internal {
        uint256 _sharesNeeded = amount * 10 ** vault.decimals() / vault.pricePerShare();
        yvxai.withdraw(math.Min(balanceOfVaultShares(), _sharesNeeded));
    }

    // @note: Manual function available to management to withdraw from vault and repay debt
    function manualWithdrawAndRepayDebt(uint256 _amount) external onlyAuthorized {
        if(_amount > 0) {
            _withdrawFromVault(_amount);
        }
        _repayMaxTokenDebt();
    }











`



    // ---------------------- If we need to buy base token ----------------------

 //This should only ever get called when withdrawing all funds from the strategy if there is debt left over.
    //It will first try and sell rewards for the needed amount of base token. then will swap want
    function _buyBaseToken() internal {
        //We should be able to get the needed amount from rewards tokens. 
        //We first try that before swapping want and reporting losses.
        _claimAndSellRewards();

        uint256 baseStillOwed = baseTokenOwedBalance();
        //Check if our debt balance is still greater than our base token balance
        if(baseStillOwed > 0) {
            //Need to account for both slippage and diff in the oracle price.
            //Should be only swapping very small amounts so its just to make sure there is no massive sandwhich
            uint256 maxWantBalance = _fromUsd(_toUsd(baseStillOwed, baseToken), address(want)) * 10_500 / MAX_BPS;
            //Under 10 can cause rounding errors from token conversions, no need to swap that small amount  
            if (maxWantBalance <= 10) return;

            //This should rarely if ever happen so we approve only what is needed
            IERC20(address(want)).safeApprove(address(router), 0);
            IERC20(address(want)).safeApprove(address(router), maxWantBalance);
            _swapFrom(address(want), baseToken, baseStillOwed, maxWantBalance);   
        }
    }

    

    // @dev: will need to use Curve for XAI (primary liquidity source)

}
