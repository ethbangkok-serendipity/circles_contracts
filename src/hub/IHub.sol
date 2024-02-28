// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.13;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface IHubV2 is IERC1155 {
    function avatars(address avatar) external view returns (address);
    function mintPolicies(address avatar) external view returns (address);
    function burn(uint256 id, uint256 amount) external;
}
