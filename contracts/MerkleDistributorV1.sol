// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./BatchInterface.sol";

error AlreadyClaimed();
error InvalidProof();

/**
 * @author hoseadevops@gmail.com
 * TODO unsafe : Non-Detected contract call return value
 */
contract MerkleDistributorV1 is AccessControl {
    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;
    using Address for address;

    bytes32 public constant CREATE_ROLE = keccak256("CREATE_ROLE");

    event Claimed(
        uint256 indexed roundID,
        address indexed sender,
        uint256 indexed index
    );

    struct Project {
        address target; // nft or deposit or any contract
        address payable receipt; // receive payment
        bytes32 merkleRoot; // merkle root
        BitMaps.BitMap bitmap; // distribute status of index
        address payment; // ETH or ERC20
        uint256 price; // nft price
        uint256 startTime; // start
        uint256 endTime; // end
    }

    struct ClaimData {
        uint256 index;
        uint256 num;
        bytes calldataABI;
        bytes32[] merkleProof;
    }

    // roundID => Project
    mapping(uint256 => Project) private round;

    constructor(address root, address creator) {
        _setupRole(DEFAULT_ADMIN_ROLE, root);
        _grantRole(CREATE_ROLE, creator);
    }

    // Setting
    function launchpad(
        uint256 _roundID,
        address _target,
        bytes32 _merkleRoot,
        address payable _receipt,
        address _payment,
        uint256 _price,
        uint256 _startTime,
        uint256 _endTime
    ) public onlyRole(CREATE_ROLE) {
        require(_endTime > block.timestamp, "End time is past");
        require(_target != address(0), "require target");
        require(_receipt != address(0), "require receipt");
        require(_price > 0, "price > 0");

        Project storage project = round[_roundID];

        require(project.target == address(0), "Do not repeat Settings");

        project.merkleRoot = _merkleRoot;
        project.target = _target;
        project.receipt = _receipt;
        project.payment = _payment;
        project.price = _price;
        project.startTime = _startTime;
        project.endTime = _endTime;
    }

    // anyone can pay
    function claim(
        uint256 roundID,
        uint256 index,
        uint256 num,
        bytes calldata calldataABI,
        bytes32[] calldata merkleProof
    ) public payable {
        Project storage project = round[roundID];

        // Verify time
        require(project.startTime <= block.timestamp, "The Launchpad activity not started");
        require(project.endTime >= block.timestamp, "The Launchpad activity has ended");

        // Verify claim
        if (project.bitmap.get(index)) revert AlreadyClaimed();

        // Verify the merkle proof.
        bytes32 node = keccak256(
            abi.encodePacked(roundID, index, num, calldataABI, msg.sender)
        );

        if (!MerkleProof.verify(merkleProof, project.merkleRoot, node))
            revert InvalidProof();
        // Mark it claimed
        project.bitmap.set(index);

        // Receipt token && Refund token
        uint256 total = project.price * num;
        if (project.payment == address(0)) {
            require(msg.value >= total, "You have to pay enough eth.");
            uint256 refund = msg.value - total;
            if (refund > 0) payable(msg.sender).transfer(refund);
            project.receipt.transfer(total);
        } else {
            require(msg.value == 0, "You don't need to pay eth");
            IERC20(project.payment).safeTransferFrom(
                msg.sender,
                project.receipt,
                total
            );
        }

        // execute
        // TODO unsafe : Non-Detected contract call return value
        project.target.functionCall(
            calldataABI,
            "MerkleDistributor: Call ABI failed."
        );
        emit Claimed(roundID, msg.sender, index);
    }

    /**
     * batchClaim
     */
    function batchClaim(
        uint256 roundID,
        uint256 amount,
        ClaimData[] calldata claimdata
    ) public payable {
        Project storage project = round[roundID];

        // Verify time
        require(project.startTime <= block.timestamp, "The Launchpad activity not started");
        require(project.endTime >= block.timestamp, "The Launchpad activity has ended");
        require(claimdata.length > 0, "At least one piece of data exists in claimdata.");

        uint256 totalAmount = 0;
        for (uint256 j = 0; j < claimdata.length; j++) {
            uint256 totalPrice = project.price * claimdata[j].num;
            totalAmount += totalPrice;
        }
        require(totalAmount == amount, "total amount error");
        for (uint256 j = 0; j < claimdata.length; j++) {
            if (project.bitmap.get(claimdata[j].index)) revert AlreadyClaimed();
            freeClaim(
                roundID,
                claimdata[j].index,
                claimdata[j].num,
                claimdata[j].calldataABI,
                claimdata[j].merkleProof,
                false
            );
            project.bitmap.set(claimdata[j].index);
        }
    }

    /**
     * freeBatchMint
     */
    function freeBatchMint(
        uint256 roundID,
        ClaimData[] calldata claimdata
    ) public {
        Project storage project = round[roundID];
        // Verify time
        require(project.startTime <= block.timestamp, "The Launchpad activity not started");
        require(project.endTime >= block.timestamp, "The Launchpad activity has ended");
        require(claimdata.length > 0, "At least one piece of data exists in claimdata.");

        for (uint256 j = 0; j < claimdata.length; j++) {
            if (project.bitmap.get(claimdata[j].index)) revert AlreadyClaimed();
            freeClaim(
                roundID,
                claimdata[j].index,
                claimdata[j].num,
                claimdata[j].calldataABI,
                claimdata[j].merkleProof,
                true
            );
            project.bitmap.set(claimdata[j].index);
        }
    }

    function freeClaim(
        uint256 roundID,
        uint256 index,
        uint256 num,
        bytes calldata calldataABI,
        bytes32[] calldata merkleProof,
        bool free
    ) internal {
        Project storage project = round[roundID];

        // Verify the merkle proof.
        bytes32 node = keccak256(
            abi.encodePacked(roundID, index, num, calldataABI, msg.sender)
        );
        if (!MerkleProof.verify(merkleProof, project.merkleRoot, node))
            revert InvalidProof();

        if (!free) {
            // Receipt token && Refund token
            uint256 total = project.price * num;
            if (project.payment == address(0)) {
                require(msg.value >= total, "You have to pay enough eth.");
                uint256 refund = msg.value - total;
                if (refund > 0) payable(msg.sender).transfer(refund);
                project.receipt.transfer(total);
            } else {
                require(msg.value == 0, "You don't need to pay eth");
                IERC20(project.payment).safeTransferFrom(
                    msg.sender,
                    project.receipt,
                    total
                );
            }
        }
        // execute
        // TODO unsafe : Non-Detected contract call return value
        project.target.functionCall(
            calldataABI,
            "MerkleDistributor: Call ABI failed."
        );
        emit Claimed(roundID, msg.sender, index);
    }

    // Returns project details by this round.
    function getProject(
        uint256 roundID
    )
        external
        view
        returns (address, address, bytes32, address, uint256, uint256, uint256)
    {
        Project storage project = round[roundID];
        return (
            project.target,
            project.receipt,
            project.merkleRoot,
            project.payment,
            project.price,
            project.startTime,
            project.endTime
        );
    }

    // Returns true if the index has been marked claimed by this round.
    function isClaimed(
        uint256 roundID,
        uint256 index
    ) external view returns (bool) {
        Project storage project = round[roundID];
        return project.bitmap.get(index);
    }
}
