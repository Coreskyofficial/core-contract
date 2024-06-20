// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CoreskyRouterInterface} from "../interfaces/CoreskyRouterInterface.sol";
import { SeaportInterface } from "../interfaces/SeaportInterface.sol";
import { ReentrancyGuard } from "../lib/ReentrancyGuard.sol";
import {ItemType} from "../lib/ConsiderationEnums.sol";
import {
AdvancedOrder,
CriteriaResolver,
Execution,
FulfillmentComponent,
ReceivedItem
} from "../lib/ConsiderationStructs.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  CoreskyRouter
 * @author Ryan Ghods (ralxz.eth), 0age (0age.eth), James Wenzel (emo.eth)
 * @notice A utility contract for fulfilling orders with multiple
 *         Seaport versions. DISCLAIMER: This contract only works when
 *         all consideration items across all listings are native tokens.
 */
contract CoreskyRouter is CoreskyRouterInterface, ReentrancyGuard, Ownable {

    //store the router address for exchange
    struct Market {
        address exchange;
        bool isActive;
    }

    Market[] public markets;
    mapping(address => mapping(address => uint256)) private balance;
    /**
     * @dev Deploy contract with the supported Seaport contracts.
     * @param proxies The address of market exchange include seaport and coresky.
     */
    constructor(address[] memory proxies) {
        for (uint256 i = 0; i < proxies.length; i++) {
            markets.push(Market(proxies[i], true));
        }
    }

    /**
     * @dev Fallback function to receive excess ether, in case total amount of
     *      ether sent is more than the amount required to fulfill the order.
     */
    receive() external payable override {
        _assertSeaportAllowed(msg.sender);
    }

    function addMarket(address proxy) external onlyOwner {
        markets.push(Market(proxy, true));
    }

    function updateMarketStatus(uint256 marketId, bool newStatus)
    external
    onlyOwner
    {
        Market storage market = markets[marketId];
        market.isActive = newStatus;
    }

    /**
     * @notice Fulfill available advanced orders through multiple Seaport versions.
     *         See {SeaportInterface-fulfillAvailableAdvancedOrders}
     * @param params The parameters for fulfilling available advanced orders.
     */
    function fulfillAvailableAdvancedOrders(
        FulfillAvailableAdvancedOrdersParams calldata params,
        address token,
        uint256 tokenAmount,
        address[] calldata conduits
    )
    public
    payable
    override
    returns (
        bool[][] memory availableOrders,
        Execution[][] memory executions
    )
    {
        // Ensure this function cannot be triggered during a reentrant call.
        _setReentrancyGuard(true);

        _approveConduit(token, tokenAmount, conduits);

        // Put the number of Seaport contracts on the stack.
        uint256 seaportContractsLength = params.seaportContracts.length;

        // Set the availableOrders and executions arrays to the correct length.
        availableOrders = new bool[][](seaportContractsLength);
        executions = new Execution[][](seaportContractsLength);

        // Track the number of order fulfillments left.
        uint256 fulfillmentsLeft = params.maximumFulfilled;

        // To help avoid stack too deep errors, we format the calldata
        // params in a struct and put it on the stack.
        AdvancedOrder[] memory emptyAdvancedOrders;
        CriteriaResolver[] memory emptyCriteriaResolvers;
        FulfillmentComponent[][] memory emptyFulfillmentComponents;
        CalldataParams memory calldataParams = CalldataParams({
            advancedOrders: emptyAdvancedOrders,
            criteriaResolvers: emptyCriteriaResolvers,
            offerFulfillments: emptyFulfillmentComponents,
            considerationFulfillments: emptyFulfillmentComponents,
            fulfillerConduitKey: params.fulfillerConduitKey,
            recipient: params.recipient,
            maximumFulfilled: fulfillmentsLeft
        });

        // If recipient is not provided assign to msg.sender.
        if (calldataParams.recipient == address(0)) {
            calldataParams.recipient = msg.sender;
        }

        // Iterate through the provided Seaport contracts.
        for (uint256 i = 0; i < seaportContractsLength;) {
            // Ensure the provided Seaport contract is allowed.
            _assertSeaportAllowed(params.seaportContracts[i]);

            // Put the order params on the stack.
            AdvancedOrderParams calldata orderParams =
                                params.advancedOrderParams[i];

            // Assign the variables to the calldata params.
            calldataParams.advancedOrders = orderParams.advancedOrders;
            calldataParams.criteriaResolvers = orderParams.criteriaResolvers;
            calldataParams.offerFulfillments = orderParams.offerFulfillments;
            calldataParams.considerationFulfillments =
                            orderParams.considerationFulfillments;

            // Execute the orders, collecting availableOrders and executions.
            // This is wrapped in a try/catch in case a single order is
            // executed that is no longer available, leading to a revert
            // with `NoSpecifiedOrdersAvailable()` that can be ignored.
            try SeaportInterface(params.seaportContracts[i])
            .fulfillAvailableAdvancedOrders{value: orderParams.etherValue}(
                calldataParams.advancedOrders,
                calldataParams.criteriaResolvers,
                calldataParams.offerFulfillments,
                calldataParams.considerationFulfillments,
                calldataParams.fulfillerConduitKey,
                calldataParams.recipient,
                calldataParams.maximumFulfilled
            ) returns (
                bool[] memory newAvailableOrders,
                Execution[] memory newExecutions
            ) {
                availableOrders[i] = newAvailableOrders;
                executions[i] = newExecutions;

                // Subtract the number of orders fulfilled.
                uint256 newAvailableOrdersLength = newAvailableOrders.length;
                for (uint256 j = 0; j < newAvailableOrdersLength;) {
                    if (newAvailableOrders[j]) {
                        unchecked {
                            --fulfillmentsLeft;
                            ++j;
                        }
                    }
                }

                // Break if the maximum number of executions has been reached.
                if (fulfillmentsLeft == 0) {
                    break;
                }
            } catch (bytes memory data) {
                // Set initial value of first four bytes of revert data
                // to the mask.
                bytes4 customErrorSelector = bytes4(0xffffffff);

                // Utilize assembly to read first four bytes
                // (if present) directly.
                assembly {
                // Combine original mask with first four bytes of
                // revert data.
                    customErrorSelector :=
                    and(
                    // Data begins after length offset.
                        mload(add(data, 0x20)),
                        customErrorSelector
                    )
                }

                // Pass through the custom error if the error is
                // not NoSpecifiedOrdersAvailable()
                if (customErrorSelector != NoSpecifiedOrdersAvailable.selector)
                {
                    assembly {
                        revert(add(data, 32), mload(data))
                    }
                }
            }

            // Update fulfillments left.
            calldataParams.maximumFulfilled = fulfillmentsLeft;

            unchecked {
                ++i;
            }
        }

        // Throw an error if no orders were fulfilled.
        if (fulfillmentsLeft == params.maximumFulfilled) {
            revert NoSpecifiedOrdersAvailable();
        }

        // Return excess ether or token that may not have been used or was sent back.
        _returnTokens(token, tokenAmount, executions);

        // Clear the reentrancy guard.
        _clearReentrancyGuard();
    }

    function _approveConduit(address token, uint256 tokenAmount, address[]  calldata conduits) internal {
        if (msg.value == 0 && token == address(0)) {
            revert InValidTokenAndValue();
        }
        if (token != address(0) && tokenAmount>0) {
            for (uint256 i = 0; i < conduits.length; i++) {
                address conduit = conduits[i];
                _approveEthUSDT(token,conduit);
                IERC20(token).approve(conduit, tokenAmount);
                bool success = IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
                if (!success) {
                    revert TokenReturnTransferFailed(msg.sender, address(this), tokenAmount);
                }
                balance[msg.sender][token] += tokenAmount;
            }
        }

    }
    /**
     * @dev Reverts if the provided market contract is not allowed.
     */
    function _assertSeaportAllowed(address market) internal view {
        bool exsitMarket;
        for (uint256 i = 0; i < markets.length; i++) {
            if (markets[i].exchange == market && markets[i].isActive) {
                exsitMarket = true;
            }
        }
        if (!exsitMarket) {
            revert SeaportNotAllowed(market);
        }
    }

    function _returnTokens(address token, uint256 tokenAmount, Execution[][] memory executions) private {
        if (address(this).balance > 0) {
            _returnExcessEther();
        }
        //return erc20 token if has erc20
        if(token != address(0) && tokenAmount>0){
            uint256 _tokenLeftBalance = IERC20(token).balanceOf(address(this));
            if (_tokenLeftBalance>0) {
                _setExcessTokenAmount(token, executions);
                uint256 excessTokenAmount = _getExcessTokenAmount(token);
                if (excessTokenAmount > 0) {
                    bool sucess = IERC20(token).transfer(msg.sender, excessTokenAmount);
                    if (!sucess) {
                        revert TokenReturnTransferFailed(address(this), msg.sender, excessTokenAmount);
                    }
                    balance[msg.sender][token] -= excessTokenAmount;
                }
            }
        }
    }

    function _setExcessTokenAmount(address token, Execution[][] memory executions) private {
        uint256 transferAmount;
        for (uint256 i = 0; i < executions.length; i++) {
            for (uint256 j = 0; j < executions[i].length; j++) {
                ReceivedItem memory _execute = executions[i][j].item;
                if (token == _execute.token && ItemType.ERC20 == _execute.itemType) {
                    transferAmount += _execute.amount;
                }
            }
        }
        balance[msg.sender][token] -= transferAmount;
    }

    function _getExcessTokenAmount(address token) view internal returns (uint256) {
        return balance[msg.sender][token];
    }

    /**
     * @dev Function to return excess ether, in case total amount of
     *      ether sent is more than the amount required to fulfill the order.
     */
    function _returnExcessEther() private {
        // Send received funds back to msg.sender.
        (bool success, bytes memory data) = payable(msg.sender).call{value: address(this).balance}("");

        // Revert with an error if the ether transfer failed.
        if (!success) {
            revert EtherReturnTransferFailed(msg.sender, address(this).balance, data);
        }
    }

    // usdt token need approve zero first on ethereum mainnet.
    function _approveEthUSDT(address token, address conduit) private {
        if (1==block.chainid){
            if(token == address(0xdAC17F958D2ee523a2206206994597C13D831ec7)){
                IERC20(token).approve(conduit, 0);
            }
        }
    }
}
