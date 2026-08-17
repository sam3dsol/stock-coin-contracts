// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  Full Math
/// @notice 512-bit multiply-then-divide, so `a * b / d` is exact even when
///         `a * b` overflows 256 bits. Uniswap v3-core's FullMath, unchanged
///         except for 0.8 syntax.
/// @dev    Needed by graduationStatus: liquidity is a uint128 and a sqrt price
///         is a uint160, so their product can reach 2^288. Shifting instead of
///         mulDiv would silently overflow on a large position.
library FullMath {
    error DivideByZero();
    error MulDivOverflow();

    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit product as prod1 * 2^256 + prod0
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                if (denominator == 0) revert DivideByZero();
                return prod0 / denominator;
            }

            // the quotient must fit in 256 bits
            if (denominator <= prod1) revert MulDivOverflow();

            // subtract the remainder to make the product an exact multiple
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // factor the powers of two out of the denominator
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // invert the denominator mod 2^256 by Newton-Raphson
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // 2^8
            inv *= 2 - denominator * inv; // 2^16
            inv *= 2 - denominator * inv; // 2^32
            inv *= 2 - denominator * inv; // 2^64
            inv *= 2 - denominator * inv; // 2^128
            inv *= 2 - denominator * inv; // 2^256

            result = prod0 * inv;
        }
    }
}
