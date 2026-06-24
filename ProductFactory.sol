// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ProductFactory
 * @notice Decentralized marketplace contract for EGPTEX store on Polygon
 * @dev Products use IPFS CID for static metadata (name/images/variants).
 *      All dynamic data (stock, orders, shipping) lives fully on-chain.
 * Owner: 0x8D7F6b1aE2C7cFCc41185D75Db3E3Aee3E44f555
 * Payment Token: 0x9FE869D94664C1C5ea90536c4a66F90B0A86A651
 */
contract ProductFactory is Ownable, ReentrancyGuard, Pausable {

    // ─────────────────────────────────────────────
    //  Custom Errors (gas-optimised)
    // ─────────────────────────────────────────────
    error ProductNotFound(uint256 productId);
    error InsufficientStock(uint256 available, uint256 requested);
    error PaymentFailed();
    error OrderNotFound(uint256 orderId);
    error InvalidQuantity();
    error ProductIsArchived(uint256 productId);
    error NotBuyer(uint256 orderId);
    error AlreadyRefunded(uint256 orderId);
    error InsufficientAllowance(uint256 required, uint256 actual);
    error ZeroPrice();
    error InvalidCID();
    error InvalidShippingData();
    error TransferFailed();

    // ─────────────────────────────────────────────
    //  Enums
    // ─────────────────────────────────────────────
    enum OrderStatus {
        Pending,
        Paid,
        Processing,
        Shipped,
        Delivered,
        Cancelled,
        Refunded
    }

    // ─────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────
    struct Product {
        uint256 id;
        string metadataCID;   // IPFS CID of static metadata JSON (1 file per product, never changes unless product details change)
        uint256 price;        // Base price in payment token units (18 decimals)
        uint256 quantity;     // Current total stock
        uint256 soldCount;    // Cumulative sold
        bool isAvailable;
        bool isArchived;
        uint256 createdAt;
        uint256 updatedAt;
    }

    struct Order {
        uint256 id;
        address buyer;
        uint256 productId;
        uint256 variantIndex;  // Index into the product's variants array (0 = no variant / base product)
        uint256 quantity;
        uint256 amountPaid;    // Total paid (variant price * qty + shipping)
        OrderStatus status;
        string shippingData;   // AES-256-GCM encrypted shipping JSON, stored fully on-chain
        uint256 timestamp;
    }

    // ─────────────────────────────────────────────
    //  State Variables
    // ─────────────────────────────────────────────
    IERC20 public immutable paymentToken;

    uint256 public productCount;
    uint256 public orderCount;

    mapping(uint256 => Product) private _products;
    mapping(uint256 => Order) private _orders;
    mapping(address => uint256[]) private _buyerOrders;

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────
    event ProductCreated(
        uint256 indexed productId,
        string metadataCID,
        uint256 price,
        uint256 quantity
    );

    event ProductUpdated(
        uint256 indexed productId,
        string metadataCID,
        uint256 price
    );

    event ProductArchived(uint256 indexed productId);
    event ProductRestored(uint256 indexed productId);

    event StockUpdated(
        uint256 indexed productId,
        uint256 oldQuantity,
        uint256 newQuantity
    );

    event OrderCreated(
        uint256 indexed orderId,
        address indexed buyer,
        uint256 indexed productId,
        uint256 variantIndex,
        uint256 quantity,
        uint256 amountPaid
    );

    event OrderStatusChanged(
        uint256 indexed orderId,
        address indexed buyer,
        OrderStatus oldStatus,
        OrderStatus newStatus
    );

    event PaymentReceived(
        uint256 indexed orderId,
        address indexed buyer,
        uint256 amount
    );

    event RefundProcessed(
        uint256 indexed orderId,
        address indexed buyer,
        uint256 amount
    );

    // ─────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────
    constructor(address _paymentToken, address _owner) Ownable(_owner) {
        require(_paymentToken != address(0), "Invalid token address");
        require(_owner != address(0), "Invalid owner address");
        paymentToken = IERC20(_paymentToken);
    }

    // ─────────────────────────────────────────────
    //  Owner: Product Management
    // ─────────────────────────────────────────────

    function createProduct(
        string calldata metadataCID,
        uint256 price,
        uint256 quantity
    ) external onlyOwner whenNotPaused returns (uint256 productId) {
        if (bytes(metadataCID).length == 0) revert InvalidCID();
        if (price == 0) revert ZeroPrice();
        if (quantity == 0) revert InvalidQuantity();

        productId = ++productCount;

        _products[productId] = Product({
            id: productId,
            metadataCID: metadataCID,
            price: price,
            quantity: quantity,
            soldCount: 0,
            isAvailable: true,
            isArchived: false,
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });

        emit ProductCreated(productId, metadataCID, price, quantity);
    }

    function updateProduct(
        uint256 productId,
        string calldata metadataCID,
        uint256 price
    ) external onlyOwner {
        Product storage p = _getExistingProduct(productId);
        if (bytes(metadataCID).length == 0) revert InvalidCID();
        if (price == 0) revert ZeroPrice();

        p.metadataCID = metadataCID;
        p.price = price;
        p.updatedAt = block.timestamp;

        emit ProductUpdated(productId, metadataCID, price);
    }

    function archiveProduct(uint256 productId) external onlyOwner {
        Product storage p = _getExistingProduct(productId);
        p.isArchived = true;
        p.isAvailable = false;
        p.updatedAt = block.timestamp;
        emit ProductArchived(productId);
    }

    function restoreProduct(uint256 productId) external onlyOwner {
        Product storage p = _getExistingProduct(productId);
        p.isArchived = false;
        p.isAvailable = true;
        p.updatedAt = block.timestamp;
        emit ProductRestored(productId);
    }

    function updateStock(uint256 productId, uint256 newQuantity) external onlyOwner {
        Product storage p = _getExistingProduct(productId);
        uint256 old = p.quantity;
        p.quantity = newQuantity;
        p.isAvailable = newQuantity > 0;
        p.updatedAt = block.timestamp;
        emit StockUpdated(productId, old, newQuantity);
    }

    function updateAvailability(uint256 productId, bool available) external onlyOwner {
        Product storage p = _getExistingProduct(productId);
        p.isAvailable = available;
        p.updatedAt = block.timestamp;
    }

    function updateOrderStatus(uint256 orderId, OrderStatus newStatus) external onlyOwner {
        if (_orders[orderId].id == 0) revert OrderNotFound(orderId);
        Order storage o = _orders[orderId];
        OrderStatus old = o.status;
        o.status = newStatus;
        emit OrderStatusChanged(orderId, o.buyer, old, newStatus);
    }

    function processRefund(uint256 orderId) external onlyOwner nonReentrant {
        if (_orders[orderId].id == 0) revert OrderNotFound(orderId);
        Order storage o = _orders[orderId];
        if (o.status == OrderStatus.Refunded) revert AlreadyRefunded(orderId);

        uint256 refundAmount = o.amountPaid;
        OrderStatus old = o.status;
        o.status = OrderStatus.Refunded;

        bool ok = paymentToken.transfer(o.buyer, refundAmount);
        if (!ok) revert TransferFailed();

        emit OrderStatusChanged(orderId, o.buyer, old, OrderStatus.Refunded);
        emit RefundProcessed(orderId, o.buyer, refundAmount);
    }

    // ─────────────────────────────────────────────
    //  Emergency Controls
    // ─────────────────────────────────────────────

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────
    //  Public: Purchase
    // ─────────────────────────────────────────────

    /**
     * @notice Purchase a product (or a specific variant of it)
     * @param productId      On-chain product ID
     * @param variantIndex   Variant index (0 = base product, 1+ = variants)
     * @param qty            Quantity to purchase
     * @param variantPrice   Agreed price for the selected variant (in token units, validated off-chain via metadata)
     * @param shippingCost   Shipping cost in token units (dynamically calculated by frontend)
     * @param shippingData   AES-256-GCM encrypted shipping JSON — stored on-chain, never on IPFS
     */
    function purchaseProduct(
        uint256 productId,
        uint256 variantIndex,
        uint256 qty,
        uint256 variantPrice,
        uint256 shippingCost,
        string calldata shippingData
    ) external nonReentrant whenNotPaused returns (uint256 orderId) {
        if (qty == 0) revert InvalidQuantity();
        if (bytes(shippingData).length == 0) revert InvalidShippingData();
        if (variantPrice == 0) revert ZeroPrice();

        Product storage p = _getExistingProduct(productId);
        if (p.isArchived) revert ProductIsArchived(productId);
        if (!p.isAvailable) revert ProductIsArchived(productId);
        if (p.quantity < qty) revert InsufficientStock(p.quantity, qty);

        uint256 totalCost = (variantPrice * qty) + shippingCost;

        uint256 allowance = paymentToken.allowance(msg.sender, address(this));
        if (allowance < totalCost) revert InsufficientAllowance(totalCost, allowance);

        bool ok = paymentToken.transferFrom(msg.sender, owner(), totalCost);
        if (!ok) revert TransferFailed();

        p.quantity -= qty;
        p.soldCount += qty;
        if (p.quantity == 0) p.isAvailable = false;
        p.updatedAt = block.timestamp;

        orderId = ++orderCount;
        _orders[orderId] = Order({
            id: orderId,
            buyer: msg.sender,
            productId: productId,
            variantIndex: variantIndex,
            quantity: qty,
            amountPaid: totalCost,
            status: OrderStatus.Paid,
            shippingData: shippingData,
            timestamp: block.timestamp
        });
        _buyerOrders[msg.sender].push(orderId);

        emit PaymentReceived(orderId, msg.sender, totalCost);
        emit OrderCreated(orderId, msg.sender, productId, variantIndex, qty, totalCost);
    }

    // ─────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────

    function getProduct(uint256 productId) external view returns (Product memory) {
        return _getExistingProduct(productId);
    }

    function getProducts(uint256 offset, uint256 limit)
        external
        view
        returns (Product[] memory result, uint256 total)
    {
        total = productCount;
        if (offset >= total) return (new Product[](0), total);
        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 count = end - offset;
        result = new Product[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = _products[offset + i + 1];
        }
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        if (_orders[orderId].id == 0) revert OrderNotFound(orderId);
        return _orders[orderId];
    }

    function getBuyerOrders(address buyer)
        external
        view
        returns (Order[] memory result)
    {
        uint256[] storage ids = _buyerOrders[buyer];
        result = new Order[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = _orders[ids[i]];
        }
    }

    function getBuyerOrderIds(address buyer) external view returns (uint256[] memory) {
        return _buyerOrders[buyer];
    }

    // ─────────────────────────────────────────────
    //  Internal Helpers
    // ─────────────────────────────────────────────

    function _getExistingProduct(uint256 productId) internal view returns (Product storage) {
        if (_products[productId].id == 0) revert ProductNotFound(productId);
        return _products[productId];
    }
}
