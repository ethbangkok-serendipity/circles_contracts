// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.24;

import {ABDKMath64x64 as Math64x64} from "lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import "../errors/Errors.sol";
import "./ERC1155.sol";

contract Circles is ERC1155, ICirclesErrors {
    // Type declarations

    /**
     * @notice MintTime struct stores the last mint time,
     * and the status of a connected v1 Circles contract.
     * @dev This is used to store the last mint time for each avatar,
     * and the address is used as a status for the connected v1 Circles contract.
     * The address is kept at zero address if the avatar is not registered in Hub v1.
     * If the avatar is registered in Hub v1, but the associated Circles ERC20 contract
     * has not been stopped, then the address is set to that v1 Circles contract address.
     * Once the Circles v1 contract has been stopped, the address is set to 0x01.
     * At every observed transition of the status of the v1 Circles contract,
     * the lastMintTime will be updated to the current timestamp to avoid possible
     * overlap of the mint between Hub v1 and Hub v2.
     */
    struct MintTime {
        address mintV1Status;
        uint96 lastMintTime;
    }

    // Constants

    /**
     * @notice Upon claiming, the maximum claim is upto two weeks
     * of history. Unclaimed older Circles are unclaimable.
     */
    uint256 private constant MAX_CLAIM_DURATION = 2 weeks;

    /**
     * @dev Address used to indicate that the associated v1 Circles contract has been stopped.
     */
    address internal constant CIRCLES_STOPPED_V1 = address(0x1);

    /**
     * @notice Indefinite future, or approximated with uint96.max
     */
    uint96 internal constant INDEFINITE_FUTURE = type(uint96).max;

    // State variables

    /**
     * @notice The mapping of avatar addresses to the last mint time,
     * and the status of the v1 Circles minting.
     * @dev This is used to store the last mint time for each avatar.
     */
    mapping(address => MintTime) internal mintTimes;

    // Events

    event PersonalMint(address indexed human, uint256 amount, uint256 startPeriod, uint256 endPeriod);

    // Constructor

    /**
     * Constructor to create a Circles ERC1155 contract with demurrage.
     * @param _inflation_day_zero Inflation day zero stores the start of the global inflation curve
     * @param _uri uri for the Circles metadata
     */
    constructor(uint256 _inflation_day_zero, string memory _uri)
        ERC1155(_uri)
        DiscountedBalances(_inflation_day_zero)
    {}

    // Internal functions

    /**
     * @notice Calculate the demurraged issuance for a human's avatar.
     * @param _human Address of the human's avatar to calculate the issuance for.
     * @return issuance The issuance in attoCircles.
     * @return startPeriod The start of the claimable period.
     * @return endPeriod The end of the claimable period.
     */
    function _calculateIssuance(address _human) internal view returns (uint256, uint256, uint256) {
        MintTime memory mintTime = mintTimes[_human];
        if (mintTime.mintV1Status != address(0) && mintTime.mintV1Status != CIRCLES_STOPPED_V1) {
            // Circles v1 contract cannot be active.
            // revert CirclesERC1155MintBlocked(_human, mintTime.mintV1Status);
            revert CirclesErrorOneAddressArg(_human, 0xC0);
        }

        // Check if at least one new completed hour is mintable
        uint256 lastCompletedHour = mintTime.lastMintTime / 1 hours;
        uint256 currentCompletedHour = block.timestamp / 1 hours;

        if (lastCompletedHour >= currentCompletedHour || mintTime.lastMintTime == INDEFINITE_FUTURE) {
            // No new completed hour to mint, or stopped
            return (0, 0, 0);
        }

        // calculate the start of the claimable period
        uint256 startMint = _max(block.timestamp - MAX_CLAIM_DURATION, mintTime.lastMintTime);

        // day of start of mint, dA
        uint256 dA = uint256(day(startMint));

        // day of current block, dB
        uint256 dB = uint256(day(block.timestamp));

        // the difference of days between dB and dA used for the table lookups
        uint256 n = dB - dA;

        // calculate the number of completed hours in day A until `startMint`
        int128 k = Math64x64.fromUInt((startMint - (dA * 1 days + inflationDayZero)) / 1 hours);

        // Calculate the number of seconds remaining in the current day (dB)
        uint256 secondsRemainingInB = ((dB + 1) * 1 days + inflationDayZero - block.timestamp);
        // Calculate the number of complete hours remaining
        uint256 hoursRemainingInB = secondsRemainingInB / 1 hours;
        // Calculate l:
        // If there are any seconds beyond complete hours, add 1 to account for the incomplete hour
        // Convert the result to int128 using Math64x64.fromUInt
        int128 l = Math64x64.fromUInt(hoursRemainingInB + (secondsRemainingInB % 1 hours > 0 ? 1 : 0));

        // calculate the overcounted (demurraged) k (in day A) and l (in day B) hours
        // note that the hours l are not demurraged as it is current day by construction
        int128 overcount = Math64x64.add(Math64x64.mul(R[n], k), l);

        // subtract the overcount from the total issuance, and convert to attoCircles
        return (
            Math64x64.mulu(Math64x64.sub(T[n], overcount), EXA),
            // start of the claimable period
            inflationDayZero + dA * 1 days + Math64x64.mulu(k, 1 hours),
            // end of the claimable period
            inflationDayZero + dB * 1 days + 1 days - Math64x64.mulu(l, 1 hours)
        );
    }

    /**
     * @notice Claim issuance for a human's avatar and update the last mint time.
     * @param _human Address of the human's avatar to claim the issuance for.
     */
    function _claimIssuance(address _human) internal {
        (uint256 issuance, uint256 startPeriod, uint256 endPeriod) = _calculateIssuance(_human);
        if (issuance == 0) {
            // No issuance to claim, simply return without reverting
            return;
        }

        // update the last mint time, before minting as mint time determines the check (guard for reeentrancy attack)
        mintTimes[_human].lastMintTime = uint96(block.timestamp);

        // mint personal Circles to the human; ERC1155 mint will perform acceptance call
        _mintAndUpdateTotalSupply(_human, toTokenId(_human), issuance, "", true);

        emit PersonalMint(_human, issuance, startPeriod, endPeriod);
    }

    function _mintAndUpdateTotalSupply(
        address _account,
        uint256 _id,
        uint256 _value,
        bytes memory _data,
        bool _doAcceptanceCheck
    ) internal {
        _mint(_account, _id, _value, _data, _doAcceptanceCheck);

        uint64 today = day(block.timestamp);
        DiscountedBalance memory totalSupplyBalance = discountedTotalSupplies[_id];
        uint256 newTotalSupply =
            _calculateDiscountedBalance(totalSupplyBalance.balance, today - totalSupplyBalance.lastUpdatedDay) + _value;
        if (newTotalSupply > MAX_VALUE) {
            // DiscountedBalances: balance exceeds maximum value
            // revert CirclesDemurrageAmountExceedsMaxUint192(_account, _id, newTotalSupply, 2);
            revert CirclesErrorAddressUintArgs(_account, _id, 0x80);
        }
        totalSupplyBalance.balance = uint192(newTotalSupply);
        totalSupplyBalance.lastUpdatedDay = today;
        discountedTotalSupplies[_id] = totalSupplyBalance;
    }

    function _burnAndUpdateTotalSupply(address _account, uint256 _id, uint256 _value) internal {
        // _update will discount the balance before subtracting the value
        _burn(_account, _id, _value);

        uint64 today = day(block.timestamp);
        DiscountedBalance memory totalSupplyBalance = discountedTotalSupplies[_id];
        uint256 discountedTotalSupply =
            _calculateDiscountedBalance(totalSupplyBalance.balance, today - totalSupplyBalance.lastUpdatedDay);
        if (discountedTotalSupply < _value) {
            // Logically impossible to burn more than the total supply
            // however if the total supply nears dust, the discounting of the balance
            // and the total supply might differ on the least significant bits.
            // There is no good way to handle this, so user should burn a few attoCRC less,
            // or wait a day for the total supply to be discounted to zero automatically.
            // revert CirclesLogicAssertion(4);
            revert CirclesErrorNoArgs(0x84);
        }
        unchecked {
            totalSupplyBalance.balance = uint192(discountedTotalSupply - _value);
        }
        totalSupplyBalance.lastUpdatedDay = today;
        discountedTotalSupplies[_id] = totalSupplyBalance;
    }

    /**
     * @dev Max function to compare two values.
     * @param a Value a
     * @param b Value b
     */
    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }
}
