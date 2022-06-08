/// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.11;

import "../RcaShieldNormalized.sol";
import "../../external/Bancor.sol";

contract RcaShieldBancor is RcaShieldNormalized {
    using SafeERC20 for IERC20Metadata;

    IStandardRewards public immutable standardRewards;

    uint256 public immutable id;
    bool public joinRewardsProgram;

    constructor(
        string memory _name,
        string memory _symbol,
        address _uToken,
        uint256 _uTokenDecimals,
        address _governance,
        address _controller,
        IStandardRewards _standardRewards,
        uint256 _id
    ) RcaShieldNormalized(_name, _symbol, _uToken, _uTokenDecimals, _governance, _controller) {
        standardRewards = _standardRewards;
        id = _id;
        uToken.safeApprove(address(standardRewards), type(uint256).max);
    }

    function getReward() external {
        uint256[] memory t = new uint256[](1);
        t[0] = id;
        standardRewards.claimRewards(t);  
    }

    function purchase(
        address _token,
        uint256 _amount, // token amount to buy
        uint256 _tokenPrice,
        bytes32[] calldata _tokenPriceProof,
        uint256 _underlyingPrice,
        bytes32[] calldata _underlyinPriceProof
    ) external {
        require(_token != address(uToken), "cannot buy underlying token");
        controller.verifyPrice(_token, _tokenPrice, _tokenPriceProof);
        controller.verifyPrice(address(uToken), _underlyingPrice, _underlyinPriceProof);
        uint256 underlyingAmount = (_amount * _tokenPrice) / _underlyingPrice;
        if(discount > 0) {
            underlyingAmount -= (underlyingAmount * discount) / DENOMINATOR;
        }

        IERC20Metadata token = IERC20Metadata(_token);
        // normalize token amount to transfer to the user so that it can handle different decimals
        _amount = (_amount * 10**token.decimals()) / BUFFER;

        token.safeTransfer(msg.sender, _amount);
        uToken.safeTransferFrom(msg.sender, address(this), _normalizedUAmount(underlyingAmount));

        if(joinRewardsProgram) {
            if(standardRewards.isProgramActive(id)) standardRewards.join(id, underlyingAmount);
        } 
    }

    function setRewardsProgramJoinEnabled(
        bool _joinRewardsProgram
        //TODO: onlyGuardian?
    ) external {
        require(standardRewards.isProgramEnabled(id), "Rewards program is disabled for this pool");
        if(!standardRewards.isProgramEnabled(id)) revert("Rewards program is disabled for this pool");
        else joinRewardsProgram = _joinRewardsProgram;
    }

    function _uBalance() internal view override returns (uint256) {
        return((uToken.balanceOf(address(this)) + standardRewards.providerStake(address(this), id)) * BUFFER) / BUFFER_UTOKEN;
    }

    function _afterMint(uint256 _uAmount) internal override {
        // TODO: sometimes joining might not be worth it. Compounding rewards 
        // occure anyways. Joining is only for additional BNT incentive rewards.  
        standardRewards.join(id, _uAmount); 
    }

    function _afterRedeem(uint256 _uAmount) internal override {

    }
}
