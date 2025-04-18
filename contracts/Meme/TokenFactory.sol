// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {Token} from "./Token.sol";
// import "hardhat/console.sol";

error AlreadyUsed(uint256 serialNo);
contract TokenFactory is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{

    struct TokenInfo {
        address base;         // Address of the base token
        address quote;        // 报价Token
        uint256 template;     // 模板ID
        uint256 totalSupply;  // 总供应量
        uint256 maxOffers;    // 最大offers数量
        uint256 maxRaising;   // 最大募集金额(wei)
        uint256 launchTime;   // 启动时间戳
        uint256 offers;       // offer数量
        uint256 funds;        // 已募集资金(wei)
        uint256 lastPrice;    // 最后交易价格(wei)
        uint256 K;            // 价格曲线参数
        uint256 T;            // 时间衰减参数
        uint256 status;       // 当前状态
        uint256 v;            // 版本
    }

    struct Template {
        address bondingCurve;      // Bonding Curve
        address quote;             // 报价代币地址
        uint256 initialLiquidity;  // 初始流动性(wei)
        uint256 maxRaising;        // 最大募集金额(wei)
        uint256 totalSupply;       // 代币总量
        uint256 maxOffers;         // 最大报价数量
        uint256 minTradingFee;     // 最小交易费(wei)
    }

    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;
    using ECDSA for bytes32;
    using ECDSA for bytes;


    enum TokenState {
        NOT_CREATED,
        CREATED,
        FUNDING,
        TRADING
    }

    bytes32 public constant BOT_SIGN_CREATE_TOKEN = keccak256('createToken(uint256 roundId,string name,string symbol,uint256 deadline)');
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ASSET_ROLE = keccak256("ASSET_ROLE");

    // 1 Billion
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;
    // initial supply 1/5 = 200_000_000
    uint256 public constant INITIAL_SUPPLY = (MAX_SUPPLY * 1) / 5;
    // funding supply 4/5 = 800_000_000
    uint256 public constant FUNDING_SUPPLY = (MAX_SUPPLY * 4) / 5;
    // fee denominator
    uint256 public constant FEE_DENOMINATOR = 10000;

    // funding goal
    uint256 public FUNDING_GOAL;

    // rounID => issue token tokenAddr
    mapping(uint256 => address) public tokensById;
    // distribute status of index
    BitMaps.BitMap bitmap;    
    // signature => exsist: 0 or 1 
    mapping(bytes32 =>uint8) public signMap;
    // issue token tokenAddr=> TotenState
    mapping(address => TokenState) public tokens;
    // tokenCollateral => amount
    mapping(address => uint256) public collateral;
    // Meme Token Implementation
    address public tokenImplementation;
    address public uniswapV2Router;
    address public uniswapV2Factory;
    BondingCurve public bondingCurve;
    // bp
    uint256 public feePercent;
    // fee 
    uint256 fee;
    // payment token
    address public paymentToken;

    // token => fee  
    mapping(address => uint256) public tradingTotalFeeByToken;
    // paytoken => fee  
    mapping(address => uint256) public tradingTotalFeeByQuote;
    /// @dev 支持付款代币模板列表
    Template[] public _templates;
    /// @dev 模版数量
    uint256 public _templateCount;
    /// @dev 默认模版 模版为空默认原生币支付
    uint256 public _defaultTemplate;
    // mmtoken => tokenInfo
    mapping(address => TokenInfo) public _tokenInfos;
    // fee recipient
    address public feeRecipient;

    // Events
    event TokenCreated(address indexed token, uint256 roundID, uint256 timestamp);
    event TokenLiqudityAdded(address indexed token, uint256 timestamp);
    event Withdraw(
        address indexed _token,
        address indexed _to,
        uint256 indexed _amount
    );
    event DropToken(
        address indexed _token,
        address indexed _to,
        uint256 indexed _amount
    );

    event Launch(address indexed token, address memeRecipient, uint256 recipientAmount, uint256 sendAmount, uint256 timestamp);

    event Buy(address indexed token, address indexed account, uint256 serialNo, address quote, uint256 offerAmount, uint256 tokenAmount, uint256 timestamp);

    event Sell(address indexed token, address indexed account, uint256 serialNo, address quote, uint256 offerAmount, uint256 tokenAmount, uint256 timestamp);

    /**
     * @dev Initializes the contract by setting a `admin_` and a `operator_` to the Alloction.
     */
    function initialize(
        address _admin,
        address _operator,
        address _paymentToken,
        address _tokenImplementation,
        address _uniswapV2Router,
        address _uniswapV2Factory,
        address _bondingCurve,
        uint256 _feePercent
    ) public initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
        _setRoleAdmin(OPERATOR_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ASSET_ROLE, DEFAULT_ADMIN_ROLE);
        paymentToken = _paymentToken;
        tokenImplementation = _tokenImplementation;
        uniswapV2Router = _uniswapV2Router;
        uniswapV2Factory = _uniswapV2Factory;
        bondingCurve = BondingCurve(_bondingCurve);
        feePercent = _feePercent;
        FUNDING_GOAL = 100000 ether;
        addTemplate(
         _bondingCurve,
         _paymentToken,
         INITIAL_SUPPLY,
         FUNDING_GOAL,
         MAX_SUPPLY,
         FUNDING_SUPPLY,
         _feePercent)
         ;
         _defaultTemplate = _templateCount - 1;
    }


    // Admin functions
    function updateSwapAddress(
        address _swapV2Router,
        address _swapV2Factory
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uniswapV2Router = _swapV2Router;
        uniswapV2Factory = _swapV2Factory;
    }

    function setTokenImpl(
        address _tokenImplementation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenImplementation = _tokenImplementation;
    }

    function setFundingGoal(
        uint256 _fundingGoal
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        FUNDING_GOAL = _fundingGoal;
        _templates[_defaultTemplate].maxRaising = _fundingGoal;
    }

    function setFeeRecipient(
        address _feeRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeRecipient = _feeRecipient;
    }

    function setFeePercent(
        uint256 _feePercent
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feePercent = _feePercent;
        _templates[_defaultTemplate].minTradingFee = _feePercent;
    }


    /**
     * addTemplate
     * 
     * @param _bondingCurve   Bonding Curve
     * @param _quote  报价代币地址
     * @param _initialLiquidity  初始流动性(wei)
     * @param _maxRaising  最大募集金额(wei)
     * @param _totalSupply 代币总量
     * @param _maxOffers   最大出价金额(wei)
     * @param _minTradingFee  最小交易费(wei)
     */
    function addTemplate(
        address _bondingCurve,
        address _quote,
        uint256 _initialLiquidity,
        uint256 _maxRaising,
        uint256 _totalSupply,
        uint256 _maxOffers,
        uint256 _minTradingFee
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _templateCount++;
        _templates.push(Template(_bondingCurve, _quote, _initialLiquidity, _maxRaising, _totalSupply, _maxOffers, _minTradingFee));
    }

    function setDefaultTemplate(
        uint256 _tempIndex
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_templateCount > 0 && _templateCount > _tempIndex, "Temppate is not exists");
        _defaultTemplate = _tempIndex;
    }

    function setPaymentToken(
        address _paymentToken
    ) external onlyRole(OPERATOR_ROLE) {
        paymentToken = _paymentToken;
        _templates[_defaultTemplate].quote = _paymentToken;
    }

    function setBondingCurve(
        address _bondingCurve
    ) external onlyRole(OPERATOR_ROLE) {
        bondingCurve = BondingCurve(_bondingCurve);
    }
    
    // Token functions
    function createToken(
        uint256 roundID,
        string memory name,
        string memory symbol,
        uint256 deadline,
        bytes memory botSignature
    ) external returns (address) {
        require(roundID > 0, "RoundID is empty");
        require(tokensById[roundID] == address(0), "RoundID already exists");
        // sign verify
        bytes32 signHash = keccak256(botSignature);
        require(signMap[signHash] == 0, "Token already exists");
        address _recoveredSigner = recoveredSigner(
                roundID,
                name,
                symbol,
                deadline, 
                botSignature);
        
        require(hasRole(OPERATOR_ROLE, _recoveredSigner), "BotSignatureInvalid");
        signMap[signHash] = 1;

        address tokenAddress = Clones.clone(tokenImplementation);
        Token token = Token(tokenAddress);
        token.initialize(name, symbol);
        tokens[tokenAddress] = TokenState.CREATED;
        tokensById[roundID] = tokenAddress;

        require(_templates.length > 0, "Template is empty");
        TokenInfo storage info = _tokenInfos[tokenAddress];
        Template memory t = _templates[_defaultTemplate];

        info.base = tokenAddress;         // Address of the base token
        info.template = _defaultTemplate;     // 模板ID
        info.quote = t.quote;        // Address of the quote token which is the token traded by. If quote returns address 0, it means the token is traded by BNB. otherwise traded by BEP20
        info.totalSupply = t.totalSupply;  // 总供应量
        info.maxOffers = t.maxOffers;    // 最大报价数量
        info.maxRaising = t.maxRaising;   // 最大募集金额(wei)
        info.K = BondingCurve(t.bondingCurve).B();            // 价格曲线参数
        info.T = BondingCurve(t.bondingCurve).A();            // 时间衰减参数
        
        info.launchTime = block.timestamp;   // 启动时间戳
        info.status = uint256(TokenState.CREATED); // 当前状态
        info.v = 1;

        emit TokenCreated(tokenAddress, roundID, block.timestamp);
        return tokenAddress;
    }
    
    /**
     * @dev recoveredSigner.
     */
    function recoveredSigner(
        uint256 _roundID,
        string memory _name,
        string memory _symbol,
        uint256 deadline,
        bytes memory signature
    ) internal view returns (address) {
        require(block.timestamp < deadline, "The sign deadline error");
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                BOT_SIGN_CREATE_TOKEN,
                msg.sender,
                _roundID,
                _name,
                _symbol,
                deadline
            )
        );
        return messageHash.recover(signature);
    }


    function launch(
        address tokenAddress,
        uint256 quantity,
        address memeRecipient,
        address[] calldata users,
        uint256[] calldata amounts
    ) external payable nonReentrant onlyRole(ASSET_ROLE) {
        require(memeRecipient != address(0), "memeRecipient is empty");
        require(tokens[tokenAddress] == TokenState.CREATED, "Token not found");
        require(quantity > 0, "The quantity must be greater than 0");
        require(
            users.length == amounts.length,
            "users, amounts array data mismatch"
        );
        require(_templates.length > 0, "Template is empty");
        TokenInfo storage tokenInfo = _tokenInfos[tokenAddress];
        Template memory t = _templates[tokenInfo.template];
        if(tokenInfo.v == 0){
            tokenInfo.base = tokenAddress;         // Address of the base token
            tokenInfo.template = _defaultTemplate;     // 模板ID
            tokenInfo.quote = paymentToken;           // Address of the quote token which is the token traded by. If quote returns address 0, it means the token is traded by BNB. otherwise traded by BEP20
            tokenInfo.totalSupply = MAX_SUPPLY;       // 总供应量
            tokenInfo.maxOffers =   FUNDING_SUPPLY;   // 最大Offers数量
            tokenInfo.maxRaising = FUNDING_GOAL;      // 最大募集金额(wei)
            tokenInfo.K = bondingCurve.B();           // 价格曲线参数
            tokenInfo.T = bondingCurve.A();           // 时间衰减参数
            tokenInfo.launchTime = block.timestamp;   // 启动时间戳
            tokenInfo.status = uint256(TokenState.CREATED); // 当前状态
            tokenInfo.v = 1;
            t.initialLiquidity = INITIAL_SUPPLY;
        }
        uint256 valueToBuy;
        if (tokenInfo.quote == address(0)) {
            valueToBuy = msg.value;
            require(valueToBuy > 0 && valueToBuy >= quantity, "ETH not enough");
        } else {
            valueToBuy = quantity;
            require(valueToBuy > 0, "Token quantity not enough");
            require(msg.value == 0, "Needn't pay mainnet token");
            // Transfer the total payment from the sender to the project receipt address
            IERC20(tokenInfo.quote).safeTransferFrom(
                msg.sender,
                address(this),
                valueToBuy
            );
        }

        // 盘内交易Token数量
        uint256 tokenCollateral = tokenInfo.funds;
        // 剩余额度
        uint256 remainingEthNeeded = tokenInfo.maxRaising - tokenCollateral;
        // 扣除手续费后购买数量
        uint256 contributionWithoutFee = valueToBuy > remainingEthNeeded
            ? remainingEthNeeded
            : valueToBuy;
        Token token = Token(tokenAddress);
        uint256 amount = BondingCurve(t.bondingCurve).getAmountOut(
            token.totalSupply(),
            contributionWithoutFee
        );
        uint256 availableSupply = tokenInfo.maxOffers - token.totalSupply();
        require(amount <= availableSupply, "Token supply not enough");
        tokenCollateral += contributionWithoutFee;
        uint256 sendTotal;
        for (uint256 i; i < users.length; i++) {
            sendTotal += amounts[i];
        }
        require(sendTotal <= amount, "Insufficient pre-market quota");

        for (uint256 i; i < users.length; i++) {
            token.mint(users[i], amounts[i]);
            emit DropToken(tokenAddress, users[i], amounts[i]);
        }
        // launch memme init mint
        uint256 recipientAmount = (amount - sendTotal);
        token.mint(memeRecipient, recipientAmount);
        // when reached FUNDING_GOAL
        if (tokenCollateral >= tokenInfo.maxRaising) {
            token.mint(address(this), t.initialLiquidity);
            address pair = createLiquilityPool(tokenAddress, tokenInfo.quote);
            uint256 liquidity = addLiquidity(
                tokenAddress, 
                tokenInfo.quote,
                t.initialLiquidity,
                tokenCollateral
            );
            burnLiquidityToken(pair, liquidity);
            tokenCollateral = 0;
            tokens[tokenAddress] = TokenState.TRADING;
            tokenInfo.status = uint256(TokenState.TRADING);
            emit TokenLiqudityAdded(tokenAddress, block.timestamp);
        }
        tokenInfo.offers = amount;
        tokenInfo.funds = tokenCollateral;
        tokens[tokenAddress] = TokenState.FUNDING;
        tokenInfo.status = uint256(TokenState.FUNDING);
        emit Launch(tokenAddress, memeRecipient, recipientAmount, sendTotal, block.timestamp);
    }

    function buy(
        uint256 serialNo,
        address tokenAddress,
        uint256 quantity
    ) external payable nonReentrant {
        TokenInfo storage tokenInfo = _tokenInfos[tokenAddress];
        require(_templates.length > 0, "Template is empty");
        Template memory t = _templates[tokenInfo.template];
        require(
            tokens[tokenAddress] == TokenState.FUNDING,
            "Funding has not start"
        );
        // Verify used
        if (bitmap.get(serialNo)) revert AlreadyUsed(serialNo);
        // Mark it used
        bitmap.set(serialNo);

        require(quantity > 0, "The quantity must be greater than 0");
        uint256 valueToBuy;
        if (tokenInfo.quote == address(0)) {
            valueToBuy = msg.value;
            require(valueToBuy > 0 && valueToBuy >= quantity, "ETH not enough");
        } else {
            valueToBuy = quantity;
            require(valueToBuy > 0, "Token quantity not enough");
            require(msg.value == 0, "Needn't pay mainnet token");
            // Transfer the total payment from the sender to the project receipt address
            IERC20(tokenInfo.quote).safeTransferFrom(
                msg.sender,
                address(this),
                valueToBuy
            );
        }

        // 盘内交易Token数量
        uint256 tokenCollateral = tokenInfo.funds;
        // 剩余额度
        uint256 remainingEthNeeded = tokenInfo.maxRaising - tokenCollateral;

        
        if(feeRecipient == address(0)){
            feePercent = 0;
        }
        // 扣除手续费后购买数量
        uint256 contributionWithoutFee = (valueToBuy * FEE_DENOMINATOR) / (FEE_DENOMINATOR + feePercent);
        // 如果购买数量 大于 剩余额度 则购买剩余全部
        if (contributionWithoutFee > remainingEthNeeded) {
            contributionWithoutFee = remainingEthNeeded;
        }
        // calculate fee
        uint256 _fee = calculateFee(contributionWithoutFee, feePercent);
        uint256 totalCharged = contributionWithoutFee + _fee;
        uint256 valueToReturn = valueToBuy > totalCharged
            ? valueToBuy - totalCharged
            : 0;

        tradingTotalFeeByToken[tokenAddress] += _fee;
        tradingTotalFeeByQuote[tokenInfo.quote] += _fee;

        Token token = Token(tokenAddress);
        uint256 amount = BondingCurve(t.bondingCurve).getAmountOut(
            token.totalSupply(),
            contributionWithoutFee
        );
        uint256 availableSupply = tokenInfo.maxOffers - token.totalSupply();
        require(amount <= availableSupply, "Token supply not enough");
        tokenCollateral += contributionWithoutFee;
        token.mint(msg.sender, amount);
        // when reached FUNDING_GOAL
        if (tokenCollateral >= tokenInfo.maxRaising) {
            token.mint(address(this), t.initialLiquidity);
            address pair = createLiquilityPool(tokenAddress, tokenInfo.quote);
            uint256 liquidity = addLiquidity(
                tokenAddress,
                tokenInfo.quote,
                t.initialLiquidity,
                tokenCollateral
            );
            burnLiquidityToken(pair, liquidity);
            tokenCollateral = 0;
            tokens[tokenAddress] = TokenState.TRADING;
            tokenInfo.status = uint256(TokenState.TRADING);
            emit TokenLiqudityAdded(tokenAddress, block.timestamp);
        }
        collateral[tokenAddress] = tokenCollateral;
        tokenInfo.funds = tokenCollateral;
    
        if(feeRecipient != address(0) && _fee > 0){
            Transfer(feeRecipient, tokenInfo.quote, _fee);
        }
        // return left
        if (valueToReturn > 0) {
            Transfer(msg.sender, tokenInfo.quote, valueToReturn);
        }

        emit Buy(tokenAddress, msg.sender, serialNo, paymentToken, quantity,  amount, block.timestamp);
    }

    function sell(uint256 serialNo, address tokenAddress, uint256 amount) external nonReentrant {
        TokenInfo storage tokenInfo = _tokenInfos[tokenAddress];
        require(_templates.length > 0, "Template is empty");
        Template memory t = _templates[tokenInfo.template];
        // Verify used
        if (bitmap.get(serialNo)) revert AlreadyUsed(serialNo);
        // Mark it used
        bitmap.set(serialNo);
        require(
            tokens[tokenAddress] == TokenState.FUNDING,
            "Funding has not start"
        );
        require(amount > 0, "Amount should be greater than zero");
        Token token = Token(tokenAddress);
        uint256 receivedToken = BondingCurve(t.bondingCurve).getFundsReceived(
            token.totalSupply(),
            amount
        );
        // calculate fee
        uint256 _fee = calculateFee(receivedToken, (feeRecipient == address(0) ? 0 : feePercent));
        receivedToken -= _fee;
        tradingTotalFeeByToken[tokenAddress] += _fee;
        tradingTotalFeeByQuote[tokenInfo.quote] += _fee;
        token.burn(msg.sender, amount);
        tokenInfo.funds -= receivedToken;

        if(feeRecipient != address(0) && _fee > 0){
            Transfer(feeRecipient, tokenInfo.quote, _fee);
        }
        Transfer(msg.sender, tokenInfo.quote, receivedToken);
        emit Sell(tokenAddress, msg.sender, serialNo, paymentToken, amount,  receivedToken, block.timestamp);
    }

    // Internal functions

    function createLiquilityPool(
        address tokenAddress,
        address quote
    ) internal returns (address) {
        IUniswapV2Factory factory = IUniswapV2Factory(uniswapV2Factory);
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapV2Router);

        address tokenB = quote == address(0)
            ? router.WETH()
            : quote;
        address pair = factory.createPair(tokenAddress, tokenB);
        return pair;
    }

    function addLiquidity(
        address tokenAddress,
        address quote,
        uint256 tokenAmount,
        uint256 paymentAmount
    ) internal returns (uint256) {
        Token token = Token(tokenAddress);
        IUniswapV2Router02 router = IUniswapV2Router02(uniswapV2Router);
        token.approve(uniswapV2Router, tokenAmount);
        if (quote == address(0)) {
            //slither-disable-next-line arbitrary-send-eth
            (, , uint256 liquidity) = router.addLiquidityETH{value: paymentAmount}(
                tokenAddress,
                tokenAmount,
                tokenAmount,
                paymentAmount,
                address(this),
                block.timestamp
            );
            return liquidity;
        } else {
            IERC20(quote).forceApprove(address(router), paymentAmount);
            /**
             * 
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
             */
            (, , uint256 liquidity) = router.addLiquidity(
                tokenAddress,
                quote,
                tokenAmount,
                paymentAmount,
                tokenAmount,
                paymentAmount,
                address(this),
                block.timestamp
            );
            return liquidity;
        }
    }

    function burnLiquidityToken(address pair, uint256 liquidity) internal {
        SafeERC20.safeTransfer(IERC20(pair), address(0), liquidity);
    }

    function calculateFee(
        uint256 _amount,
        uint256 _feePercent
    ) internal pure returns (uint256) {
        return (_amount * _feePercent) / FEE_DENOMINATOR;
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

    function Transfer(address _receiver, address  _quote,  uint256 _Amount) internal {
        if (_quote == address(0)) {
            // send ether
            TransferETH(_receiver, _Amount);
        } else {
            // Transfer the total payment from the sender to the project receipt address
            TransferToken(_quote, _receiver, _Amount);
        }
    }

    function TransferETH(address _receiver, uint256 _Amount) internal {
        // assert(payable(_receiver).send(_Amount));
        // This forwards all available gas. Be sure to check the return value!
        (bool success, ) = _receiver.call{value: _Amount}(new bytes(0));
        require(success, "Transfer failed.");
    }

    function TransferToken(
        address _tokenAddress,
        address _receiver,
        uint256 _Amount
    ) internal {
        IERC20(_tokenAddress).safeTransfer(_receiver, _Amount);
    }
}
