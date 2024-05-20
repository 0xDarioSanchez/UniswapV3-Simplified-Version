//SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "./lib/Tick.sol";
import "./lib/Position.sol";
import "./lib/SafeCast.sol";
import "./interfaces/IERC20.sol";
import "./NoDelegateCall.sol";

contract CLAMM is NoDelegateCall {
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    //////////////////////////////////////////////////////////////////// 
    //                      STATE VARIABLES                           //
    ////////////////////////////////////////////////////////////////////
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    uint128 public immutable maxLiquidityPerTick;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        bool unlocked;          //To prevent reentrancy
    }
    Slot0 public slot0;

    struct ModifyPositionParams {
        address owner;          //The address that owns the position
        int24 tickLower;        //The lower tick of the position
        int24 tickUpper;        //The upper tick of the position
        int128 liquidityDelta;  //Any change in liquidity
    }

    mapping(int24 => Tick.Info) public ticks;
    mapping(bytes32 => Position.Info) public positions;

    //////////////////////////////////////////////////////////////////// 
    //                          MODIFIERS                             //
    //////////////////////////////////////////////////////////////////// 

    modifier lock() {
        require(slot0.unlocked, "locked");
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    //////////////////////////////////////////////////////////////////// 
    //                         CONSTRUCTOR                            //
    ////////////////////////////////////////////////////////////////////

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    //////////////////////////////////////////////////////////////////// 
    //                      EXTERNAL FUNCTIONS                        //
    ////////////////////////////////////////////////////////////////////

    /// @notice IUniswapV3PoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external {
        require(slot0.sqrtPriceX96 == 0, 'Already Initialized');

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            unlocked: true
        });
    }

    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount) 
        external lock returns(uint256 amount0, uint256 amount1) 
        {
        require(amount > 0, "amount is zero");
        (, int256 amount0Int, int256 amount1Int) =  //Both are `int` because can be negative if `liquidityDelta` is negative
            _modifyPosition(
                ModifyPositionParams({
                    owner: recipient,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(amount)).toInt128()
                })
            );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        if (amount0 > 0) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0) ;
        }
        if (amount1 > 0) {
            IERC20(token1).transferFrom(msg.sender, address(this), amount1) ;
        }
    }

    //////////////////////////////////////////////////////////////////// 
    //                      INTERNAL FUNCTIONS                        //
    ////////////////////////////////////////////////////////////////////

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    function _modifyPosition(ModifyPositionParams memory params) private noDelegateCall
        returns(Position.Info storage position, int256 amount0, int256 amount1)
    {
        _checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0;    //SLOAD for gas optimization

        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,      //Amount of liquidity that is been added or removed
            _slot0.tick
        );

        return (positions[bytes32(0)], 0, 0);
    }

    /// @dev Common checks for valid tick inputs.
    function _checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        position = positions.get(owner, tickLower, tickUpper);

        //TODO fees
        uint256 _feeGrowthGlobal0X128 = 0; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = 0; // SLOAD for gas optimization

        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            // uint32 time = _blockTimestamp();
            // (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
            //     observations.observeSingle(
            //         time,
            //         0,
            //         slot0.tick,
            //         slot0.observationIndex,
            //         liquidity,
            //         slot0.observationCardinality
            //     );

            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                false,
                maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                true,
                maxLiquidityPerTick
            );

            // if (flippedLower) {
            //     tickBitmap.flipTick(tickLower, tickSpacing);
            // }
            // if (flippedUpper) {
            //     tickBitmap.flipTick(tickUpper, tickSpacing);
            // }
        }

        // (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
        //     ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);
        
        //TODO fees
        position.update(liquidityDelta, 0, 0);

        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }
}
