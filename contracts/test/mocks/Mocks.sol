// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter02} from "../../src/interfaces/IUniswapV3.sol";
import {TwapOracle} from "../../src/libraries/TwapOracle.sol";
import {TickMath} from "../../src/libraries/uniswap/TickMath.sol";

contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// Uniswap-v3-shaped pool: `twapTick` drives the oracle (observe), `spotTick` drives the mock router's execution price.
contract MockPool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public twapTick;
    int24 public spotTick;
    uint16 public cardinality = 100;
    uint32 public oldestAge = 3600;
    uint128 public liquidity = 1e18;

    constructor(address a, address b, uint24 f, int24 tick) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = f;
        twapTick = tick;
        spotTick = tick;
    }

    function setTicks(int24 twap, int24 spot) external {
        twapTick = twap;
        spotTick = spot;
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    function setOracle(uint16 card, uint32 age) external {
        cardinality = card;
        oldestAge = age;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtPriceAtTick(spotTick), spotTick, 0, cardinality, cardinality, 0, true);
    }

    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        return (uint32(block.timestamp) - oldestAge, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tc, uint160[] memory spl) {
        tc = new int56[](secondsAgos.length);
        spl = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            require(secondsAgos[i] <= oldestAge, "OLD");
            // cumulative = tick * (now - secondsAgo) relative to an arbitrary origin
            tc[i] = int56(twapTick) * int56(int256(uint256(1_000_000 - secondsAgos[i])));
        }
    }
}

contract MockFactory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function setPool(address a, address b, uint24 f, address p) external {
        getPool[a][b][f] = p;
        getPool[b][a][f] = p;
    }
}

/// SwapRouter02-shaped router: pulls amountIn, pays out at the pool's spot tick minus the fee, mints tokenOut.
contract MockRouter {
    MockFactory public immutable factory;
    bool public forceRevert;
    uint256 public lastAmountIn;

    constructor(MockFactory f) {
        factory = f;
    }

    bool public emptyRevert;
    uint256 public burnLoops;

    function setEmptyRevert(bool v) external {
        emptyRevert = v;
    }

    function setBurnLoops(uint256 n) external {
        burnLoops = n;
    }

    function setForceRevert(bool v) external {
        forceRevert = v;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(!forceRevert, "forced");
        if (emptyRevert) revert();
        for (uint256 i; i < burnLoops; ++i) {
            lastAmountIn = i; // burn gas like a multi-tick swap
        }
        MockPool pool = MockPool(factory.getPool(p.tokenIn, p.tokenOut, p.fee));
        require(address(pool) != address(0), "no pool");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        lastAmountIn = p.amountIn;
        out = TwapOracle.quoteAtTick(pool.spotTick(), p.amountIn, p.tokenIn, p.tokenOut);
        out = out * (1_000_000 - p.fee) / 1_000_000;
        require(out >= p.amountOutMinimum, "Too little received");
        MockERC20(p.tokenOut).mint(p.recipient, out);
    }
}

/// A router that tries to re-enter the vault during the swap.
contract ReentrantRouter {
    address public vault;
    bytes public payload;

    function arm(address v, bytes calldata data) external {
        vault = v;
        payload = data;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata) external payable returns (uint256) {
        (bool ok, bytes memory ret) = vault.call(payload);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return 0;
    }
}
