// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./ISBT.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "hardhat/console.sol";


contract LUCK_DRAW  is AccessControl  {
    
    bytes32 public constant ROLE_SUPER_ADMIN = keccak256("SUPER_ADMIN_ROLE");
    bytes32 public constant ROLE_ADMIN = keccak256("ADMIN_ROLE");
    bytes32 public constant ROLE_SIGN = keccak256("SIGN_ROLE");

    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using EnumerableMap for EnumerableMap.UintToUintMap;
    using ECDSA for bytes32;

    EnumerableMap.Bytes32ToUintMap private _signMap;
    EnumerableMap.UintToUintMap private avaliableBoxIdMap;
    address public sbtAddress;
    address public assetAddress;

    struct Box {
        uint boxId;
        string name;
        uint boxType;// 0:point 1:nft 2:usdt 
        bool isOpen;
        uint256 rewardNum;
        uint256 availableNum;
        uint256 usedNum;
        address contractAddress;
        uint tokenIndex;
        uint256[] tokenIds;
    }
    Box[] public boxes;

    mapping(uint => uint) public boxIdMap;
    mapping(uint256 => uint256) public awardMap;

    event SEND_REWARD(address sender, uint boxIndex,uint boxType,uint256 rewardNum,uint256 serialNo);

    string public constant PROVENANCE = "CoreSBT-Polygon";
    string public constant OPEN_METHOD = "openBox";

    constructor(address superAdmin, address signer, address admin) {

        _setupRole(ROLE_SUPER_ADMIN, superAdmin);
        _setupRole(ROLE_ADMIN, admin);
        _setupRole(ROLE_SIGN, signer);
        _setRoleAdmin(ROLE_SUPER_ADMIN, ROLE_SUPER_ADMIN);
        _setRoleAdmin(ROLE_ADMIN, ROLE_SUPER_ADMIN);


        boxes.push(Box(0, "", 0 ,false ,0 ,0 ,0 , address(0) ,0,new uint256[](0)));
    }
    

    function setSbtAddress(address _sbtAddress)public onlyRole(ROLE_SUPER_ADMIN){
        sbtAddress = _sbtAddress;
    }
    function setAssetAddress(address _assetAddress)public onlyRole(ROLE_SUPER_ADMIN){
        assetAddress = _assetAddress;
    }

    function viewAvaliableKey() public view returns(uint256[] memory){
        uint256[] memory keys = avaliableBoxIdMap.keys();
        return keys;
    }

    function changeOpen(uint boxId)public onlyRole(ROLE_ADMIN){
        uint boxIndex = boxIdMap[boxId];
        boxes[boxIndex].isOpen = !boxes[boxIndex].isOpen;
        if(boxes[boxIndex].isOpen && (boxes[boxIndex].availableNum - boxes[boxIndex].usedNum > 0)){
            avaliableBoxIdMap.set(boxIndex,boxId);
        }else if(!boxes[boxIndex].isOpen){
            avaliableBoxIdMap.remove( boxIndex);
        }
    }


    function addBox(
        uint _boxId,
        string calldata _name,
        uint _boxType,
        uint256 _rewardNum,
        uint256 _availableNum,
        address _contractAddress,
        uint256[] calldata _tokenIds) public onlyRole(ROLE_ADMIN){
        require(boxIdMap[_boxId] == 0, "exist boxid");
        if(_boxType == 1 || _boxType == 2){
            require(_contractAddress != address(0), "box type can't blank contract address");
        }
        Box memory box = Box(_boxId,_name, _boxType,false,_rewardNum,_availableNum,0,_contractAddress,0,_tokenIds);
        boxes.push(box);
        uint boxesLength = boxes.length;
        boxIdMap[_boxId] = boxesLength-1;
    }

    function isExistsBox(uint boxId) public view returns (bool) {
        uint boxIndex = boxIdMap[boxId];
        if(boxes[boxIndex].boxId > 0){
            return true;
        }
        return false;
    }

    function getBoxNameById(uint boxId)public view returns(string memory){
        uint boxIndex = boxIdMap[boxId];
        return boxes[boxIndex].name;
    }
    function getBoxTypeById(uint boxId)public view returns(uint){
        uint boxIndex = boxIdMap[boxId];
        return boxes[boxIndex].boxType;
    }
    function getBoxOpenById(uint boxId)public view returns(bool){
        uint boxIndex = boxIdMap[boxId];
        return boxes[boxIndex].isOpen;
    }
    function getBoxAvailableNumById(uint boxId)public view returns(uint256){
        uint boxIndex = boxIdMap[boxId];
        return boxes[boxIndex].availableNum - boxes[boxIndex].usedNum;
    }
    function getBoxUsedNumById(uint boxId)public view returns(uint256){
        uint boxIndex = boxIdMap[boxId];
        return boxes[boxIndex].usedNum;
    }
    function getBoxRewardNumById(uint boxId)public view returns(uint256){
        uint boxIndex = boxIdMap[boxId];
        return boxes[boxIndex].rewardNum;
    }
    function setOpenTrue (uint boxId)public onlyRole(ROLE_ADMIN){
        uint boxIndex = boxIdMap[boxId];
        boxes[boxIndex].isOpen = true;
        if(boxes[boxIndex].availableNum - boxes[boxIndex].usedNum > 0){
            avaliableBoxIdMap.set(boxIndex,boxId);
        }
    }
    function setOpenFalse (uint boxId)public onlyRole(ROLE_ADMIN){
        uint boxIndex = boxIdMap[boxId];
        boxes[boxIndex].isOpen = false;
        avaliableBoxIdMap.remove( boxIndex);
    }

    function batchIsExistsBox(uint[] calldata boxIds)public view returns ( bool[] memory){
        bool[] memory retResult = new bool[](boxIds.length);
        for(uint i=0;i<boxIds.length;i++){
            uint boxId = boxIds[i];
            bool isExist = isExistsBox(boxId);
            retResult[i] = isExist;
        }
        return retResult;
    }
    
    function batchGetUsedNum(uint[] calldata boxIds)public view returns ( uint256[] memory){
        uint256[] memory retResult = new uint256[](boxIds.length);
        for(uint i=0;i<boxIds.length;i++){
            uint boxId = boxIds[i];
            uint256 usedNum = getBoxUsedNumById(boxId);
            retResult[i] = usedNum;
        }
        return retResult;
    }
    function batchGetBoxOpen(uint[] calldata boxIds)public view returns ( bool[] memory){
        bool[] memory retResult = new bool[](boxIds.length);
        for(uint i=0;i<boxIds.length;i++){
            uint boxId = boxIds[i];
            bool isExist = getBoxOpenById(boxId);
            retResult[i] = isExist;
        }
        return retResult;
    }

    function batchGetAward(uint256[] calldata serialNos)public view returns ( uint256[] memory){
        uint256[] memory retResult = new uint256[](serialNos.length);
        for(uint i=0;i<serialNos.length;i++){
            uint256 serialNo = serialNos[i];
            uint256 boxId = awardMap[serialNo];
            retResult[i] = boxId;
        }
        return retResult;
    }
    
    function openScore(
        uint256 deadline,
        uint256 amount,
        uint256 serialNo,
        bytes memory signature)public{

        bytes32 signHash = keccak256(signature);
        require(!_signMap.contains(signHash), "Invalid signature");
        require(verifySign( 0,deadline, amount, serialNo, signature),"verify error");
        _signMap.set(signHash, 1);

        open(serialNo);
    }

    function openSbt(
        uint256 tokenId,
        uint256 deadline,
        uint256 amount,
        uint256 serialNo,
        bytes memory signature
    )public{

        bytes32 signHash = keccak256(signature);
        require(!_signMap.contains(signHash), "Invalid signature");
        require(verifySign(tokenId, deadline, amount, serialNo, signature),"verify error");
        _signMap.set(signHash, 1);

        ISbt(sbtAddress).updateSubAmount(tokenId,deadline, amount, serialNo,signature);
        
        open(serialNo);
    }

    function getSelectKeyIndex(uint keyLength,uint256 serialNo)public view returns(uint256){
        bytes32 randomBytes = keccak256(abi.encodePacked(blockhash(block.number-1), msg.sender, block.timestamp,serialNo));
        console.log(uint256(randomBytes));
        return uint256(randomBytes) % keyLength;
    }

    function open(uint256 serialNo)private {
        // Box[] memory tboxes = getAvailableBoxIndex();
        uint256[] memory keys = avaliableBoxIdMap.keys();
        
        uint keyLength = keys.length;
        require(keyLength > 0, "box is empty");
        uint256 selectKeyIndex = getSelectKeyIndex(keyLength,serialNo);
        uint256 selectBoxIndex = keys[selectKeyIndex];

        awardMap[serialNo] = boxes[selectBoxIndex].boxId;

        uint boxType = boxes[selectBoxIndex].boxType;
        uint256 rewardNum = boxes[selectBoxIndex].rewardNum;
        
        boxes[selectBoxIndex].usedNum++;
        if(boxes[selectBoxIndex].availableNum <= boxes[selectBoxIndex].usedNum){
            EnumerableMap.remove(avaliableBoxIdMap, selectBoxIndex);
        }
        if(boxType == 1){
            require(boxes[selectBoxIndex].tokenIds.length > boxes[selectBoxIndex].tokenIndex, "box nft no have");
            uint256 tokenId = boxes[selectBoxIndex].tokenIds[boxes[selectBoxIndex].tokenIndex];
            IERC721(boxes[selectBoxIndex].contractAddress).transferFrom(assetAddress, msg.sender, tokenId);
            boxes[selectBoxIndex].tokenIndex++;
        }else if(boxType == 2){
            IERC20(boxes[selectBoxIndex].contractAddress).transferFrom(assetAddress,msg.sender, rewardNum);
        }
        emit SEND_REWARD(msg.sender,selectBoxIndex,boxType,rewardNum,serialNo);
    }

    
    function verifySign(
        uint256 tokenId,
        uint256 deadline,
        uint256 amount,
        uint256 serialNo,
        bytes memory signature
    ) internal view returns (bool) {
        require(block.timestamp < deadline, "The sign deadline error");
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                PROVENANCE,
                msg.sender,
                tokenId,
                deadline,
                amount,
                serialNo,
                'updateAmount'
            )
        );
        address sysAddress = messageHash.recover(signature);
        return hasRole(ROLE_SIGN, sysAddress);
    }
    
   
}