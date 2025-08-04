// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import {Tick} from "./lib/Tick.sol";
import {Position} from "./lib/Position.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IUniswapV3MintCallback} from "./interfaces/IUniswapV3MintCallback.sol";

/**
 * @title UniswapV3Pool
 * @notice A concentrated liquidity automated market maker pool
 * @dev This contract implements the core functionality of a Uniswap V3 pool,
 *      allowing users to provide liquidity within specific price ranges (ticks)
 */
contract UniswapV3Pool {
    // Using library functions for tick and position management
    using Tick for mapping(int24 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    // ============ ERRORS ============
    /// @notice Thrown when tick range is invalid (lower >= upper or outside bounds)
    error InvalidTickRange();
    /// @notice Thrown when attempting to mint zero liquidity
    error ZeroLiquidity();
    /// @notice Thrown when insufficient tokens are provided for minting
    error InsufficientInputAmount();

    // ============ EVENTS ============
    /// @notice Emitted when liquidity is minted (added) to the pool
    /// @param sender The address that called the mint function
    /// @param owner The address that owns the liquidity position
    /// @param lowerTick The lower tick boundary of the position
    /// @param upperTick The upper tick boundary of the position
    /// @param amount The amount of liquidity minted
    /// @param amount0 The amount of token0 required
    /// @param amount1 The amount of token1 required
    event Mint(
        address sender,
        address indexed owner,
        int24 indexed lowerTick,
        int24 indexed upperTick,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    // ============ CONSTANTS ============
    /// @notice The minimum tick that can be used in any pool (corresponds to price of ~10^-37)
    int24 internal constant MIN_TICK = -887272;
    /// @notice The maximum tick that can be used in any pool (corresponds to price of ~10^37)
    int24 internal constant MAX_TICK = -MIN_TICK;

    // ============ IMMUTABLE STATE ============
    /// @notice The first of the two tokens in the pool (address lower than token1)
    address public immutable token0;
    /// @notice The second of the two tokens in the pool (address higher than token0)
    address public immutable token1;

    // ============ MUTABLE STATE ============
    
    /**
     * @notice Packed variables that are read together for gas efficiency
     * @dev Slot0 contains the current price and tick information
     */
    struct Slot0 {
        /// @notice Current sqrt(price) * 2^96 (Q64.96 fixed point number)
        uint160 sqrtPriceX96;
        /// @notice Current tick (logarithmic representation of price)
        int24 tick;
    }
    /// @notice Current pool state variables
    Slot0 public slot0;

    /// @notice The amount of liquidity currently active in the pool
    /// @dev L in the Uniswap V3 whitepaper
    uint128 public liquidity;

    /// @notice Mapping of tick to tick information
    /// @dev Each tick stores liquidity data and crossing information
    mapping(int24 => Tick.Info) public ticks;
    
    /// @notice Mapping of position key to position information
    /// @dev Position key is computed from owner, lowerTick, and upperTick
    mapping(bytes32 => Position.Info) public positions;

    // ============ CONSTRUCTOR ============
    
    /**
     * @notice Creates a new Uniswap V3 pool
     * @param token0_ The address of token0 (must be < token1_)
     * @param token1_ The address of token1 (must be > token0_)
     * @param sqrtPriceX96 The initial sqrt price of the pool (Q64.96)
     * @param tick The initial tick corresponding to the sqrt price
     */
    constructor(
        address token0_,
        address token1_,
        uint160 sqrtPriceX96,
        int24 tick
    ) {
        token0 = token0_;
        token1 = token1_;

        // Initialize the pool's price state
        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
    }

    // ============ CORE FUNCTIONS ============
    
    /**
     * @notice Adds liquidity to the pool within a specified price range
     * @dev This function mints liquidity to a position and calculates required token amounts
     * @param owner The address that will own the liquidity position
     * @param lowerTick The lower tick boundary of the position (minimum price)
     * @param upperTick The upper tick boundary of the position (maximum price)
     * @param amount The amount of liquidity to add
     * @return amount0 The amount of token0 required for the position
     * @return amount1 The amount of token1 required for the position
     */
    function mint(
        address owner,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1) {
        
        // ============ INPUT VALIDATION ============
        
        // Validate tick range: lower must be less than upper and within global bounds
        if (
            lowerTick >= upperTick ||
            lowerTick < MIN_TICK ||
            upperTick > MAX_TICK
        ) revert InvalidTickRange();

        // Ensure we're not trying to mint zero liquidity
        if (amount == 0) revert ZeroLiquidity();

        // ============ STATE UPDATES ============
        
        // Update tick liquidity tracking for both boundaries
        // This tracks how much liquidity is added/removed when crossing each tick
        ticks.update(lowerTick, amount);
        ticks.update(upperTick, amount);

        // Get or create the position and update its liquidity
        Position.Info storage position = positions.get(
            owner,
            lowerTick,
            upperTick
        );
        position.update(amount);

        // ============ TOKEN AMOUNT CALCULATION ============
        
        // NOTE: In a real implementation, these amounts would be calculated based on:
        // - Current price (slot0.sqrtPriceX96)
        // - Position bounds (lowerTick, upperTick)  
        // - Liquidity amount
        // For this educational version, amounts are hardcoded
        amount0 = 0.998976618347425280 ether;
        amount1 = 5000 ether;      
        
        // Update global liquidity (assumes position is in range)
        liquidity += uint128(amount);

        // ============ TOKEN TRANSFER VERIFICATION ============
        
        // Record balances before callback to verify tokens are received
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        
        // Call back to the sender to request token transfers
        // The sender must implement IUniswapV3MintCallback and transfer the required tokens
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1
        );
        
        // Verify that the required tokens were actually transferred
        if (amount0 > 0 && balance0Before + amount0 > balance0())
            revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > balance1())
            revert InsufficientInputAmount();

        // ============ EVENT EMISSION ============
        
        // Emit event for tracking liquidity minting
        emit Mint(msg.sender, owner, lowerTick, upperTick, amount, amount0, amount1);
    }

    // ============ INTERNAL HELPER FUNCTIONS ============
    
    /**
     * @notice Gets the current balance of token0 held by the pool
     * @return balance The amount of token0 in the pool
     */
    function balance0() internal view returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    /**
     * @notice Gets the current balance of token1 held by the pool
     * @return balance The amount of token1 in the pool
     */
    function balance1() internal view returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }

    function swap(address recipient)
        public
        returns (int256 amount0, int256 amount1)
    {
        int24 nextTick = 85184;
        uint160 nextPrice = 5604469350942327889444743441197;

        amount0 = -0.008396714242162444 ether;
        amount1 = 42 ether;
        (slot0.tick, slot0.sqrtPriceX96) = (nextTick, nextPrice);
        IERC20(token0).transfer(recipient, uint256(-amount0));

        uint256 balance1Before = balance1();
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
            amount0,
            amount1
        );
        if (balance1Before + uint256(amount1) < balance1())
            revert InsufficientInputAmount();

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            liquidity,
            slot0.tick
        );
    }

}