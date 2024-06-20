// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

interface IDeposit {

    function grantWithdraw(address nft, address withdraw) external;
    
    function withdrawERC721(address nft, address to, uint256 tokenId) external;
    
    function batchWithdrawERC721(address nft, address to, uint256[] calldata tokenIds) external;

    function withdrawERC1155(address nft, address to, uint256 tokenId, uint256 amount) external;

    function batchWithdrawERC1155(address nft, address to, uint256[] calldata tokenIds, uint256[] calldata amounts) external;

    function multicall(address target, bytes[] calldata data) external returns (bytes[] memory results);
}