//SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import './TickMath.sol';

library Tick {

    // info stored for each initialized individual tick
    struct Info {
        uint128 liquidityGross;         //the total position liquidity that references this tick
        int128 liquidityNet;            //amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left)
        uint256 feeGrowthOutside0X128;  //fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        uint256 feeGrowthOutside1X128;  //only has relative meaning, not absolute — the value depends on when the tick is initialized
        bool initialized;               //true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0// these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
    }

    //Return the maximum liquidity available divided the number of ticks
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) 
        internal pure returns(uint128) 
    {
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        bool upper,
        uint128 maxLiquidity
    ) internal returns(bool flipped) { //`flipped` will be `true` if liquidity becomes grater than 0 or become 0 after call this fn
        Info memory info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = info.liquidityGross < 0
            ? liquidityGrossBefore - uint128(-liquidityDelta)
            : liquidityGrossBefore + uint128(liquidityDelta);

        require(liquidityGrossAfter <= maxLiquidity, "liquidity > max");

        //flipped = (1iquidityGrossBefore == 0 && 1iquidityGrossAffer > 0)
        //        || (liquidityGrossBefore > 0 && 1iquidityGrossAfter == 0)
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) { info.initialized = true; }

        info.liquidityGross = liquidityGrossAfter;

        info.liquidityNet = upper
            ? info.liquidityNet - liquidityDelta
            : info.liquidityNet + liquidityDelta;
    }

    /// @notice Clears tick data
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }
}
