// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Arrays.sol";

// TODO: Events, final pricing model, 
contract MemeSubjectShares is AccessControl {

    using Arrays for uint256[];

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    address public protocolFeeDestination;
    uint256 public protocolFeePercent;

    // SharesSubject => bool
    mapping(address => bool) public memeSubject;

    // SharesSubject => (Holder => Balance)
    mapping(address => mapping(address => uint256)) public sharesBalance;
    // SharesSubject => HolderCount
    mapping(address => uint256) public sharesHolders;

    // SharesSubject => Supply
    mapping(address => uint256) public sharesSupply;

    // snapshot
    // Snapshotted values have arrays of ids and the value corresponding to that id. These could be an array of a
    // Snapshot struct, but that would impede usage of functions that work on an array.
    struct Snapshots {
        uint256[] ids;
        uint256[] values;
    }

    // SharesSubject=> Users=> Snapshots
    mapping(address => mapping(address => Snapshots)) private _accountBalanceSnapshots;
    // SharesSubject=> Snapshots
    mapping(address => Snapshots) private _totalSupplySnapshots;

    // Snapshot ids increase monotonically, with the first value being 1. An id of 0 is invalid.
    mapping(address => uint256) private _currentSnapshotId;

    /**
     * @dev Emitted by {_snapshot} when a snapshot identified by `id` is created.
     */
    event Snapshot(address memeToken, uint256 id);
    event CreateSubject(address memeToken, uint256 time);
    event Trade(address trader, address subject, bool isBuy, uint256 shareAmount, uint256 ethAmount, uint256 protocolEthAmount, uint256 txTime, uint256 supply);
    constructor(
        address admin,
        address operator,
        address _feeDestination,
        uint256 _feePercent) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _setRoleAdmin(OPERATOR_ROLE, DEFAULT_ADMIN_ROLE);
        protocolFeeDestination = _feeDestination;
        protocolFeePercent = _feePercent;
    }

    function setFeeDestination(address _feeDestination) public onlyRole(DEFAULT_ADMIN_ROLE) {
        protocolFeeDestination = _feeDestination;
    }

    function setProtocolFeePercent(uint256 _feePercent) public onlyRole(DEFAULT_ADMIN_ROLE) {
        protocolFeePercent = _feePercent;
    }

    function createSubject(address sharesSubject) public onlyRole(OPERATOR_ROLE){
        require(sharesSubject != address(0), "sharesSubject non existent");
        require(!memeSubject[sharesSubject], "Subject already exists");
        memeSubject[sharesSubject] = true;
        buyShares(sharesSubject, 1);
        emit CreateSubject(sharesSubject, block.timestamp);
    }

    function snapshotSubject(address sharesSubject) public onlyRole(OPERATOR_ROLE) {
        _currentSnapshotId[sharesSubject] += 1;
        uint256 currentId = getCurrentSnapshotId(sharesSubject);
        emit Snapshot(sharesSubject, currentId);
    }


    function getPrice(uint256 supply, uint256 amount) public pure returns (uint256) {
        uint256 sum1 = supply == 0 ? 0 : (supply - 1 )* (supply) * (2 * (supply - 1) + 1) / 6;
        uint256 sum2 = supply == 0 && amount == 1 ? 0 : (supply - 1 + amount) * (supply + amount) * (2 * (supply - 1 + amount) + 1) / 6;
        uint256 summation = sum2 - sum1;
        return summation * 1 ether / 16000;
    }

    function getBuyPrice(address sharesSubject, uint256 amount) public view returns (uint256) {
        return getPrice(sharesSupply[sharesSubject], amount);
    }

    function getSellPrice(address sharesSubject, uint256 amount) public view returns (uint256) {
        return getPrice(sharesSupply[sharesSubject] - amount, amount);
    }

    function getBuyPriceAfterFee(address sharesSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getBuyPrice(sharesSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        return price + protocolFee;
    }

    function getSellPriceAfterFee(address sharesSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getSellPrice(sharesSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        return price - protocolFee;
    }

    function buyShares(address sharesSubject, uint256 amount) public payable {
        require(memeSubject[sharesSubject], "sharesSubject non existent");
        require(amount > 0, "Amount must be positive");
        uint256 supply = sharesSupply[sharesSubject];
        require(supply > 0 || hasRole(OPERATOR_ROLE, msg.sender), "Only the shares' subject operator can buy the first share");
        uint256 ethAmount = getPrice(supply, amount);
        uint256 protocolFee = ethAmount * protocolFeePercent / 1 ether;
        require(msg.value >= ethAmount + protocolFee, "Insufficient payment");
        
        uint256 backValue = msg.value - ethAmount - protocolFee;
        if(sharesBalance[sharesSubject][msg.sender] == 0){
            sharesHolders[sharesSubject] += 1;
        }
    
        sharesBalance[sharesSubject][msg.sender] = sharesBalance[sharesSubject][msg.sender] + amount;
        sharesSupply[sharesSubject] = supply + amount;
        emit Trade(msg.sender, sharesSubject, true, amount, ethAmount, protocolFee, block.timestamp, supply + amount);
        if(protocolFee>0){
            TransferETH(protocolFeeDestination, protocolFee);
        }
        if(backValue > 0){
            TransferETH(msg.sender, backValue);
        }
        _beforeTokenTransfer(sharesSubject,msg.sender);
    }

    function sellShares(address sharesSubject, uint256 amount) public payable {
        require(memeSubject[sharesSubject], "sharesSubject non existent");
        require(amount > 0, "Amount must be positive");
        uint256 supply = sharesSupply[sharesSubject];
        require(supply > amount, "Cannot sell the last share");
        uint256 ethAmount = getPrice(supply - amount, amount);
        uint256 protocolFee = ethAmount * protocolFeePercent / 1 ether;
        require(sharesBalance[sharesSubject][msg.sender] >= amount, "Insufficient shares");
        sharesBalance[sharesSubject][msg.sender] = sharesBalance[sharesSubject][msg.sender] - amount;
        sharesSupply[sharesSubject] = supply - amount;
        emit Trade(msg.sender, sharesSubject, false, amount, ethAmount, protocolFee, block.timestamp, supply - amount);

        TransferETH(msg.sender, ethAmount - protocolFee);

        if(protocolFee>0){
            TransferETH(protocolFeeDestination, protocolFee);
        }
        _beforeTokenTransfer(sharesSubject, msg.sender);
        
        if(sharesBalance[sharesSubject][msg.sender] == 0){
            sharesHolders[sharesSubject] -= 1;
        }
    }

    function TransferETH(address _receiver, uint256 _amount) internal {
        // This forwards all available gas. Be sure to check the return value!
        (bool success, ) = _receiver.call{value: _amount}("");
        require(success, "Unable to send funds");
    }

    /**
     * @dev Get the current snapshotId
     */
    function getCurrentSnapshotId(address sharesSubject) public view virtual returns (uint256) {
        return _currentSnapshotId[sharesSubject];
    }

    /**
     * @dev Retrieves the balance of `account` at the time `snapshotId` was created.
     */
    function balanceOfAt(address sharesSubject, address account, uint256 snapshotId) public view virtual returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(sharesSubject, snapshotId, _accountBalanceSnapshots[sharesSubject][account]);

        return snapshotted ? value : sharesBalance[sharesSubject][account];
    }

    /**
     * @dev Retrieves the total supply at the time `snapshotId` was created.
     */
    function totalSupplyAt(address sharesSubject, uint256 snapshotId) public view virtual returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(sharesSubject, snapshotId, _totalSupplySnapshots[sharesSubject]);

        return snapshotted ? value : sharesSupply[sharesSubject];
    }

    // Update balance and/or total supply snapshots before the values are modified. This is implemented
    // in the _beforeTokenTransfer hook, which is executed for _mint, _burn, and _transfer operations.
    function _beforeTokenTransfer(address sharesSubject,address sender) internal virtual {
            _updateAccountSnapshot(sharesSubject, sender);
            _updateTotalSupplySnapshot(sharesSubject);
    }

    function _valueAt(address sharesSubject, uint256 snapshotId, Snapshots storage snapshots) private view returns (bool, uint256) {
        require(snapshotId > 0, "MemeSharesSnapshot: id is 0");
        require(snapshotId <= getCurrentSnapshotId(sharesSubject), "MemeSharesSnapshot: nonexistent id");

        // When a valid snapshot is queried, there are three possibilities:
        //  a) The queried value was not modified after the snapshot was taken. Therefore, a snapshot entry was never
        //  created for this id, and all stored snapshot ids are smaller than the requested one. The value that corresponds
        //  to this id is the current one.
        //  b) The queried value was modified after the snapshot was taken. Therefore, there will be an entry with the
        //  requested id, and its value is the one to return.
        //  c) More snapshots were created after the requested one, and the queried value was later modified. There will be
        //  no entry for the requested id: the value that corresponds to it is that of the smallest snapshot id that is
        //  larger than the requested one.
        //
        // In summary, we need to find an element in an array, returning the index of the smallest value that is larger if
        // it is not found, unless said value doesn't exist (e.g. when all values are smaller). Arrays.findUpperBound does
        // exactly this.

        uint256 index = snapshots.ids.findUpperBound(snapshotId);

        if (index == snapshots.ids.length) {
            return (false, 0);
        } else {
            return (true, snapshots.values[index]);
        }
    }

    function _updateAccountSnapshot(address sharesSubject, address account) private {
        _updateSnapshot(sharesSubject, _accountBalanceSnapshots[sharesSubject][account], sharesBalance[sharesSubject][account]);
    }

    function _updateTotalSupplySnapshot(address sharesSubject) private {
        _updateSnapshot(sharesSubject, _totalSupplySnapshots[sharesSubject], sharesSupply[sharesSubject]);
    }

    function _updateSnapshot(address sharesSubject, Snapshots storage snapshots, uint256 currentValue) private {
        uint256 currentId = getCurrentSnapshotId(sharesSubject);
        if (_lastSnapshotId(snapshots.ids) < currentId) {
            snapshots.ids.push(currentId);
            snapshots.values.push(currentValue);
        }
    }

    function _lastSnapshotId(uint256[] storage ids) private view returns (uint256) {
        if (ids.length == 0) {
            return 0;
        } else {
            return ids[ids.length - 1];
        }
    }
}