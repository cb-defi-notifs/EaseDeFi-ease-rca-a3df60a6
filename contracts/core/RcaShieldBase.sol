/// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.11;
import '../general/Governable.sol';
import '../interfaces/IZapper.sol';
import '../interfaces/IRcaController.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import 'hardhat/console.sol';

/**
 * @title RCA Vault
 * @notice Main contract for reciprocally-covered assets. Mints, redeems, and sells.
 * Each underlying token (not protocol) has its own RCA vault. This contract
 * doubles as the vault and the RCA token.
 * @dev This contract assumes uToken decimals of 18.
 * @author Robert M.C. Forster & Romke Jonker
**/
abstract contract RcaShieldBase is ERC20, Governable {
    using SafeERC20 for IERC20;

    uint256 constant YEAR_SECS = 31536000;
    uint256 constant DENOMINATOR = 10000;

    /// @notice Controller of RCA contract that takes care of actions.
    IRcaController public controller;
    /// @notice Underlying token that is protected by the shield.
    IERC20 public uToken;
    /// @notice Percent to pay per year. 1000 == 10%.
    uint256 public apr;
    /// @notice Current sale discount to sell tokens cheaper.
    uint256 public discount;
    /// @notice Treasury for all funds that accepts payments.
    address payable public treasury;
    /// @notice Percent of the contract that is currently paused and cannot be withdrawn.
    /// Set > 0 when a hack has happened and DAO has not submitted for sales.
    /// Withdrawals during this time will lose this percent. 1000 == 10%.
    uint256 public percentReserved;

    /** 
     * @notice Cumulative total amount that has been liquidated lol.
     * @dev Used to make sure we don't run into a situation where liq amount isn't updated,
     * a new hack occurs and current liq is added to, then current liq is updated while
     * DAO votes on the new total liq. In this case we can subtract that interim addition.
     */
    uint256 public cumLiqForClaims;
    /// @notice Amount of tokens currently up for sale.
    uint256 public amtForSale;

    /** 
     * @notice Amount of underlying tokens pending withdrawal. 
     * @dev When doing value calculations this is required because RCAs are burned immediately 
     * upon request, but underlying tokens only leave the contract once the withdrawal is finalized.
     */
    uint256 public pendingWithdrawal;
    /// @notice withdrawal variable for withdrawal delays.
    uint256 public withdrawalDelay;
    /// @notice Requests by users for withdrawals.
    mapping (address => WithdrawRequest) public withdrawRequests;

    /** 
     * @notice Last time the contract has been updated.
     * @dev Used to calculate APR if fees are implemented.
     */
    uint256 lastUpdate;

    struct WithdrawRequest {
        uint112 uAmount;
        uint112 rcaAmount;
        uint32  endTime;
    }

    /// @notice Notification of the mint of new tokens.
    event Mint(address indexed sender, address indexed to, uint256 uAmount, uint256 rcaAmount, uint256 timestamp);
    /// @notice Notification of an initial redeem request.
    event RedeemRequest(address indexed user, uint256 uAmount, uint256 rcaAmount, uint256 endTime, uint256 timestamp);
    /// @notice Notification of a redeem finalization after withdrawal delay.
    event RedeemFinalize(address indexed user,address indexed to, uint256 uAmount, uint256 rcaAmount, uint256 timestamp);
    /// @notice Notification of a purchase of the underlying token.
    event PurchaseU(address indexed to, uint256 uAmount,uint256 ethAmount, uint256 price, uint256 timestamp);
    /// @notice Notification of a purchase of an RCA token.
    event PurchaseRca(address indexed to,uint256 uAmount,uint256 rcaAmount, uint256 ethAmount, uint256 price, uint256 timestamp);

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////// modifiers //////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Restrict set functions to only controller for many variables.
     */
    modifier onlyController()
    {
        require(msg.sender == address(controller), "Function must only be called by controller.");
        _;
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////// constructor ////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Construct shield and RCA ERC20 token.
     * @param _name Name of the RCA token.
     * @param _symbol Symbol of the RCA token.
     * @param _uToken Address of the underlying token.
     * @param _governor Address of the governor (owner) of the shield.
     * @param _controller Address of the controller that maintains the shield.
     */
    constructor(
        string  memory _name,
        string  memory _symbol,
        address _uToken,
        address _governor,
        address _controller
    )
    ERC20(
        _name,
        _symbol
    )
    {
        initializeGovernable(_governor);
        uToken = IERC20(_uToken);
        controller = IRcaController(_controller);
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////// initialize /////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Controller calls to initiate which sets current contract variables. All %s are 1000 == 10%.
     * @param _apr Fees for using the RCA ecosystem.
     * @param _discount Discount for purchases while tokens are being liquidated.
     * @param _treasury Address of the treasury to which Ether from fees and liquidation will be sent.
     * @param _withdrawalDelay Delay of withdrawals from the shield in seconds.
     */
    function initialize(
        uint256 _apr,
        uint256 _discount,
        address payable _treasury,
        uint256 _withdrawalDelay
    )
      external
      onlyController
    {
        require(treasury == address(0), "Contract has already been initialized.");
        apr = _apr;
        discount = _discount;
        treasury = _treasury;
        withdrawalDelay = _withdrawalDelay;
        lastUpdate = block.timestamp;
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////// external //////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /// Get reward of a protocol includes rewards
    function getReward(IERC20[] memory _tokens) public virtual;

    /**
     * @notice Mint tokens to an address. Not automatically to msg.sender so we can more easily zap assets.
     * @param _user The user to mint tokens to.
     * @param _uAmount Amount of underlying tokens desired to use for mint.
     * @param _capacity Capacity of the vault (in underlying tokens).
     * @param _capacityProof Merkle proof to verify capacity.
     * @param _newCumLiqForClaims New total cumulative liquidated if there is one.
     * @param _liqForClaimsProof Merkle proof to verify cumulative liquidated.
     */
    function mintTo(
        address   _user,
        uint256   _uAmount,
        uint256   _capacity,
        bytes32[] calldata _capacityProof,
        uint256   _newCumLiqForClaims,
        bytes32[] calldata _liqForClaimsProof
    )
      external
    {
        // Call controller to check capacity limits, add to capacity limits, emit events, check for new "for sale".
        controller.mint(
            _user,
            _uAmount,
            _capacity,
            _capacityProof,
            _newCumLiqForClaims,
            _liqForClaimsProof
        );

        // Only update fees after potential contract update.
        _update();

        uint256 rcaAmount = _rcaValue(_uAmount, amtForSale);
        uToken.safeTransferFrom(msg.sender, address(this), _uAmount);
        _mint(_user, rcaAmount);

        _afterMint(_uAmount);

        emit Mint(
            msg.sender,
            _user,
            _uAmount,
            rcaAmount,
            block.timestamp
        );
    }

    /**
     * @notice Request redemption of RCAs back to the underlying token. Has a withdrawal delay so it's 2 parts (request and finalize).
     * @param _rcaAmount The amount of tokens (in RCAs) to be redeemed.
     * @param _newCumLiqForClaims New cumulative liquidated if this must be updated.
     * @param _liqForClaimsProof Merkle proof to verify the new cumulative liquidated.
     */
    function redeemRequest(
        uint256   _rcaAmount,
        uint256   _newCumLiqForClaims,
        bytes32[] calldata _liqForClaimsProof
    )
      external
    {
        controller.redeemRequest(
            msg.sender,
            _rcaAmount,
            _newCumLiqForClaims,
            _liqForClaimsProof
        );

        _update();

        uint256 uAmount = _uValue(_rcaAmount, amtForSale, percentReserved);
        _burn(msg.sender, _rcaAmount);

        _afterRedeem(uAmount);

        pendingWithdrawal += uAmount;

        WithdrawRequest memory curRequest = withdrawRequests[msg.sender];
        uint112 newUAmount                = uint112(uAmount) + curRequest.uAmount;
        uint112 newRcaAmount              = uint112(_rcaAmount) + curRequest.rcaAmount;
        uint32 endTime                    = uint32(block.timestamp) + uint32(withdrawalDelay);
        withdrawRequests[msg.sender]      = WithdrawRequest(newUAmount, newRcaAmount, endTime);

        emit RedeemRequest(
            msg.sender,
            uint256(uAmount),
            _rcaAmount,
            uint256(endTime),
            block.timestamp
        );
    }

    /**
     * @notice Used to exchange RCA tokens back to the underlying token. Will have a 2+ day delay upon withdrawal.
     * This can mint to a "zapper" contract that can exchange the asset for Ether and send to the user.
     * @param _to The destination of the tokens.
     * @param _newCumLiqForClaims New cumulative liquidated if this must be updated.
     * @param _liqForClaimsProof Merkle proof to verify new cumulative liquidation.
     */
    function redeemTo(
        address   _to,
        address   _user,
        uint256   _newCumLiqForClaims,
        bytes32[] calldata _liqForClaimsProof
    )
      external
    {
        WithdrawRequest memory request = withdrawRequests[_user];
        delete withdrawRequests[_user];
        
        // endTime > 0 ensures request exists.
        require(request.endTime > 0 && uint32(block.timestamp) > request.endTime, "Withdrawal not yet allowed.");

        // This function doubles as redeeming and determining whether `to` is a zapper.
        bool zapper = 
            controller.redeemFinalize(
                _to,
                _user,
                uint256(request.rcaAmount),
                _newCumLiqForClaims,
                _liqForClaimsProof
            );

        _update();

        pendingWithdrawal -= uint256(request.uAmount);

        uToken.safeTransfer( _to, uint256(request.uAmount) );

        // The cool part about doing it this way rather than having user send RCAs to zapper contract,
        // then it exchanging and returning Ether is that it's more gas efficient and no approvals are needed.
        if (zapper) IZapper(_to).zapTo( _user, uint256(request.uAmount) );
        else if (_user != _to) revert("Invalid `to` address.");

        emit RedeemFinalize(
            _user,
            _to,
            uint256(request.uAmount),
            uint256(request.rcaAmount),
            block.timestamp
        );
    }

    /**
     * @notice Purchase underlying tokens directly. This will be preferred by bots.
     * @param _user The user to purchase tokens for.
     * @param _uAmount Amount of underlying tokens to purchase.
     * @param _uEthPrice Price of the underlying token in Ether per token.
     * @param _priceProof Merkle proof for the price.
     * @param _newCumLiqForClaims New cumulative amount for liquidation.
     * @param _liqForClaimsProof Merkle proof for new liquidation amounts.
     */
    function purchaseU(
        address   _user,
        uint256   _uAmount,
        uint256   _uEthPrice,
        bytes32[] calldata _priceProof,
        uint256   _newCumLiqForClaims,
        bytes32[] calldata _liqForClaimsProof
    )
      external
      payable
    {
        // If user submits incorrect price, tx will fail here.
        controller.purchase(
            _user,
            _uEthPrice,
            _priceProof,
            _newCumLiqForClaims,
            _liqForClaimsProof
        );

        _update();

        uint256 price = _uEthPrice  - (_uEthPrice * discount / DENOMINATOR);
        // divide by 1 ether because price also has 18 decimals.
        uint256 ethAmount = price * _uAmount / 1 ether;
        require(msg.value == ethAmount, "Incorrect Ether sent.");

        // If amount is bigger than for sale, tx will fail here.
        amtForSale -= _uAmount;

        uToken.safeTransfer(_user, _uAmount);
        treasury.transfer(msg.value);
        
        emit PurchaseU(
            _user,
            _uAmount,
            ethAmount,
            _uEthPrice,
            block.timestamp
        );
    }

    /**
     * @notice purchaseRca allows a user to purchase the RCA directly with Ether through liquidation.
     * @param _user The user to make the purchase for.
     * @param _uAmount The amount of underlying tokens to purchase.
     * @param _uEthPrice The underlying token price in Ether per token. 
     * @param _priceProof Merkle proof to verify this price.
     * @param _newCumLiqForClaims Old cumulative amount for sale.
     * @param _liqForClaimsProof Merkle proof of the for sale amounts.
     */
    function purchaseRca(
        address   _user,
        uint256   _uAmount,
        uint256   _uEthPrice,
        bytes32[] calldata _priceProof,
        uint256   _newCumLiqForClaims,
        bytes32[] calldata _liqForClaimsProof
    )
      external
      payable
    {
        // If user submits incorrect price, tx will fail here.
        controller.purchase(
            _user,
            _uEthPrice,
            _priceProof,
            _newCumLiqForClaims,
            _liqForClaimsProof
        );

        _update();

        uint256 price = _uEthPrice  - (_uEthPrice * discount / DENOMINATOR);
        // divide by 1 ether because price also has 18 decimals.
        uint256 ethAmount = price * _uAmount / 1 ether;
        require(msg.value == ethAmount, "Incorrect Ether sent.");
        
        // If amount is too big than for sale, tx will fail here.
        uint256 rcaAmount = _rcaValue(_uAmount, amtForSale);
        amtForSale       -= _uAmount;

        _mint(_user, rcaAmount);
        treasury.transfer(msg.value);

        emit PurchaseRca(
            _user,
            _uAmount,
            rcaAmount,
            _uEthPrice,
            ethAmount,
            block.timestamp
        );
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////// view ////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev External version of RCA value is needed so that frontend can properly
     * calculate values in cases where the contract has not been recently updated.
     * @param _rcaAmount Amount of RCA tokens (18 decimal) to find the underlying token value of.
     * @param _newCumLiqForClaims New cumulative liquidated if this must be updated.
     */
    function uValue(
        uint256 _rcaAmount,
        uint256 _newCumLiqForClaims
    )
      external
      view
    returns(
        uint256 uAmount
    )
    {
        (uint256 extraForSale, uint256 _percentReserved) = getExtraForSale(_newCumLiqForClaims);
        uAmount = _uValue(_rcaAmount, extraForSale, _percentReserved);
    }

    /**
     * @dev External version of RCA value is needed so that frontend can properly
     * calculate values in cases where the contract has not been recently updated.
     * @param _uAmount Amount of underlying tokens (18 decimal).
     * @param _newCumLiqForClaims New cumulative liquidated if this must be updated.
     */
    function rcaValue(
        uint256   _uAmount,
        uint256   _newCumLiqForClaims
    )
      external
      view
    returns(
        uint256 rcaAmount
    )
    {
        (uint256 extraForSale, /* percentReserved */) = getExtraForSale(_newCumLiqForClaims);
        rcaAmount = _rcaValue(_uAmount, extraForSale);
    }

    /**
     * @notice Convert RCA value to underlying tokens. This is internal because new 
     * for sale amounts will already have been retrieved and updated.
     * @param _rcaAmount The amount of RCAs to find the underlying value of.
     * @param _extraForSale Used by external value calls cause updates aren't made on those.
     * @param _percentReserved Percent of funds reserved if a hack is being examined.
     */
    function _uValue(
        uint256 _rcaAmount,
        uint256 _extraForSale,
        uint256 _percentReserved
    )
      internal
      view
    returns(
        uint256 uAmount
    )
    {
        uint256 subtrahend = _extraForSale - pendingWithdrawal;
        uint256 balance = _uBalance();
        if (totalSupply() == 0 || balance < subtrahend) return _rcaAmount;

        uAmount = 
            (balance - subtrahend)
            * _rcaAmount
            / (totalSupply());

        if (_percentReserved > 0)
            uAmount -= 
            (uAmount 
            * _percentReserved 
            / DENOMINATOR);
    }

    /**
     * @notice Find the RCA value of an amount of underlying tokens.
     * @param _uAmount Amount of underlying tokens to find RCA value of.
     * @param _extraForSale Used by external value calls cause updates aren't made on those.
     */
    function _rcaValue(
        uint256 _uAmount,
        uint256 _extraForSale
    )
      internal
      view
    returns(
        uint256 rcaAmount
    )
    {
        uint256 balance = _uBalance();
        uint256 subtrahend = _extraForSale + pendingWithdrawal;
        if (balance == 0 || balance < subtrahend) return _uAmount;
        rcaAmount = 
            totalSupply()
            * _uAmount
            / (balance - subtrahend);
    }

    /**
     * @notice For frontend calls. Doesn't need to verify info because it's not changing state.
     */
    function getExtraForSale(
        uint256 _newCumLiqForClaims
    )
      public
      view
    returns(
        uint256 extraForSale,
        uint256 _percentReserved
    )
    {
        // Check for liquidation, then percent paused, then APR
        (/** */, /** */, /** */, /** */, uint32 aprUpdate, /** */) = controller.systemUpdates();
        uint256 extraLiqForClaims = _newCumLiqForClaims - cumLiqForClaims;
        uint256 extraFees = _getInterimFees(
                                controller.apr(),
                                uint256(aprUpdate)
                            );
        extraForSale = extraFees + extraLiqForClaims;
        return (extraForSale, controller.percentReserved());
    }

    /**
     * @notice Get the amount that should be added to "amtForSale" based on actions within the time since last update.
     * @dev If values have changed within the interim period, this function averages them to find new owed amounts for fees.
     * @param _newApr new APR.
     * @param _aprUpdate start time for new APR.
     */
    function _getInterimFees(
        uint256 _newApr,
        uint256 _aprUpdate
    )
      internal
      view
    returns(
        uint256 fees
    )
    {
        // Get all variables that are currently in this contract's state.
        // 1e18 used as a buffer.
        uint256 uBalance         = _uBalance();
        uint256 aprAvg           = apr * 1e18;
        uint256 totalTimeElapsed = block.timestamp - lastUpdate;

        // Find average APR throughout period if it has been updated.
        if (_aprUpdate > lastUpdate) {
            uint256 aprPrev = apr * (_aprUpdate - lastUpdate);
            uint256 aprCur  = _newApr * (block.timestamp - _aprUpdate);
            aprAvg          = (aprPrev + aprCur) * 1e18 / totalTimeElapsed;
        }

        if (uBalance < pendingWithdrawal + amtForSale) return 0;

        // Calculate fees based on average active amount (excl reserved)
        uint256 activeInclReserved = uBalance - pendingWithdrawal - amtForSale;
        fees = activeInclReserved * aprAvg * totalTimeElapsed / YEAR_SECS / DENOMINATOR / 1e18;
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////// internal ///////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Update the amtForSale if there's an active fee.
     */
    function _update()
      internal
    {
        if (apr > 0) {
            uint256 balance    = _uBalance();
            uint256 subtrahend = amtForSale + pendingWithdrawal;

            // If liquidation for claims is set incorrectly this could occur and break the contract.
            if (balance < subtrahend) return;

            uint256 secsElapsed = block.timestamp - lastUpdate;
            uint256 active = balance - subtrahend;
            uint256 activeExclReserved = active - (active * percentReserved / DENOMINATOR);

            amtForSale += 
                activeExclReserved
                * secsElapsed 
                * apr
                / YEAR_SECS
                / DENOMINATOR;
        }

        lastUpdate = block.timestamp;
    }

    /// @notice Check balance of underlying token.
    function _uBalance() internal virtual view returns(uint256);

    /// @notice Get reward for this token if there are rewards.
    function _updateReward(address _user) internal virtual;

    /// @notice Logic to run after a mint, such as if we need to stake the underlying token.
    function _afterMint(uint256 _uAmount) internal virtual;

    /// @notice Logic to run after a redeem, such as unstaking.
    function _afterRedeem(uint256 _uAmount) internal virtual;

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////// onlyController //////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Update function to be called by controller. This is only called when a controller has made
     * an update since the last shield update was made, so it must do extra calculations to determine
     * what the exact costs throughout the period were according to when system updates were made.
     */
    function controllerUpdate(
        uint256 _newApr,
        uint256 _aprUpdate
    )
      external
      onlyController
    {
        // This update only affects the contract when APR is active.
        if (apr == 0 && _newApr == 0) return;

        uint256 extraFees = _getInterimFees(
                                _newApr,
                                _aprUpdate
                            );

        amtForSale += extraFees;
        lastUpdate = block.timestamp;
    }

    /**
     * @notice Add a for sale amount to this shield vault.
     * @param _newCumLiqForClaims New cumulative total for sale.
    **/
    function setLiqForClaims(
        uint256 _newCumLiqForClaims
    )
      external
      onlyController
    {
        // Do this here rather than on controller for slight savings.
        uint256 addForSale = _newCumLiqForClaims - cumLiqForClaims;
        amtForSale += addForSale;
        cumLiqForClaims = _newCumLiqForClaims;
    }

    /**
     * @notice Change the treasury address to which funds will be sent.
     * @param _newTreasury New treasury address.
    **/
    function setTreasury(
        address _newTreasury
    )
      external
      onlyController
    {
        treasury = payable(_newTreasury);
    }

    /**
     * @notice Change the percent paused on this vault. 1000 == 10%.
     * @param _newPercentReserved New percent paused.
    **/
    function setPercentReserved(
        uint256 _newPercentReserved
    )
      external
      onlyController
    {
        percentReserved = _newPercentReserved;
    }

    /**
     * @notice Change the withdrawal delay of withdrawing underlying tokens from vault. In seconds.
     * @param _newWithdrawalDelay New withdrawal delay.
    **/
    function setWithdrawalDelay(
        uint256 _newWithdrawalDelay
    )
      external
      onlyController
    {
        withdrawalDelay = _newWithdrawalDelay;
    }

    /**
     * @notice Change the discount that users get for purchasing from us. 1000 == 10%.
     * @param _newDiscount New discount.
    **/
    function setDiscount(
        uint256 _newDiscount
    )
      external
      onlyController
    {
        discount = _newDiscount;
    }

    /**
     * @notice Change the treasury address to which funds will be sent.
     * @param _newApr New APR. 1000 == 10%.
    **/
    function setApr(
        uint256 _newApr
    )
      external
      onlyController
    {
        apr = _newApr;
    }

/////////////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////// onlyGov //////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Update Controller to a new address. Very rare case for this to be used.
     * @param _newController Address of the new Controller contract.
     */
    function setController(
        address _newController
    )
      external
      onlyGov
    {
        controller = IRcaController(_newController);
    }

    /**
     * @notice Needed for Nexus to prove this contract lost funds. We'll likely have reinsurance
     * at least at the beginning to ensure we don't have too much risk in certain protocols.
     * @param _coverAddress Address that we need to send 0 eth to to confirm we had a loss.
     */
    function proofOfLoss(
        address payable _coverAddress
    )
      external
      onlyGov
    {
        _coverAddress.transfer(0);
    }

}