// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/IFeeProxy.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IPriceConsumer.sol";
import "hardhat/console.sol";

library DelegatedStakingHelper {

    /**
     * @dev Calculates shares
     * @param _amount amount of collateral
     * @param _totalShares total number of shares
     * @param _totalAmount total amount of collateral
     */
    function _calculateShares(uint256 _amount, uint256 _totalShares, uint256 _totalAmount)
        internal
        pure
        returns(uint256)
    {
        return _amount * _totalShares / _totalAmount;
    }

    /**
     * @dev Calculates amount from shares
     * @param _shares number of shares
     * @param _totalAmount total amount of collateral
     * @param _totalShares total number of shares
     */
    function _calculateFromShares(uint256 _shares, uint256 _totalAmount, uint256 _totalShares)
        internal
        pure
        returns(uint256)
    {
        return _shares * _totalAmount / _totalShares;
    }

    /**
     * @dev Calculates passed rewards
     * @param _shares Delegator shares
     * @param _accTokens Accumulated tokens per share
     */
    function _calculatePassedRewards(uint256 _shares, uint256 _accTokens) internal pure returns (uint256) {
        return _shares * _accTokens / 1e18;
    }
}

contract DelegatedStaking is Initializable,
                         AccessControlUpgradeable,
                         PausableUpgradeable,
                         ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    struct RewardInfo {
        uint256 totalAmount; // total rewards
        uint256 distributed; // distributed rewards
    }

    struct WithdrawalInfo {
        address delegator;
        uint256 amount; // amount of withdrawn token
        uint256 slashingAmount; // slashing amount by governance
        uint256 timelock; // time till the asset is locked
        address receiver; // token receiver
        address collateral; // collateral identifier
        bool executed; // whether is executed
        bool paused;    // whether is paused
    }

    struct WithdrawalRequests {
        mapping(uint256 => WithdrawalInfo) withdrawals;
        uint256 count; // counter of withdrawals from specific validator
    }

    struct DelegatorsInfo {
        uint256 shares; // delegator share of collateral tokens
        uint256 locked; // share locked by depositing to strategy
        mapping(address => uint256) strategyShares; // map strategy(aave/compound/yearn) for each collateral
        uint256 accumulatedRewards; // info how many reward tokens were earned
    }

    struct ValidatorCollateral {
        uint256 stakedAmount; // total tokens staked by delegators
        uint256 shares; // total share of collateral tokens
        uint256 locked; // total share locked by depositing to strategy
        mapping(address => uint256) strategyShares;
        mapping(address => DelegatorsInfo) delegators; // delegation info for each delegator
        uint256 accumulatedRewards; // how many reward tokens were earned
        uint256 rewardsForWithdrawal; // how many reward tokens validator can withdrawal
    }

    struct ValidatorInfo {
        address admin;
        mapping(address => ValidatorCollateral) collateralPools; // collateral pools of validator
        uint256 rewardWeightCoefficient;
        uint256 profitSharingBPS;  // profit sharing basis points.
        bool delegatorActionPaused; // paused stake/unstake for this validator
        bool isEnabled;
        bool exists;
    }

    struct Collateral {
        uint256 slashedAmount; // balance of slashing treasury of this assets
        uint256 totalLocked; // total staked tokens
        uint256 rewards; // total accumulated rewards
        uint256 maxStakeAmount; // maximum stake for each validator's collateral
        uint8 decimals;
        bool isEnabled;
        bool isUSDStable;
        bool exists;
    }

    struct Strategy {
        address stakeToken;
        address strategyToken;
        address rewardToken;
        uint256 totalShares;
        uint256 totalReserves;
        uint256 rewards;
        bool isEnabled;
        bool exists;
        bool isRecoverable;
    }

    mapping(address => RewardInfo) public getRewardsInfo;
    mapping(address => ValidatorInfo) public getValidatorInfo; // validator address => validator details
    mapping(address => WithdrawalRequests) public getWithdrawalRequests; // validators address => withdrawal requests

    uint256 public withdrawTimelock; // duration of withdrawal timelock
    uint256 public constant BPS_DENOMINATOR = 10000; // Basis points, or bps, equal to 1/10000 used to express relative value
    uint256 public minProfitSharingBPS;
    uint256 public weightCoefficientDenominator;
    mapping(address => Collateral) public collaterals;
    address[] public validatorAddresses;
    address[] public collateralAddresses;
    mapping(address => mapping(address => Strategy)) public strategies;
    address[] public strategyControllerAddresses;
    mapping(address => bool) public strategyControllerExists;
    IPriceConsumer public priceConsumer;
    IFeeProxy public feeProxy; // proxy to convert the collected rewards into other collaterals
    address public slashingTreasury;

    /* ========== ERRORS ========== */

    error AdminBadRole();
    error CollateralDisabled();
    error CollateralLimited();
    error WrongArgument();
    error WrongRequest(uint256 id);
    error AlreadyExecuted(uint256 id);

    error DelegatorActionPaused();
    error RequestPaused(uint256 id);
    error Timelock();
    error AlreadyExists();
    error ZeroAmount();
    error WrongAmount();

    /* ========== MODIFIERS ========== */

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert AdminBadRole();
        _;
    }

    /* ========== Events ========== */

    event Staked(address validator, address delegator, address collateral, uint256 amount);
    event UnstakeRequested(
        address validator,
        address delegator,
        address collateral,
        address receipient,
        uint256 timelock,
        uint256 shares,
        uint256 tokenAmount,
        uint256 index);

    event ValidatorRewardsExchanged(
        address _validator,
        address _admin,
        address _caller,
        address _collateral,
        uint256 _rewardAmount);

    event SlashedUnstakeRequest(
        address validator,
        address delegator,
        address collateral,
        uint256 slashedAmount,
        uint256 index);

    event SlashedValidatorCollateral(
        address validator,
        address collateral,
        uint256 slashedAmount);

    event SlashedValidatorRewards(
        address validator,
        address collateral,
        uint256 slashedAmount
    );

    event UnstakeExecuted(address validator, address delegator, address collateral, uint256 amount, uint256 withdrawalId);
    event UnstakeCancelled(address validator, address delegator, uint256 withdrawalId);
    event UnstakePaused(address validator, uint256 withdrawalId, bool paused);
    event Liquidated(address validator, address collateral, uint256 amount);
    event LiquidatedDelegator(address validator, address delegator, address collateral, uint256 amount);
    event DepositedToStrategy(address validator, address delegator, uint256 amount, address strategy, address collateral);
    event WithdrawnFromStrategy(address validator, address delegator, uint256 amount, address strategy, address collateral);
    event EmergencyWithdrawnFromStrategy(uint256 amount, address strategy, address collateral);
    event RecoveredFromEmergency(address validator, uint256 amount, address strategy, address collateral);
    event StrategyReset(address _strategy, address collateral);
    event RewardsReceived(address token,  uint256 amount);
    event RewardsDistributed(address rewardToken, uint256 rewardAmount);
    event WithdrawSlashingTreasury(address collateral, uint256 amount);
    event UpdateSlashingTreasury(address newTreasury);
    event WithdrawTimelockUpdated(uint256 newTimelock);

    event UpdateCollateralEnabled(address collateral, bool isEnabled);
    event UpdateCollateral(address collateral, uint256 maxStakeAmount);
    event UpdateRewardWeight(address validator, uint256 value);
    event EnableValidator(address validator, bool isEnabled);

    /* PUBLIC */

    /**
     * @dev Initializer that initializes the most important configurations.
     * @param _withdrawTimelock Duration of withdrawal timelock.
     * @param _priceConsumer Price consumer contract.
     * @param _slashingTreasury Address of slashing treasury.
     */
    function initialize(
        uint256 _withdrawTimelock, 
        IPriceConsumer _priceConsumer,
        IFeeProxy _feeProxy,
        address _slashingTreasury
    ) public initializer {
        // Grant the contract deployer the default admin role: it will be able
        // to grant and revoke any roles
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        withdrawTimelock = _withdrawTimelock;
        priceConsumer = _priceConsumer;
        feeProxy = _feeProxy;
        slashingTreasury = _slashingTreasury;
        minProfitSharingBPS = 5000;
    }

    /**
     * @dev stake collateral to validator.
     * @param _validator Validator address.
     * @param _collateral address of collateral
     * @param _amount Amount to stake.
     */
    function stake(
        address _validator,
        address _collateral,
        uint256 _amount
    ) external nonReentrant whenNotPaused {
        ValidatorInfo storage validator = getValidatorInfo[_validator];
        if (validator.delegatorActionPaused) revert DelegatorActionPaused();
        Collateral storage collateral = collaterals[_collateral];
        if (!collateral.isEnabled) revert CollateralDisabled();
        ValidatorCollateral storage validatorCollateral = validator.collateralPools[_collateral];
        if (validatorCollateral.stakedAmount + _amount > collateral.maxStakeAmount) revert CollateralLimited();
        DelegatorsInfo storage delegator = validatorCollateral.delegators[msg.sender];

        IERC20(_collateral).safeTransferFrom(msg.sender, address(this), _amount);

        // Calculate amount of shares to be issued to delegator
        uint256 shares = validatorCollateral.stakedAmount > 0
            ? DelegatedStakingHelper._calculateShares(_amount, validatorCollateral.shares,
                validatorCollateral.stakedAmount)
            : _amount;

        //Increase total collateral of the protocol for this asset
        collateral.totalLocked += _amount;
        //Increase total collateral of the validator for this asset
        validatorCollateral.stakedAmount += _amount;
        validatorCollateral.shares += shares;
        delegator.shares += shares;

        emit Staked(_validator, msg.sender, _collateral, _amount);

        console.log("collateral %s", _collateral);
        console.log("validator %s", _validator);
        console.log("delegation %s", msg.sender);
        console.log("_amount %s", _amount);
        console.log("collateral.totalLocked %s", collateral.totalLocked);
        console.log("validatorCollateral.stakedAmount %s", validatorCollateral.stakedAmount);
        console.log("validatorCollateral.shares %s",validatorCollateral.shares);
        console.log("delegator.shares %s", delegator.shares);
    }

    /**
     * @dev Withdraws validator reward.
     * @param _validator Validator address.
     * @param _collateral Index of collateral
     * @param _recipient Recepient reward.
     * @param _shares Shares to withdraw.
     */
    function requestUnstake(
        address _validator,
        address _collateral,
        address _recipient,
        uint256 _shares
    ) external nonReentrant whenNotPaused {

        console.log("requestUnstake _validator %s", _validator);
        console.log("requestUnstake _collateral %s", _collateral);
        ValidatorInfo storage validator = getValidatorInfo[_validator];
        if (validator.delegatorActionPaused) revert DelegatorActionPaused();
        ValidatorCollateral storage validatorCollateral = validator.collateralPools[_collateral];
        WithdrawalRequests storage withdrawalRequests =  getWithdrawalRequests[_validator];
        DelegatorsInfo storage delegator = validatorCollateral.delegators[msg.sender];

        if (_shares > delegator.shares) {
            _shares = delegator.shares;
        }
        console.log("requestUnstake _shares %s", _shares);

        uint256 withdrawTokenAmount = DelegatedStakingHelper._calculateFromShares(
            _shares, validatorCollateral.stakedAmount,
            validatorCollateral.shares
        );

        delegator.shares -= _shares;
        console.log("new  delegator.shares %s", delegator.shares);
        validatorCollateral.shares -= _shares;
        validatorCollateral.stakedAmount -= withdrawTokenAmount;
        collaterals[_collateral].totalLocked -= withdrawTokenAmount;

        uint256 withdrawIndex = withdrawalRequests.count;
        uint256 timelock = block.timestamp + withdrawTimelock;
        WithdrawalInfo storage withdraw = withdrawalRequests.withdrawals[withdrawIndex];
        withdraw.delegator = msg.sender;
        withdraw.amount = withdrawTokenAmount;
        withdraw.timelock = timelock;
        withdraw.receiver = _recipient;
        withdraw.collateral = _collateral;

        withdrawalRequests.count++;
        emit UnstakeRequested(
            _validator,
            msg.sender,
            _collateral,
            _recipient,
            timelock,
            _shares,
            withdrawTokenAmount,
            withdrawIndex);
    }

    /**
    * @dev Execute withdrawal requests.
    * @param _validator Validator address.
    * @param _fromWithdrawId Starting from withdrawal identifier.
    * @param _toWithdrawId Up to withdrawal identifier.
    */
    function executeUnstake(
        address _validator,
        uint256 _fromWithdrawId,
        uint256 _toWithdrawId
    ) external nonReentrant whenNotPaused {
        if (getValidatorInfo[_validator].delegatorActionPaused) revert DelegatorActionPaused();
        WithdrawalRequests storage withdrawalRequests = getWithdrawalRequests[_validator];
        if (_toWithdrawId >= withdrawalRequests.count) revert WrongArgument();
        for (uint256 currentWithdrawId = _fromWithdrawId; currentWithdrawId < _toWithdrawId; currentWithdrawId++) {
            WithdrawalInfo storage withdrawal = withdrawalRequests.withdrawals[currentWithdrawId];
            if (!withdrawal.executed) {
                if (withdrawal.paused) revert RequestPaused(currentWithdrawId);
                if (withdrawal.timelock > block.timestamp) revert Timelock();

                withdrawal.executed = true;
                uint256 withdrawAmount = withdrawal.amount - withdrawal.slashingAmount; // I think this is already accounted for on L#428
                IERC20(withdrawal.collateral).safeTransfer(withdrawal.receiver, withdrawAmount);
                emit UnstakeExecuted(_validator, withdrawal.delegator, withdrawal.collateral, withdrawAmount, currentWithdrawId);
            }
        }
    }

    /**
     * @dev Cancel unstake.
     * @param _validator Validator address.
     * @param _fromWithdrawId Starting from withdrawal identifier.
     * @param _toWithdrawId Up to withdrawal identifier.
     */
    function cancelUnstake(
        address _validator,
        uint256 _fromWithdrawId,
        uint256 _toWithdrawId
    ) external nonReentrant whenNotPaused {
        ValidatorInfo storage validator = getValidatorInfo[_validator];
        if (validator.delegatorActionPaused) revert DelegatorActionPaused();
        WithdrawalRequests storage withdrawalRequests =  getWithdrawalRequests[_validator];

        for (uint256 currentWithdrawId = _fromWithdrawId; currentWithdrawId < _toWithdrawId; currentWithdrawId++) {
            WithdrawalInfo storage withdrawal = withdrawalRequests.withdrawals[currentWithdrawId];
            if (withdrawal.executed) revert AlreadyExecuted(currentWithdrawId);
            ValidatorCollateral storage validatorCollateral = validator.collateralPools[withdrawal.collateral];
            if (msg.sender != withdrawal.delegator) revert WrongArgument();
            DelegatorsInfo storage delegator = validatorCollateral.delegators[withdrawal.delegator];

            withdrawal.executed = true;
            uint256 _shares = validatorCollateral.shares > 0
                ? DelegatedStakingHelper._calculateShares(
                    withdrawal.amount,
                    validatorCollateral.shares,
                    validatorCollateral.stakedAmount)
                : withdrawal.amount;
            collaterals[withdrawal.collateral].totalLocked += withdrawal.amount;
            delegator.shares += _shares;
            validatorCollateral.shares += _shares;
            validatorCollateral.stakedAmount += withdrawal.amount;
            emit UnstakeCancelled(_validator, withdrawal.delegator, currentWithdrawId);
        }
    }

    /**
    * @dev Execute withdrawal requests.
    * @param _validator Validator address.
    * @param _problemTimestamp Timestamp at which problem occurred
    * @param _slashPercent percent must be set in wei (1e18 DENOMINATOR)
    */
    function slashUnstakeRequests(
        address _validator,
        uint256 _problemTimestamp,
        uint256 _slashPercent
    ) external onlyAdmin {
        WithdrawalRequests storage withdrawalRequests = getWithdrawalRequests[_validator];
        uint256[] memory withdrawalIds = new uint256[](withdrawalRequests.count); // allocate enough for worst case where all requests are included
        uint256 idIterator = 0;
        for (uint256 id = 0; id < withdrawalRequests.count; id++) {
            WithdrawalInfo memory withdrawal = withdrawalRequests.withdrawals[id];
            if (!withdrawal.executed && withdrawal.timelock > _problemTimestamp + withdrawTimelock) {
                // then this was after problem, so add to list of ids to slash
                withdrawalIds[idIterator] = id;
                idIterator++;
            }
        }
        address[] memory seenCollateral = new address[](collateralAddresses.length);
        uint256[] memory slashingAmounts = new uint256[](collateralAddresses.length);
        uint256 seenIterator = 0;
        for (uint256 idIndex = 0; idIndex < withdrawalIds.length; idIndex++) {
            uint256 currentWithdrawId = withdrawalIds[idIndex];
            WithdrawalInfo storage withdrawal = withdrawalRequests.withdrawals[currentWithdrawId];
            uint256 slashingAmount = withdrawal.amount * _slashPercent / 1e18;
            withdrawal.amount = withdrawal.amount - slashingAmount;
            withdrawal.slashingAmount = slashingAmount;
                
            bool seen = false;
            for (uint256 i=0; i<seenCollateral.length; i++) {
                if (seenCollateral[i] == withdrawal.collateral) {
                    slashingAmounts[i] += slashingAmount;
                    seen = true;
                    break;
                }
            }
            if (seen == false) {
                seenCollateral[seenIterator] = withdrawal.collateral;
                slashingAmounts[seenIterator] = slashingAmount;
                seenIterator++;
            }
            emit SlashedUnstakeRequest(
                _validator,
                withdrawal.delegator,
                withdrawal.collateral,
                slashingAmount,
                currentWithdrawId);
        }
        for (uint256 seenIndex=0; seenIndex < seenCollateral.length; seenIndex++) {
            collaterals[seenCollateral[seenIndex]].slashedAmount += slashingAmounts[seenIndex];
        }
    }

    /**
    * @dev Withdraw collected slashed amounts of all assets to protocol slashing treasury address
    */
    function withdrawSlashingTreasury() external onlyAdmin {
        for (uint256 i = 0; i < collateralAddresses.length; i++) {
            address collateralAddress = collateralAddresses[i];
            Collateral storage currentCollateral = collaterals[collateralAddress];
            uint256 slashedAmount = currentCollateral.slashedAmount;
            if (slashedAmount > 0) {
                currentCollateral.slashedAmount = 0;
                IERC20(collateralAddress).safeTransfer(slashingTreasury, slashedAmount);
                emit WithdrawSlashingTreasury (collateralAddress, slashedAmount);
            }
        }
    }

    /**
    * @dev Slash validator collateral.
    * @param _validator Validator address.
    * @param _collateral Collateral address.
    * @param _slashAmount Amount to be slashed.
    */
    function slashValidatorCollateral(
        address _validator,
        address _collateral,
        uint256 _slashAmount
    ) external onlyAdmin {
        Collateral storage collateral = collaterals[_collateral];
        //Decrease total collateral of the protocol for this asset
        collateral.totalLocked -= _slashAmount;
        collateral.slashedAmount += _slashAmount;
        //Decrease total collateral of the validator for this asset
        getValidatorInfo[_validator].collateralPools[_collateral].stakedAmount -= _slashAmount;
        emit SlashedValidatorCollateral(_validator, _collateral, _slashAmount);
    }

    /**
    * @dev Slash validator rewards.
    * @param _validator Validator address.
    * @param _collateral Collateral address.
    * @param _bpsAmount Basis points to be slashed.
    */
    function slashValidatorRewards(
        address _validator,
        address _collateral,
        uint256 _bpsAmount
    ) public onlyAdmin { // TODO: either make this method internal and call in liquidate, or remove and have arbitrary wallet (keeper) call exchangeValidatorRewards prior to slashing
        Collateral storage collateral = collaterals[_collateral];
        uint256 slashingFraction = _bpsAmount/BPS_DENOMINATOR;
        uint256 _slashAmount = getValidatorInfo[_validator].collateralPools[_collateral].rewardsForWithdrawal * slashingFraction;
        collateral.slashedAmount += _slashAmount;
        emit SlashedValidatorRewards(_validator, _collateral, _slashAmount);
    }

    // /**
    //  * @dev Stake token to strategies to earn rewards
    //  * @param _validator address of validator
    //  * @param _shares Shares to be staked
    //  * @param _strategy strategy to stake into.
    //  */
    // function depositToStrategy(address _validator, uint256 _shares, address _strategy, address _stakeToken)
    //     external
    //     nonReentrant
    //     whenNotPaused
    // {
    //     Strategy storage strategy = strategies[_strategy][_stakeToken];
    //     DelegatedStakingHelper._validateStrategy(strategy.isEnabled);
    //     IStrategy strategyController = IStrategy(_strategy);
    //     Collateral storage stakeCollateral = collaterals[strategy.stakeToken];
    //     ValidatorInfo storage validator = getValidatorInfo[_validator];
    //     ValidatorCollateral storage validatorCollateral = validator.collateralPools[_stakeToken];

    //     DelegatorsInfo storage delegator = validator.delegators[msg.sender];
    //     DelegatedStakingHelper._validateDelegator(delegator.exists);
    //     DelegatorsInfo storage delegation = validatorCollateral.delegation[msg.sender];
    //     uint256 _amount = DelegatedStakingHelper._calculateFromShares(
    //         _shares,
    //         validatorCollateral.stakedAmount,
    //         validatorCollateral.shares
    //     );
    //     DelegatedStakingHelper._validateGtE(
    //         delegation.shares
    //         - delegation.locked,
    //         _shares
    //     );
    //     delegation.locked += _shares;
    //     validatorCollateral.locked += _shares;

    //     IERC20(strategy.stakeToken).safeApprove(address(strategyController), 0);
    //     IERC20(strategy.stakeToken).safeApprove(address(strategyController), _amount);
    //     strategy.totalReserves = strategyController.updateReserves(address(this), strategy.strategyToken);
    //     strategyController.deposit(strategy.stakeToken, _amount);
    //     uint256 afterBalance = strategyController.updateReserves(address(this), strategy.strategyToken);
    //     uint256 receivedAmount = afterBalance - strategy.totalReserves;
    //     strategy.totalReserves = strategyController.updateReserves(address(this), strategy.strategyToken);
    //     uint256 shares = strategy.totalShares > 0
    //         ? DelegatedStakingHelper._calculateShares(receivedAmount, strategy.totalShares, strategy.totalReserves)
    //         : receivedAmount;
    //     strategy.totalShares += shares;
    //     strategy.totalReserves = strategyController.updateReserves(address(this), strategy.strategyToken);
    //     delegation.strategyShares[_strategy] += shares;
    //     validatorCollateral.strategyShares[_strategy] += shares;
    //     stakeCollateral.totalLocked -= _amount;
    //     emit DepositedToStrategy(_validator, msg.sender, _amount, _strategy, strategy.stakeToken);
    // }

    // /**
    //  * @dev Withdraw token from strategies to claim rewards
    //  * @param _validator address of validator
    //  * @param _shares number of shares to redeem
    //  * @param _strategy strategy to withdraw from.
    //  */
    // function withdrawFromStrategy(address _validator, uint256 _shares, address _strategy, address _stakeToken)
    //     external
    //     nonReentrant
    //     whenNotPaused
    // {
    //     Strategy storage strategy = strategies[_strategy][_stakeToken];
    //     DelegatedStakingHelper._validateStrategy(strategy.isEnabled);
    //     ValidatorInfo storage validator = getValidatorInfo[_validator];
    //     ValidatorCollateral storage validatorCollateral = validator.collateralPools[_stakeToken];
    //     DelegatorsInfo storage delegator = validator.delegators[msg.sender];
    //     DelegatedStakingHelper._validateDelegator(delegator.exists);
    //     DelegatorsInfo storage delegation = validatorCollateral.delegation[msg.sender];
    //     uint256 beforeBalance = IERC20(strategy.stakeToken).balanceOf(address(this));
    //     strategy.totalReserves = IStrategy(_strategy).updateReserves(address(this), strategy.strategyToken);
    //     uint256 stakeTokenAmount = DelegatedStakingHelper._calculateFromShares(
    //         _shares, strategy.totalReserves, strategy.totalShares
    //     );

    //     { // scope to avoid stack too deep errors
    //         DelegatedStakingHelper._validateGtE(delegation.strategyShares[_strategy], _shares);
    //         delegation.strategyShares[_strategy] -= _shares;
    //         validatorCollateral.strategyShares[_strategy] -= _shares;
    //         strategy.totalShares -= _shares;
    //         IERC20(strategy.strategyToken).safeApprove(address(_strategy), 0);
    //         IERC20(strategy.strategyToken).safeApprove(address(_strategy), stakeTokenAmount);
    //         IStrategy(_strategy).withdraw(strategy.stakeToken, stakeTokenAmount);
    //     }
    //     uint256 receivedAmount = IERC20(strategy.stakeToken).balanceOf(address(this)) - beforeBalance;
    //     collaterals[strategy.stakeToken].totalLocked += receivedAmount;
    //     strategy.totalReserves = IStrategy(_strategy).updateReserves(address(this), strategy.strategyToken);
    //     uint256 rewardAmount = receivedAmount - stakeTokenAmount;
    //     collaterals[strategy.stakeToken].rewards += rewardAmount;
    //     strategy.rewards += rewardAmount;
    //     validatorCollateral.accumulatedRewards += rewardAmount;
    //     delegation.accumulatedRewards += rewardAmount;
    //     uint256 rewardShares = validatorCollateral.shares > 0
    //     ? DelegatedStakingHelper._calculateShares(rewardAmount, validatorCollateral.shares,
    //         validatorCollateral.stakedAmount)
    //     : rewardAmount;
    //     uint256 stakeTokenShares = DelegatedStakingHelper._calculateShares(
    //         stakeTokenAmount,
    //         validatorCollateral.shares,
    //         validatorCollateral.stakedAmount
    //     );
    //     delegation.shares += rewardShares;
    //     delegation.locked -= stakeTokenShares;
    //     validatorCollateral.locked -= stakeTokenShares;
    //     validatorCollateral.stakedAmount += rewardAmount;
    //     validatorCollateral.shares += rewardShares;
    //     emit WithdrawnFromStrategy(_validator, msg.sender, receivedAmount, _strategy, strategy.stakeToken);
    // }

    // /**
    //  * @dev Recovers user share of all funds emergency withdrawn from the strategy.
    //  * @param _strategy Strategy to recover from.
    //  * @param _stakeToken Address of collateral.
    //  * @param _validators Array of validator addresses.
    //  */
    // function recoverFromEmergency(address _strategy, address _stakeToken, address[] calldata _validators)
    //     external
    //     nonReentrant
    //     whenNotPaused
    // {
    //     _recoverFromEmergency(_strategy, _stakeToken, _validators);
    // }

    // /**
    //  * @dev Recovers user share of all funds emergency withdrawn from the strategy.
    //  * @param _strategy Strategy to recover from.
    //  * @param _stakeToken Address of collateral.
    //  * @param _validators Array of validator addresses.
    //  */
    // function _recoverFromEmergency(address _strategy, address _stakeToken, address[] memory _validators) internal {
    //     Strategy storage strategy = strategies[_strategy][_stakeToken];
    //     require(!strategy.isEnabled, "strategy enabled");
    //     require(strategy.isRecoverable, "not recoverable");
    //     for (uint256 i=0; i<_validators.length; i++) {
    //         ValidatorInfo storage validator = getValidatorInfo[_validators[i]];
    //         ValidatorCollateral storage validatorCollateral = validator.collateralPools[_stakeToken];
    //         strategy.totalReserves = IStrategy(_strategy).updateReserves(address(this), strategy.strategyToken);
    //         uint256 amount = DelegatedStakingHelper._calculateFromShares(
    //             validatorCollateral.strategyShares[_strategy], strategy.totalReserves, strategy.totalShares
    //         );
    //         uint256 fullAmount = DelegatedStakingHelper._calculateFromShares(
    //             validatorCollateral.locked, validatorCollateral.stakedAmount, validatorCollateral.shares);
    //         uint256 lost = fullAmount - amount;
    //         strategy.totalShares -= validatorCollateral.strategyShares[_strategy];
    //         validatorCollateral.locked -= validatorCollateral.strategyShares[_strategy];
    //         validatorCollateral.stakedAmount -= lost;
    //         validatorCollateral.strategyShares[_strategy] = 0;
    //         strategy.totalReserves -= amount;

    //         for (uint256 k=0; k<validator.delegatorCount; k++) {
    //             DelegatorsInfo storage delegation = validatorCollateral.delegation[validator.delegatorAddresses[k]];
    //             if (delegation.strategyShares[_strategy] == 0) continue;
    //             delegation.locked -= delegation.strategyShares[_strategy];
    //             delegation.strategyShares[_strategy] = 0;
    //         }
    //         emit RecoveredFromEmergency(_validators[i], amount, _strategy, strategy.stakeToken);
    //     }
    // }

    /**
     * @dev set basis points of profit sharing
     * @param _validator address of validator
     * @param _profitSharingBPS profit sharing basis points
     */
    function setProfitSharing(address _validator, uint256 _profitSharingBPS) external nonReentrant whenNotPaused {
        ValidatorInfo storage validator = getValidatorInfo[_validator];
        if (validator.admin != msg.sender) revert AdminBadRole();
        if (_profitSharingBPS < minProfitSharingBPS
            || _profitSharingBPS > BPS_DENOMINATOR) revert WrongArgument();
        validator.profitSharingBPS = _profitSharingBPS;
    }

    /**
     * @dev Receive protocol rewards.
     * @param _rewardToken Address of reward token.
     * @param _amount Amount of reward tokem.
     */
    function sendRewards(
        address _rewardToken,
        uint256 _amount
    ) external nonReentrant whenNotPaused {
        if (!collaterals[_rewardToken].isEnabled) revert CollateralDisabled();
        IERC20(_rewardToken).safeTransferFrom(msg.sender, address(this), _amount);
        getRewardsInfo[_rewardToken].totalAmount += _amount;

        emit RewardsReceived(_rewardToken, _amount);

        console.log("_amount %s", _amount);
        console.log("getRewardsInfo[_rewardToken].totalAmount %s", getRewardsInfo[_rewardToken].totalAmount);
        console.log("getRewardsInfo[_rewardToken].distributed %s", getRewardsInfo[_rewardToken].distributed);
    }

    /**
     * @dev Calculates rewards to swapped and credited to validators collateral
     * @param _rewardToken address of reward token
     * @param _rewardAmount amount of reward token
     */
    function _calculateValidatorRewards(address _rewardToken, uint256 _rewardAmount) internal returns (uint256[] memory, uint256[][] memory) {
        uint256[] memory collectedRewards = new uint256[](collateralAddresses.length);
        uint256[][] memory validatorRewards = new uint256[][](validatorAddresses.length);
        for (uint256 v = 0; v < validatorAddresses.length; v++) {
            address validatorAddress = validatorAddresses[v];
            ValidatorInfo storage validator = getValidatorInfo[validatorAddress];
            uint256 validatorAmount = validator.rewardWeightCoefficient * _rewardAmount / weightCoefficientDenominator;
            uint256 delegatorsAmount = validatorAmount * validator.profitSharingBPS / BPS_DENOMINATOR;

            (uint256[] memory poolsUSDAmounts, uint256 totalUSDAmount) = getTotalUSDAmount(validatorAddress);

            uint256[] memory tempValidatorRewards = new uint256[](collateralAddresses.length);
            for (uint256 c = 0; c < collateralAddresses.length; c++) {
                address collateralAddress = collateralAddresses[c];
                uint256 delegatorReward = delegatorsAmount * poolsUSDAmounts[c] / totalUSDAmount;
                if (_rewardToken == collateralAddress) {
                    ValidatorCollateral storage validatorRewardCollateral = validator.collateralPools[_rewardToken];
                    uint256 validatorReward = validatorAmount - delegatorsAmount;
                    validatorRewardCollateral.stakedAmount += delegatorReward;
                    validatorRewardCollateral.accumulatedRewards += validatorAmount;
                    validatorRewardCollateral.rewardsForWithdrawal += validatorReward;
                    tempValidatorRewards[c] = 0;
                    collectedRewards[c] += 0;
                } else {
                    tempValidatorRewards[c] = delegatorReward;
                    collectedRewards[c] += delegatorReward;
                }
            }
            validatorRewards[v] = tempValidatorRewards;
        }
        return (collectedRewards, validatorRewards);
    }

    /**
     * @dev Distributes validator rewards to validator/delegators
     * @param _rewardToken address of reward token
     */
    function distributeValidatorRewards(address _rewardToken) external nonReentrant whenNotPaused {
        Collateral storage rewardCollateral = collaterals[_rewardToken];
        if (!rewardCollateral.isEnabled) revert CollateralDisabled();

        RewardInfo storage rewardInfo = getRewardsInfo[_rewardToken];
        uint256 _rewardAmount = rewardInfo.totalAmount - rewardInfo.distributed;
        if (_rewardAmount == 0) revert ZeroAmount();
        rewardInfo.distributed += _rewardAmount;

        // we need to know how much tokens to swap for each pool;
        // Sample
        //         bob			        david			        sarah
        //        LINK	USDC	USDT	LINK	USDC	USDT	LINK	USDC	USDT

        // ALICE  2000	10000	10000	1000	10000	10000	1000	10000	10000

        // EVE	  1000	10000	10000	1000	20000	10000	1000	10000	10000

        // SAM	  1000	10000	10000	1000	10000	10000	1000	10000	20000
        // profitSharingBPS 50          75                      100
        // we distrubute reward 1800 USDT (600 USDT for each validator)
        // bob will have 300 usdt and his validators 300 usdt
        // link price 25 usd
        // bob                  LINK	                    USDC	            USDT
        // Pool cost in USD     4000*25=100000                      30000               30000
        // will receive usdt    100000*300/160000=187,5     56,25               56,25
        // we need to swap  187,5 usdt to link and just increment link collateral.totalStaked += receivedLinkAmount;
        // we need to swap  56,25 usdt to usdc and just increment usdc collateral.totalStaked += receivedUSDCAmount;
        // We don't need to create swap for each validators pool. Firs we need to calulate total Link to swap

        uint256[] memory collectedRewards = new uint256[](collateralAddresses.length);
        uint256[][] memory validatorRewards = new uint256[][](validatorAddresses.length);
        (collectedRewards, validatorRewards) = _calculateValidatorRewards(_rewardToken, _rewardAmount);

        for (uint256 cc=0; cc<collateralAddresses.length; cc++) {
            address currentCollateral = collateralAddresses[cc];
            uint256 swapAmount = collectedRewards[cc];
            if (currentCollateral == _rewardToken || swapAmount == 0) continue;
            IERC20(_rewardToken).safeApprove(address(feeProxy), 0);
            IERC20(_rewardToken).safeApprove(address(feeProxy), swapAmount);
            uint256 amountOut = feeProxy.swap(_rewardToken, currentCollateral, address(this), swapAmount);
            collaterals[currentCollateral].totalLocked += amountOut;
            collaterals[currentCollateral].rewards += amountOut;
            // now we need to split amountOut for each current collateral between validator pools
            uint256 postSwapRewardAmount;
            for (uint256 vv=0; vv<validatorAddresses.length; vv++) {
                ValidatorInfo storage validator = getValidatorInfo[validatorAddresses[vv]];
                postSwapRewardAmount = validatorRewards[vv][cc] * amountOut / collectedRewards[cc];
                ValidatorCollateral storage validatorCollateral = validator.collateralPools[currentCollateral];
                validatorCollateral.stakedAmount += postSwapRewardAmount;
                validatorCollateral.accumulatedRewards += postSwapRewardAmount;
            }
        }
        emit RewardsDistributed(_rewardToken, _rewardAmount);
    }

    function exchangeValidatorRewards(
        address _validator,
        address _collateral
    ) external nonReentrant whenNotPaused {
        ValidatorInfo storage validator = getValidatorInfo[_validator];
        if (validator.delegatorActionPaused) revert DelegatorActionPaused();
        ValidatorCollateral storage validatorCollateral = validator.collateralPools[_collateral];
        DelegatorsInfo storage admin = validatorCollateral.delegators[validator.admin];
        uint256 rewardAmount = validatorCollateral.rewardsForWithdrawal;
        uint256 rewardShares = DelegatedStakingHelper._calculateShares(rewardAmount, validatorCollateral.shares, validatorCollateral.stakedAmount);

        validatorCollateral.rewardsForWithdrawal -= rewardAmount;
        collaterals[_collateral].totalLocked += rewardAmount;
        validatorCollateral.stakedAmount += rewardAmount;
        validatorCollateral.shares += rewardShares;
        admin.accumulatedRewards += rewardAmount;
        admin.shares += rewardShares;
        emit ValidatorRewardsExchanged(
            _validator,
            validator.admin,
            msg.sender,
            _collateral,
            rewardAmount);
    }

    /* ADMIN */

    // /**
    //  * @dev Withdraws all funds from the strategy.
    //  * @param _strategy Strategy to withdraw from.
    //  */
    // function emergencyWithdrawFromStrategy(address _strategy, address _stakeToken)
    //     external
    //     onlyAdmin
    // {
    //     Strategy storage strategy = strategies[_strategy][_stakeToken];
    //     DelegatedStakingHelper._validateStrategy(strategy.isEnabled);
    //     IStrategy strategyController = IStrategy(_strategy);
    //     Collateral storage stakeCollateral = collaterals[strategy.stakeToken];
    //     IERC20(strategy.strategyToken).safeApprove(address(_strategy), 0);
    //     IERC20(strategy.strategyToken).safeApprove(address(_strategy), type(uint256).max);
    //     uint256 beforeBalance = strategyController.updateReserves(address(this), strategy.stakeToken);
    //     strategyController.withdrawAll(strategy.stakeToken);
    //     uint256 afterBalance = strategyController.updateReserves(address(this), strategy.stakeToken);
    //     uint256 receivedAmount = afterBalance - beforeBalance;
    //     stakeCollateral.totalLocked += receivedAmount;
    //     strategy.totalReserves = receivedAmount;
    //     strategy.isEnabled = false;
    //     strategy.isRecoverable = true;
    //     emit EmergencyWithdrawnFromStrategy(receivedAmount, _strategy, strategy.stakeToken);
    // }

    // function resetStrategy(address _strategy, address _stakeToken)
    //     external
    //     onlyAdmin
    // {
    //     Strategy storage strategy = strategies[_strategy][_stakeToken];
    //     require(!strategy.isEnabled, "strategy enabled");
    //     _recoverFromEmergency(_strategy, _stakeToken, validatorAddresses);
    //     strategy.totalReserves = 0;
    //     strategy.totalShares = 0;
    //     strategy.isEnabled = true;
    //     strategy.isRecoverable = false;
    //     emit StrategyReset(_strategy, strategy.stakeToken);
    // }

    /**
     * @dev Change withdrawal timelock.
     * @param _newTimelock New timelock.
     */
    function setWithdrawTimelock(uint256 _newTimelock) external onlyAdmin {
        withdrawTimelock = _newTimelock;
        emit WithdrawTimelockUpdated(_newTimelock);
    }

    /**
     * @dev set min basis points of profit sharing
     * @param _profitSharingBPS profit sharing basis points
     */
    function setMinProfitSharing(uint256 _profitSharingBPS) external onlyAdmin {
        if (_profitSharingBPS > BPS_DENOMINATOR) revert WrongArgument();
        for (uint256 i=0; i<validatorAddresses.length; i++) {
            ValidatorInfo storage validator = getValidatorInfo[validatorAddresses[i]];
            if (validator.profitSharingBPS < _profitSharingBPS) {
                validator.profitSharingBPS = _profitSharingBPS;
            }
        }
        minProfitSharingBPS = _profitSharingBPS;
    }

    /**
     * @dev Confiscate collateral.
     * @param _validator Validator address.
     * @param _collaterals Collateral addresses.
     * @param _bpsAmount Basis points to slash.
     */
    function liquidate(address _validator, address[] calldata _collaterals, uint256 _bpsAmount) external onlyAdmin {
        ValidatorInfo storage validator = getValidatorInfo[_validator];
        uint256 _delegatorBPS = validator.profitSharingBPS * _bpsAmount / BPS_DENOMINATOR;
        uint256 validatorBPS = _bpsAmount - _delegatorBPS;

        for (uint256 i=0; i<_collaterals.length; i++) {
            address _collateral = _collaterals[i];
            uint256 delegatorBPS = _delegatorBPS;
            ValidatorCollateral storage validatorCollateral = validator.collateralPools[_collateral];
            DelegatorsInfo storage adminCollateral = validatorCollateral.delegators[validator.admin];
            Collateral storage collateral = collaterals[_collateral];
            uint256 totalSlashed;
            // slash admin start
            if (adminCollateral.shares/validatorCollateral.shares < validatorBPS) {
                _liquidateDelegator(_validator, validator.admin, _collateral, BPS_DENOMINATOR);
                delegatorBPS += validatorBPS - adminCollateral.shares/validatorCollateral.shares;
            } else {
                _liquidateDelegator(_validator, validator.admin, _collateral, validatorBPS);
            }
            slashValidatorRewards(_validator, _collateral, validatorBPS);
            // slash admin end
            // slash strategy deposits
            totalSlashed += _slashValidatorCollateralStrategyDeposits(_validator, _collateral, delegatorBPS);
            // slash unlocked collateral
            uint256 slashedAmount = DelegatedStakingHelper._calculateFromShares(
                (validatorCollateral.shares - validatorCollateral.locked) * delegatorBPS / BPS_DENOMINATOR,
                validatorCollateral.stakedAmount,
                validatorCollateral.shares
            );
            validatorCollateral.stakedAmount -= slashedAmount;
            collateral.slashedAmount += slashedAmount;
            collateral.totalLocked -= slashedAmount;
            totalSlashed += slashedAmount;

            IERC20(_collateral).safeTransfer(slashingTreasury, totalSlashed);
            emit Liquidated(_validator, _collateral, totalSlashed);
        }
    }

    /**
     * @dev Confiscate delegator collateral.
     * @param _validator Validator address.
     * @param _delegator Delegator address.
     * @param _collateral Index of collateral.
     * @param _bpsAmount Basis points to slash.
     */
    function _liquidateDelegator(address _validator, address _delegator, address _collateral, uint256 _bpsAmount) internal {
        ValidatorInfo storage validator = getValidatorInfo[_validator];
        ValidatorCollateral storage validatorCollateral = validator.collateralPools[_collateral];
        DelegatorsInfo storage delegator = validatorCollateral.delegators[_delegator];
        Collateral storage collateral = collaterals[_collateral];
        uint256 slashingFraction = _bpsAmount/BPS_DENOMINATOR;
        uint256 totalSlashed;

        // slash strategy deposits
        _slashDelegatorStrategyDeposits(_validator, _delegator, _collateral, _bpsAmount);

        // slash delegation collateral start
        uint256 _shares = (validatorCollateral.shares - validatorCollateral.locked) * slashingFraction;
        uint256 slashedAmount = DelegatedStakingHelper._calculateFromShares(
            _shares,
            validatorCollateral.stakedAmount,
            validatorCollateral.shares
        );
        delegator.shares -= _shares;
        validatorCollateral.shares -= _shares;
        validatorCollateral.stakedAmount -= slashedAmount;
        collateral.slashedAmount += slashedAmount;
        collateral.totalLocked -= slashedAmount;
        totalSlashed += slashedAmount;
        // slash delegation collateral end

        IERC20(_collateral).safeTransfer(slashingTreasury, totalSlashed);
        emit LiquidatedDelegator(_validator, _delegator, _collateral, totalSlashed);
    }

    function liquidateDelegator(address _validator, address _delegator, address _collateral, uint256 _bpsAmount) external onlyAdmin {
        _liquidateDelegator(_validator, _delegator, _collateral, _bpsAmount);
    }

    /**
     * @dev Confiscates collateral deposited to strategy
     * @param _validator Validator address.
     * @param _collateral Collateral address.
     * @param _bpsAmount Basis points to slash.
     */
    function _slashValidatorCollateralStrategyDeposits(address _validator, address _collateral, uint256 _bpsAmount) internal returns(uint256) {
        Collateral storage collateral = collaterals[_collateral];
        ValidatorCollateral storage validatorCollateral = getValidatorInfo[_validator].collateralPools[_collateral];
        uint256 slashingFraction = _bpsAmount / BPS_DENOMINATOR;
        uint256 totalSlashed;
        for (uint256 j=0; j<strategyControllerAddresses.length; j++) {
            address _strategyController = strategyControllerAddresses[j];
            Strategy storage strategy = strategies[_strategyController][_collateral];
            uint256 beforeBalance = IERC20(_collateral).balanceOf(address(this));
            strategy.totalReserves = IStrategy(_strategyController).updateReserves(address(this), strategy.strategyToken);
            uint256 _strategyShares = validatorCollateral.strategyShares[_strategyController] * slashingFraction;
            uint256 stakeTokenCollateral = DelegatedStakingHelper._calculateFromShares(
                _strategyShares, strategy.totalReserves, strategy.totalShares
            );
            strategy.totalShares -= _strategyShares;
            IERC20(strategy.strategyToken).safeApprove(_strategyController, 0);
            IERC20(strategy.strategyToken).safeApprove(_strategyController, _strategyShares);
            IStrategy(_strategyController).withdraw(_collateral, _strategyShares);
            uint256 receivedAmount = IERC20(_collateral).balanceOf(address(this)) - beforeBalance;
            strategy.totalReserves = IStrategy(_strategyController).updateReserves(address(this), strategy.strategyToken);
            uint256 rewardAmount = receivedAmount - stakeTokenCollateral;
            collateral.rewards += rewardAmount;
            strategy.rewards += rewardAmount;
            validatorCollateral.stakedAmount -= stakeTokenCollateral;
            collateral.slashedAmount += receivedAmount;
            totalSlashed += receivedAmount;
        }
        return totalSlashed;
    }

    /**
     * @dev Confiscates delegator collateral deposited to strategy
     * @param _validator Validator address.
     * @param _delegator Delegator address.
     * @param _collateral Collateral address.
     * @param _bpsAmount Basis points to slash.
     */
    function _slashDelegatorStrategyDeposits(address _validator, address _delegator, address _collateral, uint256 _bpsAmount) internal returns(uint256) {
        ValidatorCollateral storage validatorCollateral = getValidatorInfo[_validator].collateralPools[_collateral];
        DelegatorsInfo storage delegator = validatorCollateral.delegators[_delegator];
        Collateral storage collateral = collaterals[_collateral];
        uint256 slashingFraction = _bpsAmount/BPS_DENOMINATOR;
        uint256 totalSlashed;
        for (uint i=0; i<strategyControllerAddresses.length; i++) {
            address _strategyController = strategyControllerAddresses[i];
            Strategy storage strategy = strategies[_strategyController][_collateral];
            uint256 beforeBalance = IERC20(_collateral).balanceOf(address(this));
            strategy.totalReserves = IStrategy(_strategyController).updateReserves(address(this), strategy.strategyToken);
            uint256 _strategyShares = delegator.strategyShares[_strategyController] * slashingFraction;
            uint256 stakeTokenCollateral = DelegatedStakingHelper._calculateFromShares(
                _strategyShares, strategy.totalReserves, strategy.totalShares
            );
            delegator.strategyShares[_strategyController] -= _strategyShares;
            validatorCollateral.strategyShares[_strategyController] -= _strategyShares;
            strategy.totalShares -= _strategyShares;
            IERC20(strategy.strategyToken).safeApprove(_strategyController, 0);
            IERC20(strategy.strategyToken).safeApprove(_strategyController, _strategyShares);
            IStrategy(_strategyController).withdraw(_collateral, _strategyShares);
            uint256 receivedAmount = IERC20(_collateral).balanceOf(address(this)) - beforeBalance;
            strategy.totalReserves = IStrategy(_strategyController).updateReserves(address(this), strategy.strategyToken);
            uint256 rewardAmount = receivedAmount - stakeTokenCollateral;
            uint256 slashedStrategyShares = validatorCollateral.shares > 0
                ? DelegatedStakingHelper._calculateShares(
                    stakeTokenCollateral,
                    validatorCollateral.shares,
                    validatorCollateral.stakedAmount)
                : stakeTokenCollateral;
            collateral.rewards += rewardAmount;
            strategy.rewards += rewardAmount;
            delegator.shares -= slashedStrategyShares;
            validatorCollateral.shares -= slashedStrategyShares;
            delegator.locked -= slashedStrategyShares;
            validatorCollateral.locked -= slashedStrategyShares;
            validatorCollateral.stakedAmount -= stakeTokenCollateral;
            collateral.slashedAmount += receivedAmount;
            totalSlashed += receivedAmount;
        }
        return totalSlashed;
    }

    /**
     * @dev Updates slashing treasury address.
     * @param _newTreasury New slashing treasury address.
     */
    function updateSlashingTreasury(address _newTreasury) external onlyAdmin {
        slashingTreasury = _newTreasury;
        emit UpdateSlashingTreasury(_newTreasury);
    }

    /**
     * @dev Add new validator.
     * @param _validator Validator address.
     * @param _admin Admin address.
     */
    function addValidator(
        address _validator,
        address _admin,
        uint256 _rewardWeightCoefficient,
        uint256 _profitSharingBPS
    )   external
        onlyAdmin
    {
        if (_profitSharingBPS < minProfitSharingBPS
            || _profitSharingBPS > BPS_DENOMINATOR) revert WrongArgument();

        ValidatorInfo storage validator = getValidatorInfo[_validator];
        if (!validator.exists) {
            validatorAddresses.push(_validator);
        }
        validator.admin = _admin;
        validator.rewardWeightCoefficient = _rewardWeightCoefficient;
        weightCoefficientDenominator += _rewardWeightCoefficient;
        validator.profitSharingBPS = _profitSharingBPS;
        validator.exists = true;
        validator.isEnabled = true;
    }

    /**
     * @dev Update validator enabled status.
     * @param _validator Validator address.
     * @param _isEnabled Is validator enabled.
     */
    function updateValidator(address _validator, bool _isEnabled) external onlyAdmin {
        ValidatorInfo storage validator = getValidatorInfo[_validator];
        if (!validator.exists || validator.isEnabled == _isEnabled) revert WrongArgument();
        // If we enable validator
        if(_isEnabled){
            validatorAddresses.push(_validator);
        }
        // If we disable validator
        else {
            for (uint256 i=0; i< validatorAddresses.length; i++) {
                if (validatorAddresses[i] == _validator) {
                    validatorAddresses[i] = validatorAddresses[validatorAddresses.length - 1];
                    validatorAddresses.pop();
                }
            }
        }
        validator.isEnabled = _isEnabled;
        emit EnableValidator(_validator, _isEnabled);
    }

    /**
     * @dev Add a new collateral
     * @param _token Address of token
     */
    function addCollateral(
        address _token,
        bool _isUSDStable,
        uint256 _maxStakeAmount
    ) external onlyAdmin {
        Collateral storage collateral = collaterals[_token];
        if (collateral.exists) revert AlreadyExists();

        collateral.exists = true;
        collateral.isEnabled = true;
        collateral.isUSDStable = _isUSDStable;
        collateral.decimals = ERC20(_token).decimals();
        collateral.maxStakeAmount = _maxStakeAmount;
        collateralAddresses.push(_token);
    }

    /**
     * @dev Update collateral enabled
     * @param _collateral address of collateral
     * @param _isEnabled bool of enable
     */
    function updateCollateralEnabled(address _collateral, bool _isEnabled) external onlyAdmin {
        Collateral storage collateral = collaterals[_collateral];
        if (!collateral.exists || collateral.isEnabled == _isEnabled) revert WrongArgument();
        if(_isEnabled){
            collateralAddresses.push(_collateral);
        }
        else {
            for (uint256 i=0; i< collateralAddresses.length; i++) {
                if (collateralAddresses[i] == _collateral) {
                    collateralAddresses[i] = collateralAddresses[collateralAddresses.length - 1];
                    collateralAddresses.pop();
                }
            }
        }
        collateral.isEnabled = _isEnabled;
        emit UpdateCollateralEnabled(_collateral, _isEnabled);
    }

    /**
     * @dev update collateral max amount
     * @param _collateral address of collateral
     * @param _maxStakeAmount max amount
     */
    function updateCollateral(address _collateral, uint256 _maxStakeAmount) external onlyAdmin {
        collaterals[_collateral].maxStakeAmount = _maxStakeAmount;
        emit UpdateCollateral(_collateral, _maxStakeAmount);
    }

    /**
    * @dev update validator reward weight coefficient
    * @param _validator address of validator
    * @param _value reward weight coefficient
    */
    function updateRewardWeight(address _validator, uint256 _value) external onlyAdmin {
        ValidatorInfo storage validator = getValidatorInfo[_validator];
        weightCoefficientDenominator -= validator.rewardWeightCoefficient;
        validator.rewardWeightCoefficient = _value;
        weightCoefficientDenominator += _value;
        emit UpdateRewardWeight(_validator, _value);
    }

    /**
     * @dev Add a new strategy controller
     * @param _strategyController Strategy controller address
     */
    function addStrategyController(address _strategyController) external onlyAdmin {
        if (strategyControllerExists[_strategyController]) revert AlreadyExists();
        strategyControllerAddresses.push(_strategyController);
        strategyControllerExists[_strategyController] = true;
    }

    /**
     * @dev Add a new strategy
     * @param _strategyController address to strategy
     * @param _stakeToken collateralId of stakeToken
     * @param _rewardToken collateralId of rewardToken
     */
    function addStrategy(address _strategyController, address _stakeToken, address _rewardToken) external onlyAdmin {
        Strategy storage strategy = strategies[_strategyController][_stakeToken];
        if (strategy.exists)  revert AlreadyExists();
        strategy.stakeToken = _stakeToken;
        strategy.strategyToken = IStrategy(_strategyController).strategyToken(_stakeToken);
        strategy.rewardToken = _rewardToken;
        strategy.isEnabled = true;
        strategy.exists = true;
    }

    // /**
    //  * @dev enable strategy
    //  * @param _strategy address of strategy
    //  * @param _stakeToken address of token
    //  * @param _isEnabled bool of enable
    //  */
    // function updateStrategy(address _strategy, address _stakeToken, bool _isEnabled) external onlyAdmin {
    //     strategies[_strategy][_stakeToken].isEnabled = _isEnabled;
    // }

    // /**
    //  * @dev enable strategy recoverable
    //  * @param _strategy address of strategy
    //  * @param _stakeToken address of token
    //  * @param _isRecoverable bool of recoverable
    //  */
    // function updateStrategyRecoverable(address _strategy, address _stakeToken, bool _isRecoverable) external onlyAdmin {
    //     strategies[_strategy][_stakeToken].isRecoverable = _isRecoverable;
    // }

    /**
     * @dev Pause/unpause unstaking request.
     * @param _validator Validator address.
     * @param _withdrawIds Withdraw requests ids.
     * @param _paused pause/unpause.
     */
    function pauseUnstakeRequests(address _validator, uint256[] memory _withdrawIds, bool _paused) external onlyAdmin {
        WithdrawalRequests storage withdrawalRequests = getWithdrawalRequests[_validator];
        uint256 maxCount = withdrawalRequests.count;
        for (uint256 i = 0; i < _withdrawIds.length; i++) {
            uint256 currentWithdrawId = _withdrawIds[i];
            if (currentWithdrawId >= maxCount) revert WrongRequest(currentWithdrawId);
            WithdrawalInfo storage withdrawal = withdrawalRequests.withdrawals[currentWithdrawId];
            if (!withdrawal.executed) {
                 withdrawal.paused = _paused;
                 emit UnstakePaused(_validator, currentWithdrawId, _paused);
            }
        }
    }

    /**
     * @dev Set Price Consumer
     * @param _priceConsumer address of price consumer
     */
    function setPriceConsumer(IPriceConsumer _priceConsumer) external onlyAdmin {
        priceConsumer = _priceConsumer;
    }

    /**
     * @dev Set fee converter proxy.
     * @param _feeProxy Fee proxy address.
     */
    function setFeeProxy(IFeeProxy _feeProxy) external onlyAdmin() {
        feeProxy = _feeProxy;
    }

    /* internal & views */

    /**
     * @dev checks strategy reserves
     * @param _strategyController Strategy controller address
     * @param _validator Validator address
     * @param _collateral Collateral address
     */
    // NOTE: this doesnt work for multiple validators staked to same strategy as the gain/loss needs to be shared between them
    // function _checkReserves(address _strategyController, address _validator, address _collateral) internal {
    //     Strategy storage strategy = strategies[_strategyController][_collateral];
    //     ValidatorCollateral storage validatorCollateral = getValidatorInfo[_validator].collateralPools[_collateral];
    //     uint256 cachedReserves = strategy.totalReserves;
    //     strategy.totalReserves = IStrategy(_strategyController).updateReserves(address(this), strategy.strategyToken);
    //     if (strategy.totalReserves > cachedReserves) {
    //        uint256 additionalShares = DelegatedStakingHelper._calculateShares(
    //            strategy.totalReserves - cachedReserves,
    //            strategy.totalShares,
    //            strategy.totalReserves
    //        );
    //        validatorCollateral.strategyShares[_strategyController] += additionalShares;
    //        strategy.totalShares += additionalShares;
    //        validatorCollateral.locked += additionalShares;
    //     } else {
    //         uint256 reducedShares = DelegatedStakingHelper._calculateShares(
    //             cachedReserves - strategy.totalReserves,
    //             strategy.totalShares,
    //             strategy.totalReserves
    //         );
    //         validatorCollateral.strategyShares[_strategyController] -= reducedShares;
    //         strategy.totalShares -= reducedShares;
    //         validatorCollateral.locked -= reducedShares;
    //     }
    // }

    /**
     * @dev Get price per share
     * @param _strategy Address of strategy
     * @param _collateral Address of collateral
     */
    function getPricePerFullStrategyShare(address _strategy, address _stakeToken, address _collateral)
        external
        view
        returns (uint256)
    {
        if (strategies[_strategy][_stakeToken].totalShares == 0) revert ZeroAmount();
        uint256 totalStrategyTokenReserves = IStrategy(_strategy).updateReserves(address(this), _collateral);
        return totalStrategyTokenReserves/strategies[_strategy][_stakeToken].totalShares;
    }

    /**
     * @dev Get price per validator share
     * @param _validator Address of validator
     * @param _collateral Address of collateral
     */
    function getPricePerFullValidatorShare(address _validator, address _collateral)
        external
        view
        returns (uint256)
    {
        ValidatorCollateral storage validatorCollateral = getValidatorInfo[_validator].collateralPools[_collateral];
        if (validatorCollateral.shares == 0) revert ZeroAmount();
        return validatorCollateral.stakedAmount/validatorCollateral.shares;
    }

    /**
     * @dev Get USD amount of validator collateral
     * @param _validator Address of validator
     * @param _collateral Address of collateral
     * @return USD amount with decimals 18
     */
    function getPoolUSDAmount(address _validator, address _collateral) public view returns(uint256) {
        uint256 collateralPrice;
        Collateral storage collateral = collaterals[_collateral];
        if (collateral.isUSDStable)
            collateralPrice = 1e18;
        // All non-ETH (hence USD) pairs have 8 decimals, so pad output of priceConsumer to 18 decimals
        else collateralPrice = priceConsumer.getPriceOfToken(_collateral) * 1e10;

        return getValidatorInfo[_validator].collateralPools[_collateral].stakedAmount * collateralPrice
                / (10 ** collateral.decimals);
    }

    /**
     * @dev Get total USD amount of validator collateral
     * @param _validator Address of validator
     */
    function getTotalUSDAmount(address _validator) public view
        returns (uint256[] memory poolsUSDAmounts, uint256 totalUSDAmount
    ) {
        poolsUSDAmounts = new uint256[](collateralAddresses.length);
        for (uint256 i = 0; i < collateralAddresses.length; i++) {
            uint256 poolUSDAmount = getPoolUSDAmount(_validator, collateralAddresses[i]);
            totalUSDAmount += poolUSDAmount;
            poolsUSDAmounts[i] = poolUSDAmount;
        }
        console.log("getTotalUSDAmount %s totalUSDAmount: %s", _validator, totalUSDAmount);
        return (poolsUSDAmounts, totalUSDAmount);
    }

    /**
     * @dev Get withdrawal request.
     * @param _delegator Delegator address.
     * @param _withdrawalId Withdrawal identifier.
     */
    function getWithdrawalRequest(address _delegator, uint256 _withdrawalId)
        external
        view
        returns (WithdrawalInfo memory)
    {
        return getWithdrawalRequests[_delegator].withdrawals[_withdrawalId];
    }

    /**
     * @dev Get strategy info
     * @param _strategy Strategy address
     * @param _stakeToken Stake token address
     */
    function getStrategy(address _strategy, address _stakeToken) external view returns (Strategy memory) {
        return strategies[_strategy][_stakeToken];
    }

    /**
     * @dev get delegator, collateral and protocol rewards
     * @param _validator address of validator
     * @param _collateral Address of collateral
     */
    function getRewards(address _validator, address _collateral)
        external
        view
        returns(uint256, uint256)
    {
        return(
            getValidatorInfo[_validator].collateralPools[_collateral].accumulatedRewards,
            collaterals[_collateral].rewards
        );
    }

    function getValidatorCollateral(address _validator, address _collateral) external view
    returns(
        uint256 stakedAmount,
        uint256 shares,
        uint256 locked,
        uint256 accumulatedRewards,
        uint256 rewardsForWithdrawal
    ) {
         ValidatorCollateral storage item = getValidatorInfo[_validator].collateralPools[_collateral];
         return (
            item.stakedAmount, // total tokens staked by delegators
            item.shares, // total share of collateral tokens
            item.locked, // total share locked by depositing to strategy
            item.accumulatedRewards, // how many reward tokens was earned
            item.rewardsForWithdrawal // how many reward tokens validator can withdrawal
         );
    }


    /**
    * @dev get delegator stakes: returns whether shares, locked shares and passed rewards
    * @param _validator address of validator
    * @param _collateral Address of collateral
    * @param _delegator address of delegator
    */
    function getDelegatorsInfo(address _validator, address _collateral, address _delegator) external view
    returns(
        uint256 shares, // delegator share of collateral tokens
        uint256 locked, // share locked by depositing to strategy
        // uint256 passedRewards, // rewards per collateral address, calculated before stake
        uint256 accumulatedRewards //info how many reward tokens were earned
    ) {
         DelegatorsInfo storage item =  getValidatorInfo[_validator].collateralPools[_collateral].delegators[_delegator];
         return (
            item.shares, // delegator share of collateral tokens
            item.locked, // share locked by depositing to strategy
            // item.passedRewards, // rewards per collateral address, calculated before stake
            item.accumulatedRewards //info how many reward tokens were earned
         );
    }

    /**
     * @dev Get total stake to strategy: returns total reserve amount, total shares and total rewards
     * @param _strategy Address of strategy
     */
    function getStrategyStakes(address _strategy, address _stakeToken) external view returns(uint256, uint256, uint256) {
        return (
            strategies[_strategy][_stakeToken].totalReserves,
            strategies[_strategy][_stakeToken].totalShares,
            strategies[_strategy][_stakeToken].rewards
        );
    }

    /**
     * @dev Gets total strategy shares for validator
     * @param _validator Validator address
     * @param _strategy Strategy address
     */
    function getStrategyDepositInfo(address _validator, address _strategy, address _stakeToken)
        external
        view
        returns(uint256)
    {
        return getValidatorInfo[_validator].collateralPools[_stakeToken].strategyShares[_strategy];
    }

    /**
     * @dev Gets delegator strategy shares
     * @param _validator Validator address
     * @param _delegator Delegator address
     * @param _strategy Strategy address
     */
    function getStrategyDepositInfo(address _validator, address _delegator, address _strategy, address _stakeToken)
        external
        view
        returns(uint256)
    {
        return getValidatorInfo[_validator].collateralPools[_stakeToken].delegators[_delegator].strategyShares[_strategy];
    }
}
