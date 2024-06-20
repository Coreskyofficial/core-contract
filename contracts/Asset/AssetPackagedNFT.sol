// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract AssetPackagedNFT is ERC721, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // auto mint tokenid = 1000
    uint256 private BATCH_TOKEN_INC_INDEX = 0;

    // The maximum `quantity` that can be minted with {_mintERC721}.
    // This limit is to prevent overflows on the address data entries.
    // For a limit of 1000, a total of 3.689e15 calls to {_mintERC721}
    // is required to cause an overflow, which is unrealistic.
    uint256 private constant MAX_MINT_QUANTITY_LIMIT = 1000;

    // modify batch start token only modify once.
    bool private modifyBatchToken = false;

    /**
     * batch mint and free mint start tokenId
     */
    uint256 public maxTokenID;
    /**
     * nft baseUri
     */
    string public baseUri;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseUri
    ) ERC721(_name, _symbol) {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(MINTER_ROLE, _msgSender());
        _setupRole(BURNER_ROLE, _msgSender());
        baseUri = _baseUri;
        maxTokenID = BATCH_TOKEN_INC_INDEX;
    }

    function setBatchStartTokenId(uint256 startTokenId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(
            !modifyBatchToken,
            "NFT business has been launched and modification is not allowed."
        );
        BATCH_TOKEN_INC_INDEX= startTokenId;
        maxTokenID = startTokenId;
        modifyBatchToken = true;
    }

    function setBaseURI(string memory _baseURIString)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        baseUri = _baseURIString;
    }

    function _baseURI() internal view override returns (string memory) {
        return baseUri;
    }

    function mint(address _to, uint256 _tokenId)
        external
        onlyRole(MINTER_ROLE)
    {
        require(_to != address(0), "require to address");
        require(_tokenId <= BATCH_TOKEN_INC_INDEX, "Array length must equal. ");
        _mint(_to, _tokenId);
        modifyBatchToken = true;
    }

    function batchMint(address _to, uint256 _amount)
        external
        onlyRole(MINTER_ROLE)
    {
        require(_to != address(0), "require to address");
        require(_amount > 0, "Amount must be greater than 0.");
        require(_amount <= MAX_MINT_QUANTITY_LIMIT, "Quantity overflow 1000.");
        for (uint256 i = 0; i < _amount; i++) {
            maxTokenID = maxTokenID + 1;
            _mint(_to, maxTokenID);
        }
        modifyBatchToken = true;
    }

    function ownerBatchMint(address[] calldata _tos)
        external
        onlyRole(MINTER_ROLE)
    {
        require(_tos.length > 0, "Array length must be greater than 0. ");
        require(
            _tos.length <= MAX_MINT_QUANTITY_LIMIT,
            "Quantity overflow 1000."
        );
        for (uint256 i = 0; i < _tos.length; i++) {
            maxTokenID = maxTokenID + 1;
            _mint(_tos[i], maxTokenID);
        }
        modifyBatchToken = true;
    }

    function burn(uint256 _tokenId) external onlyRole(BURNER_ROLE) {
        _burn(_tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
