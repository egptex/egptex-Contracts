// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TokenSale
 * @notice Sell platform tokens (EGPT) for native POL on Polygon Mainnet.
 *         1 Token = 0.5 POL by default (configurable by owner).
 * @dev    tokenAmount in all external functions is expressed in token wei (18 decimals).
 *         pricePerToken is the POL wei cost per 1 whole token (1e18 token wei).
 *         requiredPOL = tokenAmount * pricePerToken / 1e18
 * Owner:  0x8D7F6b1aE2C7cFCc41185D75Db3E3Aee3E44f555
 * Token:  0x9FE869D94664C1C5ea90536c4a66F90B0A86A651
 */
contract TokenSale is Ownable, ReentrancyGuard, Pausable {

    // ─────────────────────────────────────────────
    //  Custom Errors
    // ─────────────────────────────────────────────
    error ZeroAmount();
    error ZeroPrice();
    error InsufficientContractBalance(uint256 requested, uint256 available);
    error IncorrectPayment(uint256 required, uint256 sent);
    error NothingToWithdraw();
    error TransferFailed();

    // ─────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────
    IERC20 public immutable token;

    /// @notice POL wei required to purchase 1 whole token (1e18 token wei).
    ///         Default: 5e17 = 0.5 POL per token.
    uint256 public pricePerToken;

    /// @notice Cumulative POL received from all purchases (not withdrawn yet included).
    uint256 public totalPOLCollected;

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────
    event TokensPurchased(address indexed buyer, uint256 tokenAmount, uint256 polPaid);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event POLWithdrawn(address indexed to, uint256 amount);
    event UnsoldTokensWithdrawn(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────
    /**
     * @param tokenAddress   Address of the ERC20 platform token.
     * @param initialPrice   POL wei per 1 whole token; pass 5e17 for 0.5 POL.
     * @param ownerAddress   Address that will be the sole owner / admin.
     */
    constructor(
        address tokenAddress,
        uint256 initialPrice,
        address ownerAddress
    ) Ownable(ownerAddress) {
        if (tokenAddress == address(0)) revert ZeroAmount();
        if (initialPrice == 0) revert ZeroPrice();
        token = IERC20(tokenAddress);
        pricePerToken = initialPrice;
    }

    // ─────────────────────────────────────────────
    //  Public: Buy Tokens
    // ─────────────────────────────────────────────
    /**
     * @notice Buy platform tokens by sending POL.
     * @param tokenAmount  Amount of tokens to purchase, in token wei (18 decimals).
     *                     E.g. to buy 10 tokens pass 10e18.
     */
    function buyTokens(uint256 tokenAmount)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 required = getRequiredPOL(tokenAmount);
        if (required == 0) revert ZeroAmount();
        if (msg.value != required) revert IncorrectPayment(required, msg.value);

        uint256 contractBalance = token.balanceOf(address(this));
        if (contractBalance < tokenAmount) {
            revert InsufficientContractBalance(tokenAmount, contractBalance);
        }

        totalPOLCollected += msg.value;

        bool ok = token.transfer(msg.sender, tokenAmount);
        if (!ok) revert TransferFailed();

        emit TokensPurchased(msg.sender, tokenAmount, msg.value);
    }

    // ─────────────────────────────────────────────
    //  Owner: Price
    // ─────────────────────────────────────────────
    /**
     * @notice Update the token sale price.
     * @param newPrice  New POL wei per 1 whole token.
     */
    function setPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert ZeroPrice();
        uint256 old = pricePerToken;
        pricePerToken = newPrice;
        emit PriceUpdated(old, newPrice);
    }

    // ─────────────────────────────────────────────
    //  Owner: Withdrawals
    // ─────────────────────────────────────────────
    /// @notice Withdraw all collected POL to the owner wallet.
    function withdrawPOL() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToWithdraw();
        (bool ok, ) = owner().call{value: balance}("");
        if (!ok) revert TransferFailed();
        emit POLWithdrawn(owner(), balance);
    }

    /**
     * @notice Withdraw unsold tokens held by this contract.
     * @param amount  Token wei amount to withdraw. Pass 0 to withdraw all.
     */
    function withdrawUnsoldTokens(uint256 amount) external onlyOwner nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NothingToWithdraw();
        uint256 toWithdraw = (amount == 0) ? balance : amount;
        if (toWithdraw > balance) revert InsufficientContractBalance(toWithdraw, balance);
        bool ok = token.transfer(owner(), toWithdraw);
        if (!ok) revert TransferFailed();
        emit UnsoldTokensWithdrawn(owner(), toWithdraw);
    }

    // ─────────────────────────────────────────────
    //  Owner: Pause / Unpause
    // ─────────────────────────────────────────────
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─────────────────────────────────────────────
    //  Views
    // ─────────────────────────────────────────────
    /// @notice Returns the current price per token in POL wei.
    function getCurrentPrice() external view returns (uint256) {
        return pricePerToken;
    }

    /// @notice Returns this contract's token balance in token wei.
    function getTokenBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Calculate the POL wei required for a given token purchase.
     * @param tokenAmount  Token wei amount the buyer wants to purchase.
     */
    function getRequiredPOL(uint256 tokenAmount) public view returns (uint256) {
        return (tokenAmount * pricePerToken) / 1e18;
    }

    // ─────────────────────────────────────────────
    //  Receive
    // ─────────────────────────────────────────────
    receive() external payable {}
}
