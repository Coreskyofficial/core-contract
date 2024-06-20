// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./IDeposit.sol";

contract Deposit is IDeposit, ERC721Holder, ERC1155Holder, AccessControl {
    
    using Address for address;

    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    modifier onlyEOA(address to) {
        require(!to.isContract(), "Only EOA can receive nft.");
        _;
    }

    constructor(address root, address withdraw) {
        _setupRole(DEFAULT_ADMIN_ROLE, root);
        _grantRole(WITHDRAW_ROLE, withdraw);
    }

    function grantWithdraw(address nft, address withdraw) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 role = keccak256(abi.encodePacked(nft));
        _grantRole(role, withdraw);
    }
    
    modifier onlyWithdraw(address nft) {
        bytes32 role = keccak256(abi.encodePacked(nft));
        require(( hasRole(WITHDRAW_ROLE, _msgSender()) || hasRole(role, _msgSender()) ), 'only withdraw role can call function.');
        _;
    }

    function withdrawERC721(address nft, address to, uint256 tokenId) external onlyWithdraw(nft) onlyEOA(to) {
        IERC721(nft).safeTransferFrom(address(this), to, tokenId);
    }
    
    function batchWithdrawERC721(address nft, address to, uint256[] calldata tokenIds) external onlyWithdraw(nft) onlyEOA(to) {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            IERC721(nft).safeTransferFrom(address(this), to, tokenIds[i]);
        }
    }

    function withdrawERC1155(address nft, address to, uint256 tokenId, uint256 amount) external onlyWithdraw(nft) onlyEOA(to) {
        IERC1155(nft).safeTransferFrom(address(this), to, tokenId, amount, "");
    }

    function batchWithdrawERC1155(address nft, address to, uint256[] calldata tokenIds, uint256[] calldata amounts) external onlyWithdraw(nft) onlyEOA(to) {
        IERC1155(nft).safeBatchTransferFrom(address(this), to, tokenIds, amounts, "");
    }

    function multicall(address target, bytes[] calldata data) external onlyRole(WITHDRAW_ROLE) returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            // TODO unsafe : Non-Detected contract return value
            results[i] = target.functionCall(data[i], "Deposit: Call ABI failed.");
        }
        return results;
    }
    
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155Receiver, AccessControl) returns (bool) {
        return 
            interfaceId == type(IDeposit).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId || 
            interfaceId == type(IERC1155Receiver).interfaceId || 
            super.supportsInterface(interfaceId);
    }
}