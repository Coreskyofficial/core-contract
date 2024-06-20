// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISbt{
    function tokenIdOf(address from) external view  returns (uint256);

    function updateSubAmount(
        uint256 tokenId,
        uint256 deadline,
        uint256 amount,
        uint256 serialNo,
        bytes memory signature
    ) external;
}