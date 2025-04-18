// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import "hardhat/console.sol";

error InvalidProof();
error AlreadyClaimed();
error AlreadyDroped();
error IncorrectFee();

contract TokenAirDrop is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ASSET_ROLE = keccak256("ASSET_ROLE");

    struct DropProject {
        address token;
        uint256 startTime;          // start
        uint256 endTime;            // end
        uint256 fee;        
        uint256 slicePeriodSeconds;
        BitMaps.BitMap bitmap;      // distribute status of index
        bytes32 merkleRoot;         // merkle root
    }

    struct AirDrop {
        uint256 batchNo;
        address user;
        address token;
        uint256 amount;
        uint256 serialNo;
    }

    struct ClaimData {
        address user;
        address token;
        // total amount of tokens to be released at the end of the vesting
        uint256 amount;
        // amount of tokens released
        uint256 released;
        uint256 time;
    }

    //////  configure
    // roundID => DropProject
    mapping(uint256 => DropProject) private dropProject;

    //////   User claim
    // address => roundId => ClaimData
    mapping(address => mapping(uint256 => ClaimData)) private userClaimRecord;
    // address => roundId => totalNumber
    mapping(address => mapping(uint256 => uint256)) private userClaimTotal;
    // distribute status of index
    BitMaps.BitMap bitmap;

    // dropBatchNo => serialNo[]
    mapping(uint256 => uint256[]) private dropBatchNoMap;
    // serialNo => AirDrop
    mapping(uint256 => AirDrop) private serailNoAirDropMap;
    // serialNo => token
    mapping(uint256 => address) public tokenMap;


    // Airdrop token event
    event AirDropToken(
        address indexed token,
        address indexed to,
        uint256 indexed amount,
        uint256 time,
        uint256 serialNo,
        uint256 batchNo
    );

    event Withdraw(
        address indexed _token,
        address indexed _to,
        uint256 indexed _amount
    );
    // deposit token event
    event DepositToken(
        address indexed token,
        uint256 amount,
        uint256 time,
        uint256 serialNo
    );
    // Claimed token event
    event Claimed(
        address indexed token,
        address indexed to,
        uint256 indexed amount,
        uint256 time,
        uint256 serialNo
    );
    // CreateAirDrop event
    event CreateAirDrop(uint256 indexed _roundId);

    /// @notice Emitted when a fee is set for a stage
    /// @param _roundID The _roundID identifying the stage
    /// @param fee The new fee amount
    event FeeSet(uint256 indexed _roundID, uint256 fee);

    /**
     * @dev Initializes the contract by setting a `_admin` and a `_operator` to the Alloction.
     */
    function initialize(address _admin, address _operator) public initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
        _setRoleAdmin(OPERATOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ASSET_ROLE, DEFAULT_ADMIN_ROLE);

    }


    /**
     * @dev Create AirDrop
     *
     * @param _roundId  AirDrop roundId.
     * @param _token Unlock token address.
     */
    function createAirDrop(
        uint256 _roundId,
        address _token,
        uint256 _startTime, 
        uint256 _endTime,
        uint256 _slicePeriodSeconds,
        bytes32 _merkleRoot
    ) external onlyRole(OPERATOR_ROLE) {

        require(_token != address(0), "Token non existent");
        require(_endTime > getCurrentTime(), "End time is past");
        require(_endTime > _startTime, "The end time must be greater than the start time");

        DropProject storage project = dropProject[_roundId];
        require(project.token == address(0), "Already setting");

        project.token = _token;
        project.startTime = _startTime;
        project.endTime = _endTime;
        project.merkleRoot = _merkleRoot;
        project.slicePeriodSeconds = _slicePeriodSeconds;

        emit CreateAirDrop(_roundId);
    }

    // anyone can claim
    function claimToken(uint256 _roundID, uint256 _serialNo, uint256 _amount, bytes32[] calldata _merkleProof) payable external nonReentrant{

        DropProject storage project = dropProject[_roundID];

        if (msg.value != project.fee) {
            revert IncorrectFee();
        }
        address sender = msg.sender;
        // Verify time
        require(project.startTime <= getCurrentTime(), "The Launchpad activity not started");
        require(project.endTime >= getCurrentTime(), "The Launchpad activity has ended");

        // Verify claim
        if (project.bitmap.get(_serialNo)) revert AlreadyClaimed();

        // Verify the merkle proof.
        if (!verify( _roundID, _serialNo, sender, _amount, _merkleProof)) revert InvalidProof();
        // Mark it claimed
        project.bitmap.set(_serialNo);

        uint256 bal = getWithdrawableAmount(project.token);
        require(bal > 0, "Total balance must be getter 0");

        uint256 claimedAmount = _computeClaimableAmount(project.startTime, project.endTime, project.slicePeriodSeconds, _amount);
        uint256 claimingAmount = claimedAmount - userClaimTotal[sender][_roundID];
        require(claimingAmount > 0, "claim must be getter 0");
        require(bal >= claimingAmount, "Insufficient token balance");
        IERC20(project.token).safeTransfer(sender, claimingAmount);

        // address => roundId => totalNumber
        userClaimTotal[sender][_roundID] += claimedAmount;
        // address => roundId => serialNo
        userClaimRecord[sender][_roundID] = ClaimData(sender, project.token, _amount, userClaimTotal[sender][_roundID], getCurrentTime());

        emit Claimed(project.token, sender, claimingAmount, getCurrentTime(), _serialNo);
    }


    function verify(
        uint256 _roundId,
        uint256 _serialNo,
        address _account,
        uint256 _amount,
        bytes32[] memory _proof
    ) public view returns (bool) {
        DropProject storage project = dropProject[_roundId];
        bytes32 node = keccak256(bytes.concat(keccak256(abi.encode(_roundId, _serialNo, _amount, _account))));
        return MerkleProof.verify(_proof, project.merkleRoot, node);
    }



    /**
     * batch transfer erc20 token
     */
    function sendToken(
        uint256 _batchNo,
        address _tokenAddress,
        address[] calldata _to,
        uint256[] calldata _value,
        uint256[] calldata _serialNo
    ) public payable onlyRole(OPERATOR_ROLE) nonReentrant {
        require(
            _to.length == _value.length,
            "The length of array [_to] and array [_value] does not match"
        );
        require(
            _to.length == _serialNo.length,
            "The length of array [_to] and array [_serialNo] does not match"
        );
        require(_to.length <= 1000, "The maximum limit of 1000");

        // Verify drop
        if (bitmap.get(_batchNo)) revert AlreadyDroped();
        // Mark it droped
        bitmap.set(_batchNo);

        if (_tokenAddress == address(0)) {
            uint256 total = 0;
            for (uint256 i = 0; i < _value.length; i++) {
                total = total + _value[i];
            }
            require(msg.value >= total, "Insufficient amount token");
            uint256 beforeValue = msg.value;
            uint256 afterValue = 0;
            for (uint256 i = 0; i < _to.length; i++) {
                afterValue = afterValue + _value[i];
                TransferETH(payable(_to[i]), _value[i]);
                emitAirDropToken(
                    _batchNo,
                    _tokenAddress,
                    _to[i],
                    _value[i],
                    _serialNo[i]
                );
            }
            uint256 remainingValue = beforeValue - afterValue;
            if (remainingValue > 0) {
                TransferETH(payable(msg.sender), remainingValue);
            }
        } else {
            require(msg.value == 0, "Needn't pay mainnet token");
            IERC20 token = IERC20(_tokenAddress);

            uint256 allowed = token.allowance(msg.sender, address(this));
            uint256 total = 0;
            for (uint256 i = 0; i < _value.length; i++) {
                total += _value[i];
            }

            require(total <= allowed, "ERC20 Token Insufficient limit");

            for (uint256 i = 0; i < _to.length; i++) {
                uint256 amount = _value[i];
                token.safeTransferFrom(msg.sender, _to[i], amount);
                emitAirDropToken(
                    _batchNo,
                    _tokenAddress,
                    _to[i],
                    _value[i],
                    _serialNo[i]
                );
            }
        }
    }

    /**
     * @dev batch transfer erc20 token
     *  Batch unlocking of user asset package tokens
     *
     * @param _batchNo Unlock batch number.
     * @param _tokenAddress Unlock token address.
     * @param _to Ap NFT Pledge user address array.
     * @param _value Unlock quantity array.
     * @param _serialNo serial no array.
     */
    function releaseToken(
        uint256 _batchNo,
        address _tokenAddress,
        address[] calldata _to,
        uint256[] calldata _value,
        uint256[] calldata _serialNo
    ) public onlyRole(OPERATOR_ROLE) nonReentrant {
        require(_batchNo > 0, "BatchNo is empty");
        require(
            _to.length == _value.length,
            "The length of array [_to] and array [_value] does not match"
        );
        require(
            _to.length == _serialNo.length,
            "The length of array [_to] and array [_serialNo] does not match"
        );
        require(_to.length <= 1000, "The maximum limit of 1000");

        // Verify drop
        if (bitmap.get(_batchNo)) revert AlreadyDroped();
        // Mark it droped
        bitmap.set(_batchNo);

        uint256 total;
        for (uint256 i; i < _value.length; i++) {
            total += _value[i];
        }

        require(total > 0, "Total value must be getter 0");
        uint256 bal = getWithdrawableAmount(_tokenAddress);
        require(bal > 0, "Total balance must be getter 0");
        require(bal >= total, "Insufficient token balance");

        IERC20 token = IERC20(_tokenAddress);

        for (uint256 i = 0; i < _to.length; i++) {
            uint256 amount = _value[i];
            token.safeTransfer(_to[i], amount);
            emitAirDropToken(
                _batchNo,
                _tokenAddress,
                _to[i],
                _value[i],
                _serialNo[i]
            );
        }
    }

    function emitAirDropToken(
        uint256 _batchNo,
        address _tokenAddress,
        address _to,
        uint256 _value,
        uint256 _serialNo
    ) internal {
        dropBatchNoMap[_batchNo].push(_serialNo);
        serailNoAirDropMap[_serialNo] = AirDrop(
            _batchNo,
            _to,
            _tokenAddress,
            _value,
            _serialNo
        );
        emit AirDropToken(
            _tokenAddress,
            _to,
            _value,
            getCurrentTime(),
            _serialNo,
            _batchNo
        );
    }

    /// @notice Sets the fee for a specific stage
    /// @param _roundID The _roundID identifying the stage
    /// @param _fee The fee amount to set
    /// @dev Only callable by the owner
    function setFee(uint256 _roundID, uint256 _fee) external onlyRole(OPERATOR_ROLE) {
        DropProject storage project = dropProject[_roundID];
        project.fee = _fee;
        emit FeeSet(_roundID, _fee);
    }

    /**
     * @dev withdraw native currency
     *
     */
    function withdraw(address payable _to) public onlyRole(ASSET_ROLE) {
        uint256 balance = address(this).balance;
        // _to.transfer(balance);
        (bool success, ) = _to.call{value: balance}("");
        require(success, "Transfer failed.");
        emit Withdraw(address(0), _to, balance);
    }

    /**
     * @dev get this contract's native currency balance
     * @return balance
     */
    function thisBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev withdraw token
     *
     *
     * @param _token token contract.
     * @param _to  withdraw address.
     */
    function withdrawToken(
        address _token,
        address _to
    ) public onlyRole(ASSET_ROLE) {
        uint256 balance = getWithdrawableAmount(_token);
        IERC20(_token).safeTransfer(_to, balance);
        emit Withdraw(_token, _to, balance);
    }

    /**
     * @dev Returns the amount of tokens that can be withdrawn by the owner.
     * @return the amount of tokens
     */
    function getWithdrawableAmount(
        address _token
    ) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }


    /**
     * @dev Returns the air drop result by serialNo.
     * @param _serialNo Execute batch number
     * @return batchNo
     * @return user
     * @return token
     * @return amount
     * @return serialNo
     */
    function getAirDrop(
        uint256 _serialNo
    ) external view returns (uint256 batchNo, address user, address token, uint256 amount, uint256 serialNo) {
        AirDrop storage drop = serailNoAirDropMap[_serialNo];
          batchNo = drop.batchNo;
          user = drop.user;
          token = drop.token;
          amount = drop.amount;
          serialNo = drop.serialNo;
    }

    /**
     * @dev getDropProject by round id
     * @param _roundId _roundId     
     * @return token 
     * @return startTime 
     * @return endTime 
     * @return fee 
     * @return slicePeriodSeconds 
     * @return merkleRoot 
     */
    function getDropProject(
        uint256 _roundId
    ) public view returns (address token, uint256 startTime, uint256 endTime, uint256 fee, uint256 slicePeriodSeconds, bytes32 merkleRoot) {
        DropProject storage project = dropProject[_roundId];
        token = project.token;
        startTime = project.startTime;
        endTime = project.endTime;
        fee= project.fee;
        slicePeriodSeconds= project.slicePeriodSeconds;
        merkleRoot= project.merkleRoot;
    }

    /**
     * @dev getUserClaimRecord
     * @param _roundId roundId
     * @param _user user address
     * @return user 
     * @return token 
     * @return amount 
     * @return time
     * @return released 
     */
    function getUserClaimRecord(
        uint256 _roundId,
        address _user
    ) public view returns (address user,address token,uint256 amount, uint256 time, uint256 released) {
        ClaimData storage claim = userClaimRecord[_user][_roundId];
        user = claim.user;
        token = claim.token;
        amount = claim.amount;
        time = claim.time;
        // amount of tokens released
        released= claim.released;
    }

    /**
     * @dev getClaimTotal
     * @param _roundId roundId
     * @param _user user address
     * @return
     */
    function getClaimTotal(
        uint256 _roundId,
        address _user
    ) public view returns (uint256) {
       return userClaimTotal[_user][_roundId];
    }

    /**
     * @dev getDropBatchNo
     * @param _batchNo Execute batch number
     * @return serialNo's array
     */
    function getDropBatchNo(
        uint256 _batchNo
    ) public view returns (uint256[] memory) {
        return dropBatchNoMap[_batchNo];
    }


    function TransferETH(address payable _receiver, uint256 _Amount) internal {
        // This forwards all available gas. Be sure to check the return value!
        (bool success, ) = _receiver.call{value: _Amount}("");
        require(success, "Transfer failed.");
    }

    /**
     * @notice Computes the claimed amount of tokens for the given droping schedule identifier.
     * @return the claimed amount
     */
    function computeClaimableAmount(uint256 _roundId, uint256 _amount) external view returns (uint256){
        DropProject storage project = dropProject[_roundId];
        return _computeClaimableAmount(project.startTime, project.endTime, project.slicePeriodSeconds, _amount);
    }
    
    /**
     * @dev Computes the claimed amount of tokens for a droping.
     * @return the amount of claimed tokens
     */
    function _computeClaimableAmount(uint256 startTime, uint256 endTime, uint256 slicePeriodSeconds, uint256 amount) internal view returns (uint256) {
        if(slicePeriodSeconds == 0){
            return amount;
        }
        // Retrieve the current time.
        uint256 currentTime = getCurrentTime();
        // If the current time is before the start time, no tokens are claimable.
        if (currentTime < startTime) {
            return 0;
        }
        // If the current time is after the end time, all tokens are claimable,
        // minus the amount already claimed.
        else if (currentTime >= endTime) {
            return amount;
        }
        // Otherwise, some tokens are claimable.
        else {
            uint256 duration = endTime - startTime;
            // Compute the number of full droping periods that have elapsed.
            uint256 timeFromStart = currentTime - startTime;
            uint256 claimedSlicePeriods = timeFromStart / slicePeriodSeconds;
            uint256 claimedSeconds = claimedSlicePeriods * slicePeriodSeconds;
            // Compute the amount of tokens that are claimed.
            uint256 claimedAmount = amount * claimedSeconds / duration;
            // Subtract the amount already released and return.
            return claimedAmount;
        }
    }

    /**
     * @dev Returns the current time.
     * @return the current timestamp in seconds.
     */
    function getCurrentTime() internal view virtual returns (uint256) {
        return block.timestamp;
    }
}
