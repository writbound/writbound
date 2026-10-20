// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3PoolLike} from "../interfaces/IUniswapV3.sol";
import {TickMath} from "./uniswap/TickMath.sol";
import {FullMath} from "./uniswap/FullMath.sol";

/// @notice Time-weighted price from a Uniswap v3 pool's oracle. Same maths as v3-periphery OracleLibrary
///         (consult + getQuoteAtTick + getOldestObservationSecondsAgo), rewritten for solc 0.8.
library TwapOracle {
    error TwapAmountTooLarge();

    /// @return tick   arithmetic-mean tick over `window` seconds (rounded towards -infinity, like OracleLibrary)
    /// @return used   the window actually used: min(window, age of the pool's oldest observation). 0 = spot (slot0).
    function meanTick(address pool, uint32 window) internal view returns (int24 tick, uint32 used) {
        used = oldestObservationSecondsAgo(pool);
        if (used > window) used = window;
        if (used == 0) {
            // Only possible when the pool has a single observation written in this very block (cardinality 1).
            (, tick,,,,,) = IUniswapV3PoolLike(pool).slot0();
            return (tick, 0);
        }
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = used;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = IUniswapV3PoolLike(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 w = int56(uint56(used));
        tick = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) tick--;
    }

    /// @notice Seconds since the oldest observation the pool still stores.
    function oldestObservationSecondsAgo(address pool) internal view returns (uint32) {
        (,, uint16 index, uint16 cardinality,,,) = IUniswapV3PoolLike(pool).slot0();
        if (cardinality == 0) return 0;
        (uint32 ts,,, bool initialized) = IUniswapV3PoolLike(pool).observations((uint256(index) + 1) % cardinality);
        if (!initialized) (ts,,,) = IUniswapV3PoolLike(pool).observations(0);
        unchecked {
            return uint32(block.timestamp) - ts;
        }
    }

    /// @notice Amount of `quoteToken` received for `baseAmount` of `baseToken` at `tick` (no fee, no impact).
    function quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        if (baseAmount > type(uint128).max) revert TwapAmountTooLarge();
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
