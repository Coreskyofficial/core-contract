// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "hardhat/console.sol";

interface ISBT721V1 {
    /**
     * @dev This emits when a new token is created and bound to an account by
     * any mechanism.
     * Note: For a reliable `to` parameter, retrieve the transaction's
     * authenticated `to` field.
     */
    event Attest(
        address indexed to,
        uint256 indexed tokenId,
        uint256 indexed amount
    );

    /**
     * @dev This emits when an existing SBT is revoked from an account and
     * destroyed by any mechanism.
     * Note: For a reliable `from` parameter, retrieve the transaction's
     * authenticated `from` field.
     */
    event Revoke(address indexed from, uint256 indexed tokenId);

    /**
     * @dev This emits when an existing SBT is burned by an account
     */
    event Burn(address indexed from, uint256 indexed tokenId);

    /**
     * @dev Emitted when `tokenId` token is transferred from `from` to `to`.
     */
    event Transfer(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId
    );

    /**
     * @dev This emits when an existing SBT is updateAmount by an account
     */
    event UpdateAmount(
        address indexed to,
        uint256 indexed tokenId,
        uint256 indexed balance,
        uint256 amount,
        uint256 serialNo,
        string opType 
    );

    /**
     * @dev Mints SBT
     *
     * Requirements:
     *
     * - `to` must be valid.
     * - `to` must not exist.
     *
     * Emits a {Attest} event.
     * Emits a {Transfer} event.
     * @return The tokenId of the minted SBT
     */
    function attest(address _to, uint256 _amount) external returns (uint256);

    function mint(
        address _to,
        uint256 deadline,
        uint256 level,
        uint256 value,
        uint256 serialNo,
        bytes memory signature
    ) external payable returns (uint256);

    /**
     * @dev Revokes SBT
     *
     * Requirements:
     *
     * - `from` must exist.
     *
     * Emits a {Revoke} event.
     * Emits a {Transfer} event.
     */
    function revoke(address from) external;

    /**
     * @notice At any time, an SBT receiver must be able to
     *  disassociate themselves from an SBT publicly through calling this
     *  function.
     *
     * Emits a {Burn} event.
     * Emits a {Transfer} event.
     */
    function burn(
        uint256 _tokenId,
        uint256 deadline,
        uint256 serialNo,
        bytes memory signature
    ) external;

    /**
     * @notice Count all SBTs assigned to an owner
     * @dev SBTs assigned to the zero address is considered invalid, and this
     * function throws for queries about the zero address.
     * @param owner An address for whom to query the balance
     * @return The number of SBTs owned by `owner`, possibly zero
     */
    function balanceOf(address owner) external view returns (uint256);

    /**
     * @param from The address of the SBT owner
     * @return The tokenId of the owner's SBT, and throw an error if there is no SBT belongs to the given address
     */
    function tokenIdOf(address from) external view returns (uint256);

    /**
     * @notice Find the address bound to a SBT
     * @dev SBTs assigned to zero address are considered invalid, and queries
     *  about them do throw.
     * @param tokenId The identifier for an SBT
     * @return The address of the owner bound to the SBT
     */
    function ownerOf(uint256 tokenId) external view returns (address);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);
}

/**
 * @title ERC-721 Non-Fungible Token Standard, optional metadata extension
 * @dev See https://eips.ethereum.org/EIPS/eip-721
 */
interface IERC721MetadataV1 is ISBT721V1 {
    /**
     * @dev Returns the token collection name.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the token collection symbol.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the Uniform Resource Identifier (URI) for `tokenId` token.
     */
    function tokenURI(uint256 tokenId) external view returns (string memory);

    /**
     * @dev Returns the token amount.
     */
    function getAmountByToken(uint256 tokenId) external view returns (uint256);

    /**
     * @dev Returns the token amount.
     */
    function getAmountByAddress(address owner) external view returns (uint256);
}

