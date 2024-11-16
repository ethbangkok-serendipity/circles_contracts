// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.24;

import "./IMintPolicy.sol";
import "./Definitions.sol";

contract MintPolicy is IMintPolicy {
    mapping(address => uint256) public crcAllowance;
    address public admin;

    modifier isAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    /**
     * @notice Set crcAllowance for an address
     */
    function setCrcAllowance(address _user, uint256 _amount) external isAdmin {
        crcAllowance[_user] = _amount;
    }

    constructor(address _admin) {
        admin = _admin;
    }

    // External functions

    /**
     * @notice Simple mint policy that checks whether the correct amount has been provided
     * based on crcAllowance
     */
    function beforeMintPolicy(
        address _minter /*_minter*/,
        address /*_group*/,
        uint256[] calldata /*_collateral*/,
        uint256[] calldata _amounts /*_amounts*/,
        bytes calldata /*_data*/
    ) external virtual override returns (bool) {
        require(
            crcAllowance[_minter] == uint256(_amounts[0]),
            "Correct amount must be provided"
        );
        return true;
    }

    /**
     * @notice Simple burn policy that always returns true
     */
    function beforeBurnPolicy(
        address,
        address,
        uint256,
        bytes calldata
    ) external virtual override returns (bool) {
        return true;
    }

    /**
     * @notice Simple redeem policy that returns the redemption ids and values as requested in the data
     * @param _data Optional data bytes passed to redeem policy
     */
    function beforeRedeemPolicy(
        address /*_operator*/,
        address /*_redeemer*/,
        address /*_group*/,
        uint256 /*_value*/,
        bytes calldata _data
    )
        external
        virtual
        override
        returns (
            uint256[] memory _ids,
            uint256[] memory _values,
            uint256[] memory _burnIds,
            uint256[] memory _burnValues
        )
    {
        // simplest policy is to return the collateral as the caller requests it in data
        BaseMintPolicyDefinitions.BaseRedemptionPolicy memory redemption = abi
            .decode(_data, (BaseMintPolicyDefinitions.BaseRedemptionPolicy));

        // and no collateral gets burnt upon redemption
        _burnIds = new uint256[](0);
        _burnValues = new uint256[](0);

        // standard treasury checks whether the total sums add up to the amount of group Circles redeemed
        // so we can simply decode and pass the request back to treasury.
        // The redemption will fail if it does not contain (sufficient of) these Circles
        return (
            redemption.redemptionIds,
            redemption.redemptionValues,
            _burnIds,
            _burnValues
        );
    }
}