contract CoreSBTPolyV1 is AccessControl, Pausable, IERC721MetadataV1 {
    using Strings for uint256;
    using ECDSA for bytes32;
    using ECDSA for bytes;
    using Counters for Counters.Counter;
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableMap for EnumerableMap.UintToAddressMap;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    bytes32 public constant ROLE_SUPER_ADMIN = keccak256("SUPER_ADMIN_ROLE");
    bytes32 public constant ROLE_ADMIN = keccak256("ADMIN_ROLE");
    bytes32 public constant ROLE_SIGN = keccak256("SIGN_ROLE");
    bytes32 public constant ROLE_SIGN_AMDIN = keccak256("ROLE_SIGN_AMDIN");

    string public constant PROVENANCE = "CoreSBT-Polygon";
    // Method name
    string public constant MINT_METHOD = "mint";
    string public constant BURN_METHOD = "burn";
    string public constant UPDATE_AMOUNT_METHOD = "updateAmount";

    // Token name
    string public override name;
    // Token symbol
    string public override symbol;
    // Token uri
    string public baseTokenURI;
    // Mapping from token ID to owner address
    EnumerableMap.UintToAddressMap private _ownerMap;
    EnumerableMap.AddressToUintMap private _tokenMap;
    EnumerableMap.Bytes32ToUintMap private _signMap;
    // Token Id Counter
    Counters.Counter public _tokenIdCounter;
    // Token=> amount
    mapping(uint256 => uint256) public _tokenAmountMap;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseTokenURI,
        address owner,
        address signer
    ) {
        name = _name;
        symbol = _symbol;
        baseTokenURI = _baseTokenURI;

        _setupRole(ROLE_SUPER_ADMIN, owner);
        _setupRole(ROLE_ADMIN, owner);
        _setRoleAdmin(ROLE_SUPER_ADMIN, ROLE_SUPER_ADMIN);
        _setRoleAdmin(ROLE_ADMIN, ROLE_SUPER_ADMIN);
        _setRoleAdmin(ROLE_SIGN_AMDIN, ROLE_SUPER_ADMIN);
        _setupRole(ROLE_SIGN, signer);
    }

    function pause() public onlyRole(ROLE_SUPER_ADMIN) {
        _pause();
    }

    function unpause() public onlyRole(ROLE_SUPER_ADMIN) {
        _unpause();
    }

    /**
     * @dev Update _baseTokenURI
     */
    function setBaseTokenURI(string calldata uri)
        public
        whenNotPaused
        onlyRole(ROLE_ADMIN)
    {
        baseTokenURI = uri;
    }

    /**
     * @dev Get _baseTokenURI
     */
    function _baseURI() internal view returns (string memory) {
        return baseTokenURI;
    }

    /**
     * @dev Update symbol
     */
    function setSymbol(string calldata _symbol)
        public
        whenNotPaused
        onlyRole(ROLE_ADMIN)
    {
        symbol = _symbol;
    }

    /**
     * @dev Update name
     */
    function setName(string calldata _name)
        public
        whenNotPaused
        onlyRole(ROLE_ADMIN)
    {
        name = _name;
    }

    /**
     * @dev mint SBT by admin.
     */
    function attest(address _to, uint256 _amount)
        external
        override
        whenNotPaused
        onlyRole(ROLE_ADMIN)
        returns (uint256)
    {
        require(_to != address(0), "Address is empty");
        require(_amount != 0, "amount is empty");
        require(!_tokenMap.contains(_to), "SBT already exists");
        _tokenIdCounter.increment();
        emit Attest(_to, _tokenIdCounter.current(), _amount);
        return _mint(_to, _tokenIdCounter.current(), _amount);
    }

    /**
     * @dev batch mint SBT by admin.
     */
    function batchAttest(address[] calldata addrs, uint256 amount)
        external
        whenNotPaused
        onlyRole(ROLE_ADMIN)
    {
        uint256 addrLength = addrs.length;
        require(addrLength <= 100, "The max length of addresses is 100");
        require(amount != 0, "amount is empty");
        for (uint8 i = 0; i < addrLength; i++) {
            address to = addrs[i];
            if (to == address(0) || _tokenMap.contains(to)) {
                continue;
            }
            _tokenIdCounter.increment();
            emit Attest(to, _tokenIdCounter.current(), amount);
            _mint(to, _tokenIdCounter.current(), amount);
        }
    }

    /**
     * @dev revoke SBT by admin.
     */
    function revoke(address from)
        external
        override
        whenNotPaused
        onlyRole(ROLE_ADMIN)
    {
        require(from != address(0), "Address is empty");
        require(_tokenMap.contains(from), "The account does not have any SBT");
        _revoke(from);
    }

    /**
     * @dev batch revoke SBT by admin.
     */
    function batchRevoke(address[] calldata addrs)
        external
        whenNotPaused
        onlyRole(ROLE_ADMIN)
    {
        uint256 addrLength = addrs.length;
        require(addrLength <= 100, "The max length of addresses is 100");
        for (uint8 i = 0; i < addrLength; i++) {
            address from = addrs[i];
            if (from == address(0) || !_tokenMap.contains(from)) {
                continue;
            }
            _revoke(from);
        }
    }

    /**
     * @dev Revoke SBT which address is `from`.
     *
     */
    function _revoke(address from) internal {
        uint256 tokenId = _tokenMap.get(from);
        _tokenMap.remove(from);
        _ownerMap.remove(tokenId);
        _tokenAmountMap[tokenId] = 0;
        emit Revoke(from, tokenId);
        emit Transfer(from, address(0), tokenId);
    }

    function mint(
        address _to,
        uint256 deadline,
        uint256 amount,
        uint256 value,
        uint256 serialNo,
        bytes memory signature
    ) public payable override whenNotPaused returns (uint256) {
        require(msg.value >= value, "Value sent does not match value received");
        require(msg.sender == _to, "Mint _to address error");
        // sign verify
        bytes32 signHash = keccak256(signature);
        require(!_signMap.contains(signHash), "Invalid signature");
        require(verifyMint(_to, deadline, amount, value, serialNo, signature));

        _signMap.set(signHash, 1);
        uint256 tokenId = 0;
        if (_tokenMap.contains(_to)) {
            tokenId = _tokenMap.get(_to);
            _tokenAmountMap[tokenId] += amount;

        } else {
            _tokenIdCounter.increment();
            tokenId = _mint(_to, _tokenIdCounter.current(), amount);
        }
        
        emit UpdateAmount(_to, tokenId, _tokenAmountMap[tokenId], amount, serialNo, MINT_METHOD);
        return tokenId;
    }

    /**
     * @dev Mints `tokenId` and transfers it to `to`.
     *
     * Requirements:
     *
     * - `tokenId` must not exist.
     * - `to` cannot be the zero address.
     *
     * Emits a {Attest} event.
     * Emits a {Transfer} event.
     */
    function _mint(
        address to,
        uint256 tokenId,
        uint256 amount
    ) internal returns (uint256) {
        require(to != address(0), "Address is empty");
        require(!_tokenMap.contains(to), "SBT already exists");

        _tokenMap.set(to, tokenId);
        _ownerMap.set(tokenId, to);
        _tokenAmountMap[tokenId] = amount;

        emit Transfer(address(0), to, tokenId);
        return tokenId;
    }

    /**
     * @dev Burns `tokenId`.
     *
     * Requirements:
     *
     * - The caller must own `tokenId` and has the correct signature.
     */
    function burn(
        uint256 _tokenId,
        uint256 deadline,
        uint256 serialNo,
        bytes memory signature
    ) public override whenNotPaused {
        // sign verify
        bytes32 signHash = keccak256(signature);
        require(!_signMap.contains(signHash), "Invalid signature");

        require(verifyBurn(_tokenId, deadline, serialNo, signature), "Sign verify error");
        address sender = _msgSender();
        require(
            _tokenMap.contains(sender),
            "The account does not have any SBT"
        );
        require(_tokenId == _tokenMap.get(sender), "TokenId verify error");
        _tokenMap.remove(sender);
        _ownerMap.remove(_tokenId);
        _tokenAmountMap[_tokenId] = 0;

        _signMap.set(signHash, 1);
        emit Burn(sender, _tokenId);
        emit Transfer(sender, address(0), _tokenId);
        emit UpdateAmount(sender, _tokenId, 0, 0, serialNo, BURN_METHOD);
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(
            _ownerMap.contains(tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );
        string memory baseURI = _baseURI();
        return
            bytes(baseURI).length > 0
                ? string(abi.encodePacked(baseURI, tokenId.toString()))
                : "";
    }

    /**
     * @dev See {IERC721-balanceOf}.
     */
    function balanceOf(address owner) external view override returns (uint256) {
        (bool success, ) = _tokenMap.tryGet(owner);
        return success ? 1 : 0;
    }

    /**
     * @dev Returns a token ID owned by `from`
     */
    function tokenIdOf(address from) external view override returns (uint256) {
        return _tokenMap.get(from, "The wallet has not hold any SBT");
    }

    /**
     * @dev See {IERC721-ownerOf}.
     */
    function ownerOf(uint256 tokenId) external view override returns (address) {
        return _ownerMap.get(tokenId, "Invalid tokenId");
    }

    /**
     * @dev Returns the total amount of tokens stored by the contract.
     */
    function totalSupply() external view override returns (uint256) {
        return _tokenMap.length();
    }

    /**
     * @dev Verify mint signature.
     */
    function verifyMint(
        address _to,
        uint256 deadline,
        uint256 amount,
        uint256 value,
        uint256 serialNo,
        bytes memory signature
    ) internal view returns (bool) {
        require(block.timestamp < deadline, "The sign deadline error");
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                PROVENANCE,
                _to,
                deadline,
                amount,
                value,
                serialNo,
                MINT_METHOD
            )
        );
        return hasRole(ROLE_SIGN, messageHash.recover(signature));
    }

    /**
     * @dev Verify burn signature.
     */
    function verifyBurn(
        uint256 tokenId,
        uint256 deadline,
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
                serialNo,
                BURN_METHOD
            )
        );
        return hasRole(ROLE_SIGN, messageHash.recover(signature));
    }

    /**
     * @dev Verify mint signature.
     */
    function verifyUpdateAmount(
        uint256 tokenId,
        uint256 deadline,
        uint256 amount,
        uint256 serialNo,
        bytes memory signature
    ) internal view returns (bool) {
        require(_ownerMap.contains(tokenId), "nonexistent token");
        require(block.timestamp < deadline, "The sign deadline error");
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                PROVENANCE,
                msg.sender,
                tokenId,
                deadline,
                amount,
                serialNo,
                UPDATE_AMOUNT_METHOD
            )
        );
        return hasRole(ROLE_SIGN, messageHash.recover(signature)) || hasRole(ROLE_SIGN_AMDIN, msg.sender);
    }

    /**
     * @dev Returns the token amount.
     */
    function getAmountByToken(uint256 tokenId) external view returns (uint256) {
        require(_ownerMap.contains(tokenId), "nonexistent token");
        return _tokenAmountMap[tokenId];
    }

    /**
     * @dev Returns the token amount.
     */
    function getAmountByAddress(address from) external view returns (uint256) {
        require(_tokenMap.contains(from), "nonexistent token");
        uint256 tokenId = _tokenMap.get(
            from,
            "The wallet has not hold any SBT"
        );
        return _tokenAmountMap[tokenId];
    }

    /**
     * @dev Update the token amount.
     */
    function updateAddAmount(
        uint256 tokenId,
        uint256 deadline,
        uint256 amount,
        uint256 serialNo,
        bytes memory signature
    ) public whenNotPaused {
        // update amount verify
        require(amount > 0, "SBT: Quantity must be greater than 0");
        bytes32 signHash = keccak256(signature);
        require(!_signMap.contains(signHash), "Invalid signature");

        require(
            verifyUpdateAmount(tokenId, deadline, amount,serialNo, signature),
            "SBT: Sign verify error"
        );
        _signMap.set(signHash, 1);
        _tokenAmountMap[tokenId] += amount;

        emit UpdateAmount(
            msg.sender,
            tokenId,
            _tokenAmountMap[tokenId],
            amount,
            serialNo,
            "add"
        );
    }

    /**
     * @dev Update the token amount.
     */
    function updateSubAmount(
        uint256 tokenId,
        uint256 deadline,
        uint256 amount,
        uint256 serialNo,
        bytes memory signature
    ) public whenNotPaused {
        // update Amount verify
        require(amount > 0, "SBT: Quantity must be greater than 0");
        require(
            _tokenAmountMap[tokenId] >= amount,
            "SBT: The value passed is greater than the balance quantity"
        );

        bytes32 signHash = keccak256(signature);
        require(!_signMap.contains(signHash), "Invalid signature");
        require(
            verifyUpdateAmount(tokenId, deadline, amount,serialNo, signature),
            "SBT: Sign verify error"
        );
    
        _signMap.set(signHash, 1);
        _tokenAmountMap[tokenId] -= amount;

        emit UpdateAmount(
            msg.sender,
            tokenId,
            _tokenAmountMap[tokenId],
            amount,
            serialNo,
            "sub"
        );
    }

    function withdraw() public onlyRole(ROLE_ADMIN) {
        payable(msg.sender).transfer(address(this).balance);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721MetadataV1).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
